// SPDX-License-Identifier: GPL-3.0-or-later
package me.madhushan.pairdesk

import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean

// The "pairdesk/video" channel: the computer's screen as H.264, decoded by
// the phone's (hardware) decoder straight onto a Flutter texture.
//  - supported → whether this phone has an H.264 decoder
//  - start {width, height} → texture id
//  - decode {config, frame, key, pts} → queues one access unit
//    (config: SPS+PPS of a key frame, sent as codec config)
//  - stop
// Events to Dart: "error" (the decoder failed: use JPEG) and "lost" (the
// surface went away, e.g. the app was hidden: start again).
class VideoChannel(engine: FlutterEngine) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "pairdesk/video")
    private val textures: TextureRegistry = engine.renderer
    private val main = Handler(Looper.getMainLooper())
    private var session: Session? = null

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "supported" -> result.success(hasDecoder())
            "start" -> {
                stop()
                val w = call.argument<Int>("width") ?: 0
                val h = call.argument<Int>("height") ?: 0
                try {
                    val s = Session(w, h)
                    session = s
                    result.success(s.textureId)
                } catch (e: Throwable) {
                    session = null
                    result.error("start", e.message ?: "can't start the video decoder", null)
                }
            }
            "decode" -> {
                val s = session
                val frame = call.argument<ByteArray>("frame")
                if (s == null || frame == null) {
                    result.success(null)
                    return
                }
                val pts = (call.argument<Number>("pts") ?: 0).toLong()
                call.argument<ByteArray>("config")?.let {
                    s.queue(Packet(it, MediaCodec.BUFFER_FLAG_CODEC_CONFIG, pts))
                }
                val key = call.argument<Boolean>("key") == true
                s.queue(Packet(frame, if (key) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0, pts))
                result.success(null)
            }
            "stop" -> {
                stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun stop() {
        session?.release()
        session = null
    }

    // Android 10+ only: older Flutter textures for video are less reliable,
    // and pictures work fine there.
    private fun hasDecoder(): Boolean = try {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1280, 720)
        Build.VERSION.SDK_INT >= 29 &&
            MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format) != null
    } catch (e: Throwable) {
        false
    }

    private class Packet(val data: ByteArray, val flags: Int, val pts: Long)

    // One decoder on its own thread, drawing onto one Flutter texture.
    //
    // Threads: the codec and its queues live on "pairdesk-video"; anything
    // that touches Flutter (scheduleFrame, release, channel calls) must run
    // on the main thread, where Flutter checks for it and throws otherwise.
    // Nothing here may throw on the decoder thread: an uncaught exception
    // there ends the whole app, so failures become an "error" event and Dart
    // switches to pictures.
    private inner class Session(width: Int, height: Int) {
        private val producer: TextureRegistry.SurfaceProducer
        val textureId: Long
        private val thread = HandlerThread("pairdesk-video")
        private val handler: Handler
        private var codec: MediaCodec? = null

        // Touched only on the decoder thread.
        private val freeInputs = ArrayDeque<Int>()
        private val pending = ArrayDeque<Packet>()
        @Volatile private var done = false
        @Volatile private var released = false
        private val frameScheduled = AtomicBoolean(false)

        init {
            require(width in 16..8192 && height in 16..8192) { "bad video size ${width}x$height" }
            thread.start()
            // Last line of defence: report instead of taking the app down.
            thread.setUncaughtExceptionHandler { _, e -> report("error", e.toString()) }
            handler = Handler(thread.looper)
            producer = try {
                textures.createSurfaceProducer()
            } catch (e: Throwable) {
                thread.quitSafely()
                throw e
            }
            textureId = producer.id()
            try {
                producer.setSize(width, height)
                producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                    override fun onSurfaceAvailable() {}

                    override fun onSurfaceCleanup() {
                        // The surface goes away (app hidden): this session can't
                        // continue; Dart starts a new one when it's visible again.
                        if (!done) report("lost", "surface released")
                        releaseCodec()
                    }
                })
                val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
                codec = c
                c.setCallback(Callbacks(), handler)
                c.configure(format(width, height, lowLatency = true), producer.surface, null, 0)
                c.start()
            } catch (e: Throwable) {
                // Some decoders reject the low-latency key: try once without.
                if (!retryWithoutLowLatency(width, height)) {
                    release()
                    throw if (e is Exception) e else RuntimeException(e.toString())
                }
            }
        }

        private fun format(width: Int, height: Int, lowLatency: Boolean): MediaFormat {
            val f = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
            f.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(width * height, 512 * 1024))
            if (lowLatency && Build.VERSION.SDK_INT >= 30) f.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            return f
        }

        private fun retryWithoutLowLatency(width: Int, height: Int): Boolean {
            if (Build.VERSION.SDK_INT < 30) return false
            try {
                codec?.release()
            } catch (e: Throwable) {
            }
            codec = null
            return try {
                val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
                codec = c
                c.setCallback(Callbacks(), handler)
                c.configure(format(width, height, lowLatency = false), producer.surface, null, 0)
                c.start()
                true
            } catch (e: Throwable) {
                false
            }
        }

        private inner class Callbacks : MediaCodec.Callback() {
            override fun onInputBufferAvailable(c: MediaCodec, index: Int) {
                if (done) return
                freeInputs.addLast(index)
                feed()
            }

            override fun onOutputBufferAvailable(c: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                try {
                    // Show every picture as soon as it's decoded.
                    val show = info.size > 0 && !done
                    c.releaseOutputBuffer(index, show)
                    if (show) scheduleFrame()
                } catch (e: Throwable) {
                    // Released meanwhile, or the decoder broke.
                    if (!done) report("error", e.toString())
                }
            }

            override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
                report("error", e.diagnosticInfo ?: e.message ?: "decoder error")
            }

            override fun onOutputFormatChanged(c: MediaCodec, format: MediaFormat) {}
        }

        // Asks Flutter to draw the new picture. Must happen on the main
        // thread; at most one request waits at a time.
        private fun scheduleFrame() {
            if (!frameScheduled.compareAndSet(false, true)) return
            main.post {
                frameScheduled.set(false)
                if (released) return@post
                try {
                    producer.scheduleFrame()
                } catch (e: Throwable) {
                }
            }
        }

        fun queue(p: Packet) {
            if (done) return
            handler.post {
                if (done) return@post
                // Far behind (the decoder stalled): drop what waits; the next
                // key frame (Dart asks for one) starts over cleanly.
                if (pending.size > 60) pending.clear()
                pending.addLast(p)
                feed()
            }
        }

        private fun feed() {
            if (done) return
            val c = codec ?: return
            try {
                while (freeInputs.isNotEmpty() && pending.isNotEmpty()) {
                    val p = pending.removeFirst()
                    val index = freeInputs.removeFirst()
                    val buf = c.getInputBuffer(index) ?: continue
                    buf.clear()
                    if (p.data.size > buf.capacity()) {
                        report("error", "frame larger than the decoder's buffer")
                        return
                    }
                    buf.put(p.data)
                    c.queueInputBuffer(index, 0, p.data.size, p.pts, p.flags)
                }
            } catch (e: Throwable) {
                report("error", e.toString())
            }
        }

        private fun report(event: String, message: String) {
            if (done) return
            done = true
            main.post {
                try {
                    channel.invokeMethod(event, message)
                } catch (e: Throwable) {
                }
            }
        }

        private fun releaseCodec() {
            done = true
            val c = codec ?: return
            codec = null
            val stop = Runnable {
                try {
                    c.stop()
                } catch (e: Throwable) {
                }
                try {
                    c.release()
                } catch (e: Throwable) {
                }
            }
            if (!handler.post(stop)) stop.run()
        }

        // The codec stops on its own thread first; the texture goes after it,
        // on the main thread, so nothing draws onto a released surface.
        fun release() {
            if (released) return
            released = true
            done = true
            val c = codec
            codec = null
            val finish = Runnable {
                try {
                    c?.stop()
                } catch (e: Throwable) {
                }
                try {
                    c?.release()
                } catch (e: Throwable) {
                }
                main.post {
                    try {
                        producer.release()
                    } catch (e: Throwable) {
                    }
                }
                thread.quitSafely()
            }
            if (!handler.post(finish)) finish.run()
        }
    }
}

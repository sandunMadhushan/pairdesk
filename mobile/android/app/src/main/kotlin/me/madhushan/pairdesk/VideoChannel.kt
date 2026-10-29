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
                } catch (e: Exception) {
                    stop()
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

    private fun hasDecoder(): Boolean = try {
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, 1280, 720)
        MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format) != null
    } catch (e: Exception) {
        false
    }

    private class Packet(val data: ByteArray, val flags: Int, val pts: Long)

    private inner class Session(width: Int, height: Int) {
        private val producer = textures.createSurfaceProducer()
        val textureId = producer.id()
        private val thread = HandlerThread("pairdesk-video").apply { start() }
        private val handler = Handler(thread.looper)
        private val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)

        // Touched only on the decoder thread.
        private val freeInputs = ArrayDeque<Int>()
        private val pending = ArrayDeque<Packet>()
        @Volatile private var done = false

        init {
            producer.setSize(width, height)
            producer.setCallback(object : TextureRegistry.SurfaceProducer.Callback {
                override fun onSurfaceCleanup() {
                    // The surface goes away (app hidden): this session can't
                    // continue; Dart starts a new one when it's visible again.
                    if (!done) report("lost", "surface released")
                    releaseCodec()
                }
            })
            val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height)
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(width * height, 512 * 1024))
            if (Build.VERSION.SDK_INT >= 30) format.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            codec.setCallback(object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(c: MediaCodec, index: Int) {
                    freeInputs.addLast(index)
                    feed()
                }

                override fun onOutputBufferAvailable(c: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    try {
                        // Show every picture as soon as it's decoded.
                        c.releaseOutputBuffer(index, info.size > 0)
                        if (info.size > 0) producer.scheduleFrame()
                    } catch (e: IllegalStateException) {
                        // Released meanwhile.
                    }
                }

                override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
                    report("error", e.diagnosticInfo ?: e.message ?: "decoder error")
                }

                override fun onOutputFormatChanged(c: MediaCodec, format: MediaFormat) {}
            }, handler)
            codec.configure(format, producer.surface, null, 0)
            codec.start()
        }

        fun queue(p: Packet) {
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
            try {
                while (freeInputs.isNotEmpty() && pending.isNotEmpty()) {
                    val p = pending.removeFirst()
                    val index = freeInputs.removeFirst()
                    val buf = codec.getInputBuffer(index) ?: continue
                    buf.clear()
                    if (p.data.size > buf.capacity()) {
                        report("error", "frame larger than the decoder's buffer")
                        return
                    }
                    buf.put(p.data)
                    codec.queueInputBuffer(index, 0, p.data.size, p.pts, p.flags)
                }
            } catch (e: Exception) {
                report("error", e.message ?: "decoder error")
            }
        }

        private fun report(event: String, message: String) {
            if (done) return
            done = true
            main.post { channel.invokeMethod(event, message) }
        }

        private fun releaseCodec() {
            done = true
            handler.post {
                try {
                    codec.stop()
                } catch (e: Exception) {
                }
                try {
                    codec.release()
                } catch (e: Exception) {
                }
            }
        }

        fun release() {
            releaseCodec()
            handler.post { thread.quitSafely() }
            main.post { producer.release() }
        }
    }
}

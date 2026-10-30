// SPDX-License-Identifier: GPL-3.0-or-later
package me.madhushan.pairdesk

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaCodecList
import android.media.MediaFormat
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

// The "pairdesk/audio" channel: the computer's sound on the phone, and the
// phone's voice for the computer.
//  - opusSupported → whether this phone can decode Opus
//  - startPlayer {codec, rate, channels, preSkip} / play {data} / stopPlayer
//    (an empty packet is 20 ms of silence)
//  - setCallMode {on}: while the person talks: a phone call's audio path,
//    so the phone's echo cancelling hears what it plays (both directions
//    stay open; nothing is muted)
//  - startMic → false if the person said no to the microphone / stopMic
// Events to Dart: "playerError", "mic" (20 ms of 16 kHz mono µ-law),
// "micError".
//
// Everything runs on its own threads and catches everything: a failure
// becomes an event, never a crash. Flutter is only called on the main
// thread.
class AudioChannel(engine: FlutterEngine, private val activity: MainActivity) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "pairdesk/audio")
    private val main = Handler(Looper.getMainLooper())
    private var player: Player? = null
    private var mic: Mic? = null
    private var callMode = false
    private val audioManager = activity.getSystemService(AudioManager::class.java)

    init {
        channel.setMethodCallHandler(this)
    }

    private fun emit(event: String, arg: Any?) {
        main.post {
            try {
                channel.invokeMethod(event, arg)
            } catch (e: Throwable) {
            }
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "opusSupported" -> result.success(opusSupported())
                "startPlayer" -> {
                    player?.stop()
                    player = Player(
                        opus = call.argument<String>("codec") == "opus",
                        rate = call.argument<Int>("rate") ?: 48000,
                        channels = call.argument<Int>("channels") ?: 2,
                        preSkip = call.argument<Int>("preSkip") ?: 0,
                        voice = callMode,
                    )
                    result.success(true)
                }
                "play" -> {
                    call.argument<ByteArray>("data")?.let { player?.offer(it) }
                    result.success(null)
                }
                "stopPlayer" -> {
                    player?.stop()
                    player = null
                    result.success(null)
                }
                "setCallMode" -> {
                    setCallMode(call.argument<Boolean>("on") == true)
                    result.success(null)
                }
                "startMic" -> {
                    val granted = ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) ==
                        PackageManager.PERMISSION_GRANTED
                    if (granted) {
                        startMic()
                        result.success(true)
                    } else {
                        activity.requestMicPermission { ok ->
                            if (ok) startMic()
                            result.success(ok)
                        }
                    }
                }
                "stopMic" -> {
                    mic?.stop()
                    mic = null
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            result.error("audio", e.message ?: e.toString(), null)
        }
    }

    /// Calls play through the voice path (echo cancelled, loudspeaker or
    /// headset); otherwise media. The player restarts on the new path.
    private fun setCallMode(on: Boolean) {
        if (on == callMode) return
        callMode = on
        try {
            if (on) {
                audioManager.mode = AudioManager.MODE_IN_COMMUNICATION
                routeCall()
            } else {
                if (Build.VERSION.SDK_INT >= 31) {
                    audioManager.clearCommunicationDevice()
                } else {
                    @Suppress("DEPRECATION")
                    audioManager.isSpeakerphoneOn = false
                }
                audioManager.mode = AudioManager.MODE_NORMAL
            }
        } catch (e: Throwable) {
        }
        player?.let { p ->
            p.stop()
            player = p.copy(voice = on)
        }
    }

    private val headsets = setOf(
        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_BLUETOOTH_SCO,
    )

    /// A headset if one is plugged in or paired, else the loudspeaker (a
    /// call's default, the earpiece, is too quiet held in front of you).
    private fun routeCall() {
        if (Build.VERSION.SDK_INT >= 31) {
            val devices = audioManager.availableCommunicationDevices
            val pick = devices.firstOrNull { it.type in headsets || it.type == 26 /* BLE headset */ }
                ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
            pick?.let { audioManager.setCommunicationDevice(it) }
        } else {
            val headset = audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any { it.type in headsets }
            @Suppress("DEPRECATION")
            audioManager.isSpeakerphoneOn = !headset
        }
    }

    private fun startMic() {
        mic?.stop()
        mic = Mic()
    }

    fun release() {
        setCallMode(false)
        player?.stop()
        player = null
        mic?.stop()
        mic = null
    }

    private fun opusSupported(): Boolean = try {
        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, 48000, 2)
        MediaCodecList(MediaCodecList.REGULAR_CODECS).findDecoderForFormat(format) != null
    } catch (e: Throwable) {
        false
    }

    /// Plays the computer's sound: Opus (Android's decoder) or 16-bit PCM.
    private inner class Player(
        private val opus: Boolean,
        private val rate: Int,
        private val channels: Int,
        private val preSkip: Int,
        private val voice: Boolean,
    ) {
        fun copy(voice: Boolean) = Player(opus, rate, channels, preSkip, voice)

        private val queue = LinkedBlockingQueue<ByteArray>(100)
        @Volatile private var running = true
        @Volatile private var track: AudioTrack? = null
        private val thread = Thread({ run() }, "pairdesk-audio-out").apply {
            setUncaughtExceptionHandler { _, e -> fail(e) }
            start()
        }

        fun offer(packet: ByteArray) {
            if (!queue.offer(packet)) {
                queue.clear()
                queue.offer(packet)
            }
        }

        fun stop() {
            running = false
            thread.interrupt()
        }

        private fun fail(e: Throwable) {
            if (running) {
                running = false
                emit("playerError", e.message ?: e.toString())
            }
        }

        private fun run() {
            var codec: MediaCodec? = null
            var t: AudioTrack? = null
            try {
                val outChannels = if (channels == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
                val min = AudioTrack.getMinBufferSize(rate, outChannels, AudioFormat.ENCODING_PCM_16BIT)
                // About 100 ms of room: smooth over the network's hiccups.
                val size = maxOf(min, rate * channels * 2 / 10)
                t = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(if (voice) AudioAttributes.USAGE_VOICE_COMMUNICATION else AudioAttributes.USAGE_MEDIA)
                            .setContentType(if (voice) AudioAttributes.CONTENT_TYPE_SPEECH else AudioAttributes.CONTENT_TYPE_MUSIC)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                            .setSampleRate(rate)
                            .setChannelMask(outChannels)
                            .build()
                    )
                    .setBufferSizeInBytes(size)
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .build()
                track = t
                t.play()
                if (opus) codec = openOpus()
                val silence = ByteArray(rate / 50 * channels * 2)
                val info = MediaCodec.BufferInfo()
                var pts = 0L
                while (running) {
                    val packet = queue.poll(100, TimeUnit.MILLISECONDS) ?: continue
                    // Far behind (a burst after a stall): keep the newest.
                    while (queue.size > 8) queue.poll()
                    if (packet.isEmpty()) {
                        t.write(silence, 0, silence.size)
                        continue
                    }
                    val c = codec
                    if (c == null) {
                        t.write(packet, 0, packet.size)
                        continue
                    }
                    val input = c.dequeueInputBuffer(20_000)
                    if (input >= 0) {
                        val buf = c.getInputBuffer(input) ?: continue
                        buf.clear()
                        buf.put(packet)
                        c.queueInputBuffer(input, 0, packet.size, pts, 0)
                        pts += 20_000
                    }
                    while (true) {
                        val out = c.dequeueOutputBuffer(info, 0)
                        if (out < 0) break
                        val buf = c.getOutputBuffer(out)
                        if (buf != null && info.size > 0) {
                            val pcm = ByteArray(info.size)
                            buf.position(info.offset)
                            buf.get(pcm, 0, info.size)
                            t.write(pcm, 0, pcm.size)
                        }
                        c.releaseOutputBuffer(out, false)
                    }
                }
            } catch (e: InterruptedException) {
            } catch (e: Throwable) {
                fail(e)
            } finally {
                track = null
                try {
                    codec?.stop()
                } catch (e: Throwable) {
                }
                try {
                    codec?.release()
                } catch (e: Throwable) {
                }
                try {
                    t?.stop()
                } catch (e: Throwable) {
                }
                try {
                    t?.release()
                } catch (e: Throwable) {
                }
            }
        }

        private fun openOpus(): MediaCodec {
            val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_OPUS, rate, channels)
            // The Ogg Opus header and the two delays Android wants with it.
            val head = ByteBuffer.allocate(19).order(ByteOrder.LITTLE_ENDIAN)
            head.put("OpusHead".toByteArray(Charsets.US_ASCII))
            head.put(1.toByte())
            head.put(channels.toByte())
            head.putShort(preSkip.toShort())
            head.putInt(rate)
            head.putShort(0)
            head.put(0.toByte())
            head.flip()
            format.setByteBuffer("csd-0", head)
            val nanos = { n: Long -> ByteBuffer.allocate(8).order(ByteOrder.nativeOrder()).putLong(n).apply { flip() } }
            format.setByteBuffer("csd-1", nanos(preSkip * 1_000_000_000L / 48000))
            format.setByteBuffer("csd-2", nanos(80_000_000L))
            val c = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_OPUS)
            try {
                c.configure(format, null, null, 0)
                c.start()
            } catch (e: Throwable) {
                c.release()
                throw e
            }
            return c
        }
    }

    /// The phone's microphone: 16 kHz mono, echo cancelled, as µ-law.
    private inner class Mic {
        @Volatile private var running = true
        private val thread = Thread({ run() }, "pairdesk-audio-in").apply {
            setUncaughtExceptionHandler { _, e -> fail(e) }
            start()
        }

        fun stop() {
            running = false
        }

        private fun fail(e: Throwable) {
            if (running) {
                running = false
                emit("micError", e.message ?: e.toString())
            }
        }

        @Suppress("MissingPermission") // checked before a Mic is made
        private fun run() {
            var rec: AudioRecord? = null
            var aec: AcousticEchoCanceler? = null
            var ns: NoiseSuppressor? = null
            try {
                val rate = 16000
                val min = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
                // Voice communication: the phone's own echo cancelling and
                // noise reduction, as in calls.
                rec = AudioRecord(
                    MediaRecorder.AudioSource.VOICE_COMMUNICATION,
                    rate,
                    AudioFormat.CHANNEL_IN_MONO,
                    AudioFormat.ENCODING_PCM_16BIT,
                    maxOf(min, rate / 5 * 2),
                )
                if (rec.state != AudioRecord.STATE_INITIALIZED) throw IllegalStateException("the microphone is busy")
                if (AcousticEchoCanceler.isAvailable()) aec = AcousticEchoCanceler.create(rec.audioSessionId)?.apply { enabled = true }
                if (NoiseSuppressor.isAvailable()) ns = NoiseSuppressor.create(rec.audioSessionId)?.apply { enabled = true }
                rec.startRecording()
                val pcm = ShortArray(320) // 20 ms
                while (running) {
                    var got = 0
                    while (got < pcm.size && running) {
                        val n = rec.read(pcm, got, pcm.size - got)
                        if (n < 0) throw IllegalStateException("microphone error $n")
                        got += n
                    }
                    if (!running) break
                    val ulaw = ByteArray(pcm.size) { ulaw(pcm[it]) }
                    emit("mic", ulaw)
                }
            } catch (e: Throwable) {
                fail(e)
            } finally {
                try {
                    rec?.stop()
                } catch (e: Throwable) {
                }
                try {
                    rec?.release()
                } catch (e: Throwable) {
                }
                try {
                    aec?.release()
                } catch (e: Throwable) {
                }
                try {
                    ns?.release()
                } catch (e: Throwable) {
                }
            }
        }
    }

    companion object {
        /// G.711 µ-law, as the computer expects.
        fun ulaw(sample: Short): Byte {
            var s = sample.toInt()
            var sign = 0
            if (s < 0) {
                s = -s
                sign = 0x80
            }
            s = minOf(s, 32635) + 0x84
            var exponent = 7
            var mask = 0x4000
            while ((s and mask) == 0 && exponent > 0) {
                exponent--
                mask = mask shr 1
            }
            val mantissa = (s shr (exponent + 3)) and 0x0f
            return (sign or (exponent shl 4) or mantissa).inv().toByte()
        }
    }
}

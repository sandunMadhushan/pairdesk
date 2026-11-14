// SPDX-License-Identifier: GPL-3.0-or-later
// The "pairdesk/audio" channel on iPhone, the same methods as
// android/.../AudioChannel.kt so lib/audio/native_audio.dart is unchanged:
//  - opusSupported → false for now: the computer then sends 16-bit PCM
//  - startPlayer {codec, rate, channels} / play {data} / stopPlayer:
//    the computer's sound
//  - setCallMode {on}: while talking, the voice-chat path (echo cancelling)
//  - startMic → false if the microphone isn't allowed; then "mic" events
//    with 20 ms of 16 kHz mono µ-law each / stopMic
// Events to Dart: "playerError", "mic", "micError".

import AVFoundation
import Flutter

final class AudioChannel: NSObject {
  private let channel: FlutterMethodChannel
  private let engine = AVAudioEngine()
  private let lock = NSLock()

  private var player: AVAudioPlayerNode?
  private var playFormat: AVAudioFormat?
  private var queued = 0  // buffers scheduled and not played yet (under lock)
  private var started = false
  private var callMode = false
  private var micOn = false
  private var tapInstalled = false
  private var converter: AVAudioConverter?
  private var micPending = [Int16]()
  private let micFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

  /// About 240 ms of sound: more than this waiting means the phone fell
  /// behind, and late sound is worse than a skipped bit.
  private let maxQueued = 12
  /// Start playing once this many are waiting, to ride out network jitter.
  private let prebuffer = 3

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "pairdesk/audio", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
    NotificationCenter.default.addObserver(
      self, selector: #selector(interrupted(_:)),
      name: AVAudioSession.interruptionNotification, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(routeChanged(_:)),
      name: AVAudioSession.routeChangeNotification, object: nil)
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "opusSupported":
      result(false)
    case "startPlayer":
      if (args["codec"] as? String) == "opus" {
        result(FlutterError(code: "audio", message: "Opus isn't supported on this phone", details: nil))
        return
      }
      let rate = (args["rate"] as? NSNumber)?.doubleValue ?? 48000
      let channels = (args["channels"] as? NSNumber)?.uint32Value ?? 2
      stopPlayer()
      guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels) else {
        result(FlutterError(code: "audio", message: "Unsupported sound format", details: nil))
        return
      }
      let node = AVAudioPlayerNode()
      engine.attach(node)
      player = node
      playFormat = format
      reconfigure()
      result(true)
    case "play":
      if let data = (args["data"] as? FlutterStandardTypedData)?.data { play(data) }
      result(nil)
    case "stopPlayer":
      stopPlayer()
      reconfigure()
      result(nil)
    case "setCallMode":
      let on = (args["on"] as? Bool) == true
      if on != callMode {
        callMode = on
        reconfigure()
      }
      result(nil)
    case "startMic":
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        DispatchQueue.main.async {
          if granted {
            self.micOn = true
            self.reconfigure()
          }
          result(granted)
        }
      }
    case "stopMic":
      micOn = false
      reconfigure()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Session and engine

  /// Puts the audio session and the engine in the state the current
  /// player / microphone / call mode need. Called on the main thread.
  private func reconfigure() {
    engine.stop()
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    let session = AVAudioSession.sharedInstance()
    let needsInput = micOn || callMode
    do {
      if needsInput {
        try session.setCategory(
          .playAndRecord, mode: .voiceChat,
          options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
      } else {
        try session.setCategory(.playback, mode: .default, options: [])
      }
      if player == nil && !micOn {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        return
      }
      try session.setActive(true)
      // Echo cancelling: the voice-processing unit takes the speaker's
      // sound back out of what the microphone hears.
      if needsInput != engine.inputNode.isVoiceProcessingEnabled {
        try engine.inputNode.setVoiceProcessingEnabled(needsInput)
      }
    } catch {
      emit("playerError", "Sound: \(error.localizedDescription)")
      return
    }
    if let node = player, let format = playFormat {
      engine.disconnectNodeOutput(node)
      engine.connect(node, to: engine.mainMixerNode, format: format)
    }
    if micOn { installTap() }
    do {
      engine.prepare()
      try engine.start()
      lock.lock()
      let ready = queued >= prebuffer || started
      lock.unlock()
      if ready { player?.play() }
    } catch {
      emit(micOn ? "micError" : "playerError", "Sound: \(error.localizedDescription)")
    }
  }

  private func stopPlayer() {
    if let node = player {
      node.stop()
      engine.detach(node)
    }
    player = nil
    playFormat = nil
    lock.lock()
    queued = 0
    lock.unlock()
    started = false
  }

  @objc private func interrupted(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      AVAudioSession.InterruptionType(rawValue: raw) == .ended
    else { return }
    DispatchQueue.main.async { self.reconfigure() }
  }

  @objc private func routeChanged(_ note: Notification) {
    // Headphones in or out: the engine's formats change under it.
    DispatchQueue.main.async {
      if self.player != nil || self.micOn { self.reconfigure() }
    }
  }

  // MARK: - The computer's sound

  private func play(_ data: Data) {
    guard let node = player, let format = playFormat else { return }
    let channels = Int(format.channelCount)
    var frames = data.count / (2 * channels)
    if frames == 0 { frames = Int(format.sampleRate / 50) }  // empty packet: 20 ms of silence
    lock.lock()
    if queued >= maxQueued {
      lock.unlock()
      return
    }
    queued += 1
    let count = queued
    lock.unlock()
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
      let out = buffer.floatChannelData
    else { return }
    buffer.frameLength = AVAudioFrameCount(frames)
    if data.count >= frames * 2 * channels {
      data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for i in 0..<frames {
          for c in 0..<channels {
            let at = (i * channels + c) * 2
            let sample = Int16(bitPattern: UInt16(raw[at]) | UInt16(raw[at + 1]) << 8)
            out[c][i] = Float(sample) / 32768
          }
        }
      }
    } else {
      for c in 0..<channels { out[c].update(repeating: 0, count: frames) }
    }
    node.scheduleBuffer(buffer) { [weak self] in
      guard let self = self else { return }
      self.lock.lock()
      self.queued = max(0, self.queued - 1)
      self.lock.unlock()
    }
    if !started && count >= prebuffer && engine.isRunning {
      started = true
      node.play()
    }
  }

  // MARK: - Microphone

  private func installTap() {
    let input = engine.inputNode
    let hw = input.outputFormat(forBus: 0)
    guard hw.channelCount > 0, hw.sampleRate > 0 else {
      emit("micError", "No microphone available.")
      return
    }
    converter = AVAudioConverter(from: hw, to: micFormat)
    micPending.removeAll()
    input.installTap(onBus: 0, bufferSize: 1024, format: hw) { [weak self] buffer, _ in
      self?.onMic(buffer)
    }
    tapInstalled = true
  }

  /// On the audio thread: down to 16 kHz mono, then 20 ms µ-law chunks.
  private func onMic(_ buffer: AVAudioPCMBuffer) {
    guard let converter = converter else { return }
    let ratio = micFormat.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: capacity) else { return }
    var fed = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
      if fed {
        status.pointee = .noDataNow
        return nil
      }
      fed = true
      status.pointee = .haveData
      return buffer
    }
    guard error == nil, let samples = out.int16ChannelData?[0] else { return }
    micPending.append(contentsOf: UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
    while micPending.count >= 320 {
      let chunk = Data(micPending.prefix(320).map { Self.ulaw($0) })
      micPending.removeFirst(320)
      emit("mic", FlutterStandardTypedData(bytes: chunk))
    }
  }

  /// G.711 µ-law, as the computer expects.
  static func ulaw(_ sample: Int16) -> UInt8 {
    var s = Int(sample)
    var sign = 0
    if s < 0 {
      s = -s
      sign = 0x80
    }
    s = min(s, 32635) + 0x84
    var exponent = 7
    var mask = 0x4000
    while s & mask == 0 && exponent > 0 {
      exponent -= 1
      mask >>= 1
    }
    let mantissa = (s >> (exponent + 3)) & 0x0f
    return ~UInt8(sign | (exponent << 4) | mantissa)
  }

  private func emit(_ event: String, _ argument: Any?) {
    DispatchQueue.main.async { self.channel.invokeMethod(event, arguments: argument) }
  }
}

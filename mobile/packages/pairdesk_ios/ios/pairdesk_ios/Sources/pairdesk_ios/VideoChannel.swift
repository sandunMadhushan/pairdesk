// SPDX-License-Identifier: GPL-3.0-or-later
// The "pairdesk/video" channel on iPhone, the same methods as
// android/.../VideoChannel.kt so lib/screen/video.dart is unchanged:
//  - supported → true when the phone decodes H.264 in hardware
//  - start {width, height} → texture id
//  - decode {config, frame, key, pts}: one access unit, Annex B (start
//    codes); config holds the SPS and PPS of a key frame
//  - stop
// Events to Dart: "error" (Dart switches to JPEG) and "lost" (iOS dropped
// the decoder, e.g. in the background: Dart starts again).
//
// VideoToolbox decodes into IOSurface-backed BGRA pixel buffers, which
// Flutter draws straight from its texture.

import CoreMedia
import Flutter
import VideoToolbox

final class VideoChannel: NSObject {
  private let channel: FlutterMethodChannel
  private let textures: FlutterTextureRegistry
  private var stream: Stream?

  init(messenger: FlutterBinaryMessenger, textures: FlutterTextureRegistry) {
    channel = FlutterMethodChannel(name: "pairdesk/video", binaryMessenger: messenger)
    self.textures = textures
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "supported":
      result(VTIsHardwareDecodeSupported(kCMVideoCodecType_H264))
    case "start":
      stop()
      let width = (args["width"] as? NSNumber)?.intValue ?? 0
      let height = (args["height"] as? NSNumber)?.intValue ?? 0
      guard (16...8192).contains(width), (16...8192).contains(height) else {
        result(FlutterError(code: "start", message: "bad video size \(width)x\(height)", details: nil))
        return
      }
      let s = Stream(textures: textures) { [weak self] event, message in
        DispatchQueue.main.async { self?.channel.invokeMethod(event, arguments: message) }
      }
      s.id = textures.register(s)
      stream = s
      result(s.id)
    case "decode":
      guard let s = stream, let frame = (args["frame"] as? FlutterStandardTypedData)?.data else {
        result(nil)
        return
      }
      let config = (args["config"] as? FlutterStandardTypedData)?.data
      s.decode(config: config, frame: frame)
      result(nil)
    case "stop":
      stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func stop() {
    guard let s = stream else { return }
    stream = nil
    s.close()
    textures.unregisterTexture(s.id)
  }
}

/// One decoder drawing onto one Flutter texture.
private final class Stream: NSObject, FlutterTexture {
  var id: Int64 = 0
  private weak var textures: FlutterTextureRegistry?
  private let report: (String, String) -> Void
  private let lock = NSLock()
  private var latest: CVPixelBuffer?  // under lock
  private var format: CMVideoFormatDescription?
  private var session: VTDecompressionSession?
  private var closed = false
  private var failed = false

  init(textures: FlutterTextureRegistry, report: @escaping (String, String) -> Void) {
    self.textures = textures
    self.report = report
  }

  // Flutter asks for the newest picture when it draws.
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    guard let buffer = latest else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  func close() {
    closed = true
    if let s = session {
      VTDecompressionSessionWaitForAsynchronousFrames(s)
      VTDecompressionSessionInvalidate(s)
    }
    session = nil
    lock.lock()
    latest = nil
    lock.unlock()
  }

  /// On the main thread (the channel's).
  func decode(config: Data?, frame: Data) {
    guard !closed, !failed else { return }
    if let config = config, !makeSession(config) { return }
    guard let session = session, let format = format else { return }  // waiting for a key frame
    guard let sample = Self.sampleBuffer(annexB: frame, format: format) else { return }
    let status = VTDecompressionSessionDecodeFrame(
      session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression],
      infoFlagsOut: nil
    ) { [weak self] status, _, image, _, _ in
      self?.decoded(status, image)
    }
    if status == kVTInvalidSessionErr {
      lost()
    } else if status != noErr {
      fail("decode failed (\(status))")
    }
  }

  private func decoded(_ status: OSStatus, _ image: CVImageBuffer?) {
    if status == kVTInvalidSessionErr {
      DispatchQueue.main.async { self.lost() }
      return
    }
    guard status == noErr, let image = image else {
      if status != noErr { DispatchQueue.main.async { self.fail("decoder error (\(status))") } }
      return
    }
    lock.lock()
    latest = image
    lock.unlock()
    DispatchQueue.main.async {
      if !self.closed { self.textures?.textureFrameAvailable(self.id) }
    }
  }

  private func lost() {
    guard !failed, !closed else { return }
    failed = true
    report("lost", "the video decoder went away")
  }

  private func fail(_ message: String) {
    guard !failed, !closed else { return }
    failed = true
    report("error", message)
  }

  /// A new SPS/PPS: (re)creates the decoder if the format changed.
  private func makeSession(_ config: Data) -> Bool {
    let nals = Self.nalUnits(config)
    guard let sps = nals.first(where: { ($0.first ?? 0) & 0x1f == 7 }),
      let pps = nals.first(where: { ($0.first ?? 0) & 0x1f == 8 })
    else { return session != nil }
    var newFormat: CMFormatDescription?
    let status = sps.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> OSStatus in
      pps.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> OSStatus in
        let pointers = [
          s.baseAddress!.assumingMemoryBound(to: UInt8.self),
          p.baseAddress!.assumingMemoryBound(to: UInt8.self),
        ]
        let sizes = [sps.count, pps.count]
        return CMVideoFormatDescriptionCreateFromH264ParameterSets(
          allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: pointers,
          parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
      }
    }
    guard status == noErr, let f = newFormat else {
      fail("bad video parameters (\(status))")
      return false
    }
    if let s = session, let old = format, CMFormatDescriptionEqual(old, otherFormatDescription: f) {
      _ = s
      return true
    }
    if let s = session {
      VTDecompressionSessionWaitForAsynchronousFrames(s)
      VTDecompressionSessionInvalidate(s)
      session = nil
    }
    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
      kCVPixelBufferMetalCompatibilityKey: true,
    ]
    var created: VTDecompressionSession?
    let made = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault, formatDescription: f, decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
      decompressionSessionOut: &created)
    guard made == noErr, let s = created else {
      fail("can't start the video decoder (\(made))")
      return false
    }
    VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
    session = s
    format = f
    return true
  }

  /// The NAL units of an Annex B stream, without their start codes.
  static func nalUnits(_ data: Data) -> [Data] {
    let bytes = [UInt8](data)
    var starts = [Int]()  // first byte after each start code
    var codes = [Int]()  // where each start code begins
    var i = 0
    while i + 2 < bytes.count {
      if bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1 {
        codes.append(i > 0 && bytes[i - 1] == 0 ? i - 1 : i)
        starts.append(i + 3)
        i += 3
      } else {
        i += 1
      }
    }
    if starts.isEmpty { return bytes.isEmpty ? [] : [data] }
    var units = [Data]()
    for n in 0..<starts.count {
      let end = n + 1 < starts.count ? codes[n + 1] : bytes.count
      if starts[n] < end { units.append(Data(bytes[starts[n]..<end])) }
    }
    return units
  }

  /// Annex B → one sample with 4-byte length prefixes (AVCC), leaving out
  /// parameter sets and access unit delimiters.
  static func sampleBuffer(annexB: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
    var avcc = Data()
    for nal in nalUnits(annexB) {
      let type = (nal.first ?? 0) & 0x1f
      if type == 7 || type == 8 || type == 9 { continue }
      var length = UInt32(nal.count).bigEndian
      avcc.append(Data(bytes: &length, count: 4))
      avcc.append(nal)
    }
    if avcc.isEmpty { return nil }
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
      blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
      dataLength: avcc.count, flags: 0, blockBufferOut: &block)
    guard status == kCMBlockBufferNoErr, let block = block else { return nil }
    status = avcc.withUnsafeBytes { raw in
      CMBlockBufferReplaceDataBytes(
        with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
    }
    guard status == kCMBlockBufferNoErr else { return nil }
    var sample: CMSampleBuffer?
    var size = avcc.count
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
      sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
      sampleSizeArray: &size, sampleBufferOut: &sample)
    return status == noErr ? sample : nil
  }
}

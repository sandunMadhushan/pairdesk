// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) Sandun Madhushan.
import Flutter
import QuickLook
import UIKit
import UniformTypeIdentifiers

// PairDesk's iPhone plugin: the "pairdesk/files" channel here, sound in
// AudioChannel.swift and screen video in VideoChannel.swift.
//
// The "pairdesk/files" channel on iPhone. Same methods as
// android/.../MainActivity.kt, so lib/files/native_files.dart is unchanged:
//  - pickFiles: the Files picker; picked files are copied to the cache
//  - takeShared: the pairdesk:// link that opened the app (files and text
//    sharing come with the Share Extension later)
//  - saveToDownloads: moves a received file into the app's Documents folder,
//    which the Files app shows under On My iPhone > PairDesk
//  - openFile: previews a received file with Quick Look
public class PairdeskIosPlugin: NSObject, FlutterPlugin, FlutterSceneLifeCycleDelegate,
  UIDocumentPickerDelegate, QLPreviewControllerDataSource
{
  private let channel: FlutterMethodChannel
  private var pendingLink: String?
  private var pickResult: FlutterResult?
  private var previewURL: URL?
  private let io = DispatchQueue(label: "me.madhushan.pairdesk.files", qos: .userInitiated)

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  // The sound and screen-video channels live as long as the plugin.
  private var audio: AudioChannel?
  private var video: VideoChannel?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "pairdesk/files", binaryMessenger: registrar.messenger())
    let instance = PairdeskIosPlugin(channel: channel)
    instance.audio = AudioChannel(messenger: registrar.messenger())
    instance.video = VideoChannel(messenger: registrar.messenger(), textures: registrar.textures())
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
    registrar.addSceneDelegate(instance)
  }

  // MARK: - Channel

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "pickFiles":
      pickFiles(result)
    case "takeShared":
      let link: Any = pendingLink ?? NSNull()
      pendingLink = nil
      result(["files": [Any](), "text": NSNull(), "link": link])
    case "saveToDownloads":
      guard let args = call.arguments as? [String: Any],
        let path = args["path"] as? String, let name = args["name"] as? String
      else {
        result(FlutterError(code: "save", message: "Missing file", details: nil))
        return
      }
      io.async {
        do {
          let saved = try Self.saveToDocuments(from: URL(fileURLWithPath: path), name: name)
          DispatchQueue.main.async { result(saved) }
        } catch {
          DispatchQueue.main.async {
            result(FlutterError(code: "save", message: error.localizedDescription, details: nil))
          }
        }
      }
    case "openFile":
      guard let args = call.arguments as? [String: Any],
        let uri = args["uri"] as? String, let url = URL(string: uri), url.isFileURL
      else {
        result(false)
        return
      }
      result(preview(url))
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Picking

  private func pickFiles(_ result: @escaping FlutterResult) {
    // A new request replaces one still open.
    pickResult?([Any]())
    guard let top = Self.topViewController() else {
      pickResult = nil
      result(FlutterError(code: "picker", message: "Can't show the file picker.", details: nil))
      return
    }
    pickResult = result
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
    picker.allowsMultipleSelection = true
    picker.delegate = self
    top.present(picker, animated: true)
  }

  public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let result = pickResult else { return }
    pickResult = nil
    // Copy off the main thread (files can be big). Each pick gets its own
    // folder: Dart deletes a sent file's folder, and the picker's own copies
    // all share one.
    io.async {
      var files = [[String: String]]()
      for url in urls {
        if let f = try? Self.copyToCache(url) { files.append(f) }
      }
      DispatchQueue.main.async { result(files) }
    }
  }

  public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let result = pickResult
    pickResult = nil
    result?([Any]())
  }

  private static func copyToCache(_ url: URL) throws -> [String: String] {
    let fm = FileManager.default
    let name = cleanName(url.lastPathComponent)
    let dir = fm.temporaryDirectory.appendingPathComponent("outgoing", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent(name)
    try fm.copyItem(at: url, to: dest)
    return ["path": dest.path, "name": name]
  }

  // MARK: - Received files

  /// Moves [from] into Documents, as "name", or "name (2).ext" if taken.
  private static func saveToDocuments(from temp: URL, name: String) throws -> [String: String] {
    let fm = FileManager.default
    let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let clean = cleanName(name)
    let stem = (clean as NSString).deletingPathExtension
    let ext = (clean as NSString).pathExtension
    var dest = docs.appendingPathComponent(clean)
    var n = 2
    while fm.fileExists(atPath: dest.path) {
      let numbered = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
      dest = docs.appendingPathComponent(numbered)
      n += 1
    }
    do {
      try fm.moveItem(at: temp, to: dest)
    } catch {
      try fm.copyItem(at: temp, to: dest)
      try? fm.removeItem(at: temp)
    }
    return [
      "where": "Files \u{203A} On My iPhone \u{203A} PairDesk \u{203A} \(dest.lastPathComponent)",
      "uri": dest.absoluteString,
    ]
  }

  private static func cleanName(_ name: String) -> String {
    let n = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return n.isEmpty ? "file" : n
  }

  // MARK: - Quick Look

  /// Shows a preview; false if iOS can't preview this kind of file.
  private func preview(_ url: URL) -> Bool {
    guard FileManager.default.fileExists(atPath: url.path),
      QLPreviewController.canPreview(url as NSURL),
      let top = Self.topViewController()
    else { return false }
    previewURL = url
    let ql = QLPreviewController()
    ql.dataSource = self
    top.present(ql, animated: true)
    return true
  }

  public func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
    previewURL == nil ? 0 : 1
  }

  public func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
    (previewURL ?? URL(fileURLWithPath: "/")) as NSURL
  }

  private static func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window =
      scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  // MARK: - Pairing links (pairdesk://pair… and the web pairing link)

  /// Keeps a PairDesk link for Dart to take; ignores anything else.
  @discardableResult
  private func accept(_ url: URL) -> Bool {
    let link = url.absoluteString
    guard link.hasPrefix("pairdesk://pair") || link.hasPrefix("https://pairdesk.madhushan.me/p") else {
      return false
    }
    pendingLink = link
    channel.invokeMethod("shared", arguments: nil)
    return true
  }

  // Older app-delegate route (the scene route below is the normal one).
  public func application(
    _ application: UIApplication, open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    accept(url)
  }

  // Cold start from a link.
  public func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    var took = false
    for context in connectionOptions?.urlContexts ?? [] where accept(context.url) { took = true }
    return took
  }

  // Link opened while the app is running.
  public func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    var took = false
    for context in URLContexts where accept(context.url) { took = true }
    return took
  }
}

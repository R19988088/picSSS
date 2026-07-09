import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  private let nativeImageView = NSImageView()

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    let rootViewController = NSViewController()
    let rootView = NSView(frame: NSRect(origin: .zero, size: windowFrame.size))
    makeFlutterBackgroundTransparent(flutterViewController)

    rootView.wantsLayer = true
    rootView.layer?.backgroundColor = NSColor.clear.cgColor

    nativeImageView.frame = rootView.bounds
    nativeImageView.autoresizingMask = [.width, .height]
    nativeImageView.imageAlignment = .alignCenter
    nativeImageView.imageScaling = .scaleProportionallyUpOrDown
    nativeImageView.wantsLayer = true
    nativeImageView.layer?.backgroundColor = NSColor.black.cgColor

    let flutterView = flutterViewController.view
    flutterView.frame = rootView.bounds
    flutterView.autoresizingMask = [.width, .height]
    flutterView.wantsLayer = true
    flutterView.layer?.backgroundColor = NSColor.clear.cgColor

    rootView.addSubview(nativeImageView)
    rootView.addSubview(flutterView)
    rootViewController.addChild(flutterViewController)
    rootViewController.view = rootView
    self.contentViewController = rootViewController
    self.setFrame(windowFrame, display: true)
    self.isOpaque = false
    self.backgroundColor = .clear

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerWindowChannel(flutterViewController: flutterViewController)
    registerNativeImageChannel(flutterViewController: flutterViewController)

    super.awakeFromNib()
  }

  private func makeFlutterBackgroundTransparent(_ flutterViewController: FlutterViewController) {
    let selector = Selector(("setBackgroundColor:"))
    if flutterViewController.responds(to: selector) {
      flutterViewController.perform(selector, with: NSColor.clear)
      logPicSSS("flutter background set to clear")
    } else {
      logPicSSS("flutter background clear selector unavailable")
    }
  }

  private func registerWindowChannel(flutterViewController: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "picsss/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "window_gone", message: "Window no longer exists", details: nil))
        return
      }

      switch call.method {
      case "close":
        self.close()
        result(nil)
      case "minimize":
        self.miniaturize(nil)
        result(nil)
      case "maximize":
        self.zoom(nil)
        result(nil)
      case "drag":
        if let event = NSApp.currentEvent {
          self.performDrag(with: event)
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func registerNativeImageChannel(flutterViewController: FlutterViewController) {
    let channel = FlutterMethodChannel(
      name: "picsss/native_image",
      binaryMessenger: flutterViewController.engine.binaryMessenger)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "window_gone", message: "Window no longer exists", details: nil))
        return
      }

      switch call.method {
      case "show":
        guard
          let args = call.arguments as? [String: Any],
          let path = args["path"] as? String
        else {
          result(FlutterError(code: "bad_args", message: "Missing image path", details: nil))
          return
        }
        self.showNativeImage(path: path, fill: (args["fill"] as? Bool) ?? false)
        result(nil)
      case "clear":
        self.nativeImageView.image = nil
        logPicSSS("native image cleared")
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func showNativeImage(path: String, fill: Bool) {
    guard let image = NSImage(contentsOfFile: path) else {
      logPicSSS("native image load failed: \(path)")
      return
    }
    nativeImageView.imageScaling = fill ? .scaleAxesIndependently : .scaleProportionallyUpOrDown
    nativeImageView.image = image
    logPicSSS("native image loaded: \(path) size=\(image.size.width)x\(image.size.height)")
  }

  private func logPicSSS(_ message: String) {
    NSLog("[picSSS] \(message)")
    guard let home = ProcessInfo.processInfo.environment["HOME"] else {
      return
    }
    let url = URL(fileURLWithPath: home)
      .appendingPathComponent("Library")
      .appendingPathComponent("Logs")
      .appendingPathComponent("picSSS.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) [picSSS] \(message)\n"
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
      if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: url.path) {
          let handle = try FileHandle(forWritingTo: url)
          handle.seekToEndOfFile()
          handle.write(data)
          handle.closeFile()
        } else {
          try data.write(to: url)
        }
      }
    } catch {
      NSLog("[picSSS] log write failed: \(error)")
    }
  }
}

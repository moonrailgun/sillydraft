import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.title = "SillyDraft"
    self.minSize = NSSize(width: 480, height: 540)
    self.setFrameAutosaveName("SillyDraftWorkspace")
    if !self.setFrameUsingName("SillyDraftWorkspace") {
      self.setContentSize(NSSize(width: 1180, height: 800))
      self.center()
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    FlutterMethodChannel(name: "app.sillydraft/files", binaryMessenger: flutterViewController.engine.binaryMessenger)
      .setMethodCallHandler { call, result in
        guard call.method == "saveAtomic" else { result(FlutterMethodNotImplemented); return }
        guard let arguments = call.arguments as? [String: Any],
              let path = arguments["path"] as? String,
              let bytes = arguments["bytes"] as? FlutterStandardTypedData else {
          result(FlutterError(code: "invalid_arguments", message: "无效的导出文件", details: nil)); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            try AtomicFileExport.write(bytes.data, to: URL(fileURLWithPath: path))
            DispatchQueue.main.async { result(nil) }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "save_failed", message: "无法保存文件：\(error.localizedDescription)", details: nil))
            }
          }
        }
      }

    super.awakeFromNib()
  }
}

enum AtomicFileExport {
  static func write(_ data: Data, to destination: URL) throws {
    let manager = FileManager.default
    let accessing = destination.startAccessingSecurityScopedResource()
    defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
    // NSSavePanel grants the selected file, not arbitrary siblings. Foundation
    // supplies a writable replacement directory on the destination's volume.
    let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                  appropriateFor: destination, create: true)
    defer { try? manager.removeItem(at: staging) }
    let prepared = staging.appendingPathComponent("export")
    try data.write(to: prepared)
    if manager.fileExists(atPath: destination.path) {
      _ = try manager.replaceItemAt(destination, withItemAt: prepared)
    } else {
      try manager.moveItem(at: prepared, to: destination)
    }
  }
}

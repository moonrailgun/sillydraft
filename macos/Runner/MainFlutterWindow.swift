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

    super.awakeFromNib()
  }
}

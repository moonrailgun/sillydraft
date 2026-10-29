import Cocoa
import FlutterMacOS
import IOKit.hidsystem

final class SillyDraftApplication: NSApplication {
  override func sendEvent(_ event: NSEvent) {
    let commandDeviceMask = UInt(NX_DEVICELCMDKEYMASK | NX_DEVICERCMDKEYMASK)
    guard (event.type == .keyDown || event.type == .keyUp),
          event.modifierFlags.contains(.command),
          event.modifierFlags.rawValue & commandDeviceMask == 0,
          let cgEvent = event.cgEvent?.copy() else {
      super.sendEvent(event)
      return
    }

    // shortcut: Flutter 3.47.7 needs a device bit; remove when flutter/flutter#178609 is fixed.
    // Normalize before AppKit key equivalents and Flutter's local keyUp monitor.
    cgEvent.flags = CGEventFlags(rawValue: cgEvent.flags.rawValue | UInt64(NX_DEVICELCMDKEYMASK))
    super.sendEvent(NSEvent(cgEvent: cgEvent) ?? event)
  }
}

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

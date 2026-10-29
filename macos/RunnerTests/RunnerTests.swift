import Cocoa
import FlutterMacOS
import IOKit.hidsystem
import WebKit
import XCTest
@testable import SillyDraft

class RunnerTests: XCTestCase {
  @MainActor
  func testTransparentWebViewPreservesHtmlBackgrounds() throws {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
    let window = NSWindow(contentRect: webView.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = webView
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    XCTAssertNil(MainFlutterWindow.makeWebViewTransparent(webView))
    let loaded = expectation(description: "HTML loaded")
    let navigation = HtmlNavigationWaiter(loaded)
    webView.navigationDelegate = navigation
    webView.loadHTMLString("<html><body style='margin:0'><div style='width:40px;height:40px;background:#00ff00'></div></body></html>", baseURL: nil)
    wait(for: [loaded], timeout: 10)
    let captured = expectation(description: "WebView snapshot")
    webView.takeSnapshot(with: nil) { image, error in
      defer { captured.fulfill() }
      XCTAssertNil(error)
      guard let data = image?.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: data),
            let card = bitmap.colorAt(x: bitmap.pixelsWide / 4, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB),
            let background = bitmap.colorAt(x: bitmap.pixelsWide * 3 / 4, y: bitmap.pixelsHigh / 2) else {
        XCTFail("No rendered pixels"); return
      }
      XCTAssertEqual(background.alphaComponent, 0, accuracy: 0.01, "Unstyled areas must show the reader beneath")
      XCTAssertEqual(card.alphaComponent, 1, accuracy: 0.01)
      // Allow display color-profile conversion while checking the authored green remains opaque.
      XCTAssertGreaterThan(card.greenComponent, 0.9, "Authored backgrounds must remain visible")
      XCTAssertLessThan(card.redComponent, 0.1)
    }
    wait(for: [captured], timeout: 10)
  }

  func testAtomicExportCreatesAndReplacesSelectedFile() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("novel.epub")
    try AtomicFileExport.write(Data("first".utf8), to: destination)
    XCTAssertEqual(try Data(contentsOf: destination), Data("first".utf8))
    try AtomicFileExport.write(Data("replacement".utf8), to: destination)
    XCTAssertEqual(try Data(contentsOf: destination), Data("replacement".utf8))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["novel.epub"])
  }

  func testFailedExportPreservesExistingFile() throws {
    let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("original".utf8).write(to: destination)
    defer { try? FileManager.default.removeItem(at: destination) }
    // An invalid destination under a regular file fails before replacing it.
    XCTAssertThrowsError(try AtomicFileExport.write(Data("new".utf8), to: destination.appendingPathComponent("child")))
    XCTAssertEqual(try Data(contentsOf: destination), Data("original".utf8))
  }
}

private final class HtmlNavigationWaiter: NSObject, WKNavigationDelegate {
  let loaded: XCTestExpectation
  init(_ loaded: XCTestExpectation) { self.loaded = loaded }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    loaded.fulfill()
  }
}

@MainActor
final class CommandEventTests: XCTestCase {
  private let leftCommand = UInt(NX_DEVICELCMDKEYMASK)
  private let rightCommand = UInt(NX_DEVICERCMDKEYMASK)
  private lazy var window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 80, height: 40),
    styleMask: .borderless, backing: .buffered, defer: false)

  func testSyntheticCommandDownAndUpAreNormalizedBeforeLocalMonitors() throws {
    XCTAssertTrue(NSApplication.shared is SillyDraftApplication)
    for type: NSEvent.EventType in [.keyDown, .keyUp] {
      let original = try keyEvent(type: type, flags: .command)
      let forwarded = try dispatch(original)

      XCTAssertEqual(forwarded.modifierFlags.rawValue, NSEvent.ModifierFlags.command.rawValue | leftCommand)
      XCTAssertEqual(original.modifierFlags, .command, "The incoming event must not be mutated")
      XCTAssertFalse(forwarded === original)
    }
  }

  func testNormalizationPreservesKeyboardEventInformation() throws {
    for type: NSEvent.EventType in [.keyDown, .keyUp] {
      let cgEvent = try XCTUnwrap(keyEvent(
        type: type, flags: [.command, .shift, .option], repeatKey: true).cgEvent)
      cgEvent.setIntegerValueField(.eventSourceUserData, value: 123456)
      cgEvent.setIntegerValueField(.keyboardEventKeyboardType, value: 40)
      let original = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
      let forwarded = try dispatch(original)
      let forwardedCGEvent = try XCTUnwrap(forwarded.cgEvent)

      XCTAssertEqual(forwarded.type, original.type)
      XCTAssertEqual(forwarded.keyCode, original.keyCode)
      XCTAssertEqual(forwarded.characters, original.characters)
      XCTAssertEqual(forwarded.charactersIgnoringModifiers, original.charactersIgnoringModifiers)
      XCTAssertEqual(forwarded.timestamp, original.timestamp)
      XCTAssertEqual(forwarded.locationInWindow, original.locationInWindow)
      XCTAssertEqual(forwarded.windowNumber, original.windowNumber)
      XCTAssertEqual(forwarded.isARepeat, original.isARepeat)
      XCTAssertEqual(forwarded.modifierFlags.rawValue, original.modifierFlags.rawValue | leftCommand)
      XCTAssertEqual(forwardedCGEvent.timestamp, cgEvent.timestamp)
      XCTAssertEqual(forwardedCGEvent.getIntegerValueField(.eventSourceUserData), 123456)
      XCTAssertEqual(forwardedCGEvent.getIntegerValueField(.keyboardEventKeyboardType), 40)
      XCTAssertEqual(cgEvent.flags.rawValue, UInt64(original.modifierFlags.rawValue))
    }
  }

  func testOrdinaryKeysAndPhysicalCommandEventsKeepTheirIdentity() throws {
    let flags: [NSEvent.ModifierFlags] = [
      [], [.shift, .option, .control], .init(rawValue: leftCommand | rightCommand),
      .init(rawValue: NSEvent.ModifierFlags.command.rawValue | leftCommand),
      .init(rawValue: NSEvent.ModifierFlags.command.rawValue | rightCommand),
      .init(rawValue: NSEvent.ModifierFlags.command.rawValue | leftCommand | rightCommand),
    ]
    for type: NSEvent.EventType in [.keyDown, .keyUp] {
      for modifiers in flags {
        let original = try keyEvent(type: type, flags: modifiers)
        XCTAssertTrue(try dispatch(original) === original)
        XCTAssertEqual(original.modifierFlags, modifiers)
      }
    }
  }

  func testOtherEventTypesKeepTheirIdentity() throws {
    let flagsChanged = try keyEvent(type: .flagsChanged, flags: .command)
    let mouse = try XCTUnwrap(NSEvent.mouseEvent(
      with: .leftMouseDown, location: NSPoint(x: 15, y: 25), modifierFlags: .command,
      timestamp: 123, windowNumber: window.windowNumber, context: nil,
      eventNumber: 1, clickCount: 2, pressure: 1))
    for original in [flagsChanged, mouse] {
      XCTAssertTrue(try dispatch(original) === original)
    }
  }

  private func keyEvent(
    type: NSEvent.EventType, flags: NSEvent.ModifierFlags, repeatKey: Bool = false
  ) throws -> NSEvent {
    try XCTUnwrap(NSEvent.keyEvent(
      with: type, location: NSPoint(x: 15, y: 25), modifierFlags: flags,
      timestamp: 123, windowNumber: window.windowNumber, context: nil, characters: "C",
      charactersIgnoringModifiers: "c", isARepeat: repeatKey, keyCode: 8))
  }

  private func dispatch(_ event: NSEvent) throws -> NSEvent {
    var forwarded: NSEvent?
    let monitor = try XCTUnwrap(NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown]
    ) { received in
      forwarded = received
      // Consume the test event before any shortcut can touch the clipboard.
      return nil
    })
    defer { NSEvent.removeMonitor(monitor) }
    NSApplication.shared.sendEvent(event)
    return try XCTUnwrap(forwarded, "The application must forward the event to local monitors")
  }
}

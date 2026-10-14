import Cocoa
import FlutterMacOS
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

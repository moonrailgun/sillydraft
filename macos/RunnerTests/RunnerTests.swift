import Cocoa
import FlutterMacOS
import XCTest
@testable import SillyDraft

class RunnerTests: XCTestCase {
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

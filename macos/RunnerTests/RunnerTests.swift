import Cocoa
import FlutterMacOS
import XCTest
@testable import Remina_Desktop

class RunnerTests: XCTestCase {

  func testMainWindowInterceptsCloseBeforeAppKitHidesIt() throws {
    let window = try XCTUnwrap(NSApp.windows.compactMap { $0 as? MainFlutterWindow }.first)
    XCTAssertTrue(window.delegate === window)

    let previousRequest = window.requestAppExit
    defer { window.requestAppExit = previousRequest }
    var requests = 0
    window.requestAppExit = { requests += 1 }
    let wasVisible = window.isVisible

    let closeButton = try XCTUnwrap(window.standardWindowButton(.closeButton))
    closeButton.performClick(nil)
    XCTAssertEqual(requests, 1)
    XCTAssertEqual(window.isVisible, wasVisible)
    // The Window menu / Cmd-W must follow the same path as the red button.
    window.performClose(nil)
    XCTAssertEqual(requests, 2)
    XCTAssertEqual(window.isVisible, wasVisible)
  }

}

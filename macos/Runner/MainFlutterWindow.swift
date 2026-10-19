import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow, NSWindowDelegate {
  var requestAppExit: () -> Void = { NSApp.terminate(nil) }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    // The red button must ask Flutter before AppKit hides the window.
    requestAppExit()
    return false
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(NSRect(x: windowFrame.minX, y: windowFrame.minY, width: 1280, height: 800), display: true)
    self.minSize = NSSize(width: 1040, height: 680)
    self.title = "Remina"

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
    self.delegate = self
  }
}

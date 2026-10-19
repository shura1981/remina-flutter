import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func performClose(_ sender: Any?) {
    // Keep the window visible while Flutter confirms exit and disposes sessions.
    // Closing it first leaves a canceled termination with no visible dialog.
    NSApp.terminate(sender)
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
  }
}

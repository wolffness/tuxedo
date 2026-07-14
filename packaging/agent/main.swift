// Entry point: one .accessory agent owning the ⌥] capture panel and the menu
// bar status item.
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let capture = CapturePanel()
    var menuBar: MenuBarController!

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        capture.start()
        menuBar = MenuBarController(onNewTask: { [weak capture] in capture?.show() })
        menuBar.start()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()

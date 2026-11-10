// Spike: does expanding an NSStatusItem push the status items to its LEFT off-screen on macOS 27?
// Items created later appear further left. We create: separator first (right), then "probe" (left of it).
import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let separator = NSStatusBar.system.statusItem(withLength: 20)
separator.button?.title = "|"
let probe = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
probe.button?.title = "P"
func report(_ label: String) {
    let screen = NSScreen.main!.frame
    let p = probe.button?.window?.frame ?? .zero
    let s = separator.button?.window?.frame ?? .zero
    print(label, "screen.minX:", screen.minX, "probe.x:", p.minX, "width:", p.width, "separator.x:", s.minX, "sepWidth:", s.width,
          "probeVisible:", p.maxX > screen.minX && p.minX < screen.maxX, "probeWindowVisible:", probe.button?.window?.isVisible ?? false)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    report("before:")
    separator.length = 10_000
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        report("expanded:")
        separator.length = 20
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { report("collapsed:"); exit(0) }
    }
}
app.run()

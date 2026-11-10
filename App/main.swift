import Cocoa

let app = NSApplication.shared
let delegate = NexoApp()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

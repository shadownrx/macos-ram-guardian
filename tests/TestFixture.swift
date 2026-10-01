import AppKit
final class Delegate: NSObject, NSApplicationDelegate {
    var attempts = 0
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        attempts += 1
        return CommandLine.arguments.contains("--refuse-once") && attempts == 1 ? .terminateCancel : .terminateNow
    }
}
let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()

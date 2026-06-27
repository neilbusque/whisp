import AppKit

// Login-item management hooks (used by the installer/Settings to register the
// running .app bundle as a launch-at-login item). These exit before the app
// loop so they can be invoked headlessly, e.g.
//   Whisp.app/Contents/MacOS/Whisp --login-on
let args = CommandLine.arguments
if args.contains("--login-on") {
    _ = LoginItem.setEnabled(true)
    print("login: \(LoginItem.statusDescription)")
    exit(0)
}
if args.contains("--login-off") {
    _ = LoginItem.setEnabled(false)
    print("login: \(LoginItem.statusDescription)")
    exit(0)
}
if args.contains("--login-status") {
    print("login: \(LoginItem.statusDescription)")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory) // LSUIElement at runtime too
app.run()

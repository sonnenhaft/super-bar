import AppKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("No action specified.") }
if command == "stop" {
    let apps = ["local.SuperBar", "com.local.bluebar", "ru.tclbar.app", "local.LGBar"]
        .flatMap(NSRunningApplication.runningApplications(withBundleIdentifier:))
        .filter { !$0.isTerminated }
    for app in apps { _ = app.terminate() }
    let end = Date().addingTimeInterval(12)
    while apps.contains(where: { !$0.isTerminated }) && Date() < end {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard apps.allSatisfy(\.isTerminated) else { fail("Could not close the previous menu bar apps. Close them and try installation again.") }
    exit(0)
}
guard command == "launch", args.count == 5 else { fail("Invalid launch arguments.") }
let appURL = URL(fileURLWithPath: args[1]).standardizedFileURL
let receipt = URL(fileURLWithPath: args[2])
let version = args[3], build = args[4]
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
var environment = ProcessInfo.processInfo.environment
environment["SUPER_BAR_LAUNCH_RECEIPT"] = receipt.path
configuration.environment = environment
configuration.activates = false
var result: Result<NSRunningApplication, Error>?
NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
    if let error { result = .failure(error) }
    else if let app { result = .success(app) }
}
let deadline = Date().addingTimeInterval(20)
while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
guard let result else { fail("macOS did not confirm that Super Bar launched.") }
let app: NSRunningApplication
switch result {
case .success(let started): app = started
case .failure(let error):
    let ns = error as NSError
    fail("Launch error: \(error.localizedDescription) (\(ns.domain) \(ns.code)).")
}
guard app.bundleURL?.standardizedFileURL == appURL else {
    _ = app.terminate()
    fail("An application copy launched from a different path.")
}
while !FileManager.default.fileExists(atPath: receipt.path) && !app.isTerminated && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
guard let data = try? Data(contentsOf: receipt),
      let info = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      let pid = info["pid"] as? Int,
      pid == Int(app.processIdentifier),
      let path = info["bundlePath"] as? String,
      URL(fileURLWithPath: path).standardizedFileURL == appURL,
      let executable = info["executablePath"] as? String,
      URL(fileURLWithPath: executable).standardizedFileURL == appURL.appendingPathComponent("Contents/MacOS/SuperBar").standardizedFileURL,
      info["version"] as? String == version,
      info["build"] as? String == build,
      !app.isTerminated else {
    _ = app.terminate()
    fail("The new version did not confirm launch from the installed path.")
}
print("Launched Super Bar \(version) (build \(build)), PID \(pid).")
if let placement = info["statusItem"] as? [String: Any] {
    if placement["itemVisible"] as? Bool == true, placement["insideMenuBar"] as? Bool == true {
        print("Icon placed in the menu bar: \(placement["buttonFrame"] as? String ?? "").")
    } else {
        print("The application launched, but menu bar icon placement was not confirmed.")
    }
}

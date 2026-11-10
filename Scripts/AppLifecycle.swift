import AppKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("Не указано действие.") }
if command == "stop" {
    let apps = ["local.SuperBar", "com.local.bluebar", "ru.tclbar.app", "local.LGBar"]
        .flatMap(NSRunningApplication.runningApplications(withBundleIdentifier:))
        .filter { !$0.isTerminated }
    for app in apps { _ = app.terminate() }
    let end = Date().addingTimeInterval(12)
    while apps.contains(where: { !$0.isTerminated }) && Date() < end {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard apps.allSatisfy(\.isTerminated) else { fail("Не удалось штатно закрыть старые панели. Закрой их и повтори установку.") }
    exit(0)
}
guard command == "launch", args.count == 5 else { fail("Неверные параметры запуска.") }
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
guard let result else { fail("macOS не подтвердила запуск Super Bar.") }
let app: NSRunningApplication
switch result {
case .success(let started): app = started
case .failure(let error):
    let ns = error as NSError
    fail("Ошибка запуска: \(error.localizedDescription) (\(ns.domain) \(ns.code)).")
}
guard app.bundleURL?.standardizedFileURL == appURL else {
    _ = app.terminate()
    fail("Запустилась копия приложения из другого пути.")
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
    fail("Новая версия не подтвердила запуск из установленного пути.")
}
print("Запущен Super Bar \(version) (сборка \(build)), PID \(pid).")
if let placement = info["statusItem"] as? [String: Any] {
    if placement["itemVisible"] as? Bool == true, placement["insideMenuBar"] as? Bool == true {
        print("Значок размещён в строке меню: \(placement["buttonFrame"] as? String ?? "").")
    } else {
        print("Приложение запущено, но размещение значка в строке меню не подтверждено.")
    }
}

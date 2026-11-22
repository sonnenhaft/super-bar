import Foundation
import CryptoKit

@main enum LGTelevisionProbe {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            if args.first == "--host", args.count == 2 {
                let host = args[1]
                guard WebOSTVRemote.isLocalHost(host) else {
                    throw LGError(message: "Укажите локальный IPv4-адрес телевизора из роутера.")
                }
                print("Проверка службы пульта · \(host):3001 · " + Date().formatted())
                fflush(stdout)
                try checkRemoteService(host: host)
                print("Защищённый WebSocket на порту пульта webOS доступен. Модель и состояние питания не запрашивались.")
                return
            }
            if args == ["--nearby"] {
                let found = try await WebOSTVDiscovery.discover()
                print("Поиск LG webOS в локальной сети · " + Date().formatted())
                print("Ответили на поиск: \(found.count).")
                for tv in found {
                    let name = tv.name.components(separatedBy: .controlCharacters).joined(separator: " ")
                    print("\(name) · \(tv.host)")
                }
                return
            }
            guard args == ["--allow-keychain"] else {
                throw LGError(message: "Укажите --host LOCAL_IPV4, --nearby или --allow-keychain.")
            }
            let session = try HistoryProbeSession(key: "lg-session", reason: "Прочитать список телевизоров и их доступность в LG ThinQ")
            let network = CloudRedirects.session()
            defer { network.invalidateAndCancel() }
            let client = LGMobileClient(network: network, vault: session)
            guard let items = try await client.dashboardEntriesIfConfigured() else {
                throw LGError(message: "В Keychain нет сессии LG ThinQ.")
            }
            let tvs = items.filter { CloudValue.number($0["deviceType"]) == 701 }
            print("LG ThinQ · " + Date().formatted() + " · service/application/dashboard")
            print("Устройств: \(items.count). Телевизоров: \(tvs.count).")
            for row in tvs {
                var online = LGAccountTelevision.cloudOnline(row["online"])
                var source = "dashboard"
                if online == nil, let id = row["deviceId"] as? String {
                    do {
                        online = try await client.televisionOnlineIfConfigured(id: id)
                        source = "карточка устройства"
                    } catch { source = "статус недоступен в карточке устройства" }
                }
                print("\(alias(row)) · \(online.map { $0 ? "онлайн" : "офлайн" } ?? "LG не вернул статус") · \(source)")
            }
            if tvs.isEmpty {
                for row in items {
                    let type = CloudValue.number(row["deviceType"]).flatMap(Int.init(exactly:)).map(String.init) ?? "?"
                    print("\(alias(row)) · тип \(type)")
                }
            }
        } catch {
            let error = error as NSError
            let message = error.domain == NSOSStatusErrorDomain
                ? "Keychain не предоставил сессию LG (\(error.code))."
                : error.localizedDescription
            FileHandle.standardError.write(Data(("Проверка не завершена. " + message + "\n").utf8))
            exit(1)
        }
    }

    private static func checkRemoteService(host: String) throws {
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.environment = ["LC_ALL": "C"]
        // A TV has a local certificate. This credential-free handshake checks availability only.
        curl.arguments = ["-q", "--noproxy", "*", "--http1.1", "--insecure", "--connect-timeout", "3",
                          "--max-time", "4", "--silent", "--show-error", "--verbose", "--output", "/dev/null",
                          "--header", "Connection: Upgrade", "--header", "Upgrade: websocket",
                          "--header", "Sec-WebSocket-Version: 13", "--header", "Sec-WebSocket-Key: \(key)",
                          "https://\(host):3001/"]
        let output = Pipe()
        curl.standardError = output
        try curl.run()
        let log = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        curl.waitUntilExit()
        try checkHandshake(log: log, code: curl.terminationStatus, key: key)
    }

    static func checkHandshake(log: String, code: Int32, key: String) throws {
        let lines = log.components(separatedBy: .newlines)
            .filter { $0.hasPrefix("< ") }.map { String($0.dropFirst(2)) }
        if let start = lines.lastIndex(where: { $0.hasPrefix("HTTP/") }),
           let token = lines[start].split(separator: " ").dropFirst().first, let status = Int(token) {
            let headers = lines.suffix(from: lines.index(after: start))
            let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            func values(_ field: String) -> [String] {
                headers.compactMap { line in
                    guard let split = line.firstIndex(of: ":"),
                          line[..<split].lowercased() == field else { return nil }
                    return line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
                }
            }
            guard status == 101, values("upgrade").contains(where: { $0.lowercased() == "websocket" }),
                  values("connection").flatMap({ $0.lowercased().components(separatedBy: ",") })
                    .contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }),
                  values("sec-websocket-accept") == [expected] else {
                throw LGError(message: "Устройство ответило HTTP \(status), но не подтвердило открытие WebSocket.")
            }
            return
        }
        let detail: String
        if log.contains("Operation not permitted") || log.contains("Permission denied") {
            detail = "Mac запретил локальное соединение. Статус телевизора неизвестен."
        } else if log.contains("Connection refused") {
            detail = "Адрес отклонил соединение на порту пульта."
        } else if code == 28 {
            detail = "За отведённое время служба пульта не ответила. Статус телевизора неизвестен."
        } else {
            detail = "Открыть защищённый WebSocket не удалось (curl \(code)). Статус телевизора неизвестен."
        }
        throw LGError(message: detail)
    }

    private static func alias(_ row: [String: Any]) -> String {
        let text = (row["alias"] as? String ?? "").components(separatedBy: .controlCharacters).joined(separator: " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Без названия" : String(text.prefix(100))
    }
}

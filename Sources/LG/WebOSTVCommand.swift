import Foundation

struct WebOSTVApplication: Identifiable, Equatable {
    let id: String
    let name: String
}
/// SSAP operations documented by LG's Connect SDK WebOSTVService.
/// These values describe commands; constructing one never opens a connection.
enum WebOSTVCommand: Equatable {
    case launch(String)
    case channel(up: Bool)
    case text(String), enter, deleteCharacter

    var uri: String {
        switch self {
        case .channel(let up): return up ? "tv/channelUp" : "tv/channelDown"
        case .launch: return "system.launcher/launch"
        case .text: return "com.webos.service.ime/insertText"
        case .enter: return "com.webos.service.ime/sendEnterKey"
        case .deleteCharacter: return "com.webos.service.ime/deleteCharacters"
        }
    }
    var payload: [String: Any] {
        switch self {
        case .launch(let id): return ["id": id]
        case .text(let text): return ["text": text, "replace": false]
        case .deleteCharacter: return ["count": 1]
        default: return [:]
        }
    }
    var service: String {
        switch self {
        case .channel: return "tv"
        case .launch: return "system.launcher"
        case .text, .enter, .deleteCharacter: return "com.webos.service.ime"
        }
    }
    func validate() throws {
        switch self {
        case .launch(let id):
            guard !id.isEmpty, id.utf8.count <= 512 else { throw WebOSTVError("Choose an item reported by the TV.") }
        case .text(let text):
            guard !text.isEmpty, text.utf8.count <= 4096 else { throw WebOSTVError("Enter up to 4096 bytes of text.") }
        default: break
        }
    }
}

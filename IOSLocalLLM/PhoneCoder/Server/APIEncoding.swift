import Foundation

enum PhoneCoderStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case responseEvent(name: String, json: String)
    case error(PhoneCoderAPIError)
    case done
}

enum PhoneCoderAPIEncoder {
    static func sse(id: Int, event: PhoneCoderStreamEvent) throws -> Data {
        let name: String?
        let payload: String
        switch event {
        case .textDelta(let text):
            name = nil
            payload = try json(["delta": text])
        case .responseEvent(let eventName, let value):
            guard !eventName.isEmpty, !eventName.contains("\n"), !eventName.contains("\r"), let data = value.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil else { throw PhoneCoderAPIError.invalid("Invalid stream event") }
            name = eventName
            // Re-encode to ensure embedded line breaks cannot break the SSE frame.
            payload = try json(JSONSerialization.jsonObject(with: data))
        case .error(let error):
            name = "error"
            payload = try json(["error": ["code": error.code, "message": error.message]])
        case .done:
            name = nil
            payload = "[DONE]"
        }
        guard id > 0 else { throw PhoneCoderAPIError.invalid("Invalid event ID") }
        return Data(("id: \(id)\n" + (name.map { "event: \($0)\n" } ?? "") + "data: \(payload)\n\n").utf8)
    }

    private static func json(_ value: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        guard let result = String(data: data, encoding: .utf8) else { throw PhoneCoderAPIError.invalid("Invalid UTF-8") }
        return result
    }
}

import CoreFoundation
import Foundation

struct PhoneCoderRequestID: RawRepresentable, Hashable, Codable, Sendable {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
}

struct PhoneCoderAPIError: Error, Equatable, Sendable {
    let code: String
    let message: String

    static func invalid(_ message: String) -> Self { .init(code: "invalid_request", message: message) }
    static let bodyTooLarge = Self(code: "body_too_large", message: "Request body is too large.")
}

struct PhoneCoderChatRequest: Equatable, Sendable {
    static let maximumBodyBytes = 1_048_576
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let streamIncludeUsage: Bool
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let stop: [String]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && ContractDecoder.sameMessages(lhs.messages, rhs.messages)
            && lhs.stream == rhs.stream && lhs.streamIncludeUsage == rhs.streamIncludeUsage
            && lhs.maxTokens == rhs.maxTokens && lhs.temperature == rhs.temperature
            && lhs.topP == rhs.topP && lhs.stop == rhs.stop
    }

    static func decode(_ data: Data) throws -> Self {
        let raw = try ContractDecoder.object(data)
        try ContractDecoder.keys(raw, allowed: ["model", "messages", "stream", "stream_options", "max_tokens", "max_completion_tokens", "temperature", "top_p", "stop"])
        let model = try ContractDecoder.model(raw)
        let messages = try ContractDecoder.messages(raw["messages"])
        let options = try ContractDecoder.options(raw, tokenKeys: ["max_completion_tokens", "max_tokens"])
        return Self(model: model, messages: messages, stream: options.stream, streamIncludeUsage: options.usage, maxTokens: options.maxTokens, temperature: options.temperature, topP: options.topP, stop: options.stop)
    }
}

struct PhoneCoderResponsesRequest: Equatable, Sendable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
    let streamIncludeUsage: Bool
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let stop: [String]
    let tools: [LocalAPIToolDefinition]
    let toolChoice: LocalAPIToolChoice

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model == rhs.model && ContractDecoder.sameMessages(lhs.messages, rhs.messages)
            && lhs.stream == rhs.stream && lhs.streamIncludeUsage == rhs.streamIncludeUsage
            && lhs.maxTokens == rhs.maxTokens && lhs.temperature == rhs.temperature
            && lhs.topP == rhs.topP && lhs.stop == rhs.stop && lhs.tools == rhs.tools
            && lhs.toolChoice == rhs.toolChoice
    }

    static func decode(_ data: Data) throws -> Self {
        let raw = try ContractDecoder.object(data)
        try ContractDecoder.keys(raw, allowed: ["model", "input", "instructions", "stream", "stream_options", "max_output_tokens", "temperature", "top_p", "stop", "tools", "tool_choice"])
        let model = try ContractDecoder.model(raw)
        var messages: [ChatMessage]
        if let input = raw["input"] as? String, !input.isEmpty {
            messages = [ChatMessage(role: .user, content: input)]
        } else {
            messages = try ContractDecoder.messages(raw["input"], responses: true)
        }
        if let instructions = raw["instructions"] {
            guard let text = instructions as? String else { throw PhoneCoderAPIError.invalid("instructions must be text") }
            if !text.isEmpty { messages.insert(ChatMessage(role: .system, content: text), at: 0) }
        }
        let tools = try ContractDecoder.tools(raw["tools"])
        let choice: LocalAPIToolChoice
        switch raw["tool_choice"] {
        case nil: choice = tools.isEmpty ? .none : .auto
        case let value as String where value == "none": choice = .none
        case let value as String where value == "auto": choice = tools.isEmpty ? .none : .auto
        case let value as String where value == "required" && !tools.isEmpty: choice = .required
        default: throw PhoneCoderAPIError.invalid("invalid tool_choice")
        }
        let options = try ContractDecoder.options(raw, tokenKeys: ["max_output_tokens"])
        return Self(model: model, messages: messages, stream: options.stream, streamIncludeUsage: options.usage, maxTokens: options.maxTokens, temperature: options.temperature, topP: options.topP, stop: options.stop, tools: tools, toolChoice: choice)
    }
}

private enum ContractDecoder {
    static func sameMessages(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.0.role == $0.1.role && $0.0.content == $0.1.content }
    }
    static func object(_ data: Data) throws -> [String: Any] {
        guard data.count <= PhoneCoderChatRequest.maximumBodyBytes else { throw PhoneCoderAPIError.bodyTooLarge }
        guard let value = try? JSONSerialization.jsonObject(with: data), let raw = value as? [String: Any] else { throw PhoneCoderAPIError.invalid("Expected a JSON object") }
        return raw
    }
    static func keys(_ raw: [String: Any], allowed: Set<String>) throws {
        guard Set(raw.keys).isSubset(of: allowed) else { throw PhoneCoderAPIError.invalid("Unsupported field") }
    }
    static func model(_ raw: [String: Any]) throws -> String {
        guard let model = raw["model"] as? String, !model.isEmpty else { throw PhoneCoderAPIError.invalid("model is required") }
        return model
    }
    static func messages(_ value: Any?, responses: Bool = false) throws -> [ChatMessage] {
        guard let rows = value as? [[String: Any]], !rows.isEmpty else { throw PhoneCoderAPIError.invalid("messages must be a non-empty array") }
        let messages = try rows.map { row -> ChatMessage in
            try keys(row, allowed: responses ? ["type", "role", "content"] : ["role", "content"])
            if let type = row["type"] { guard responses, type as? String == "message" else { throw PhoneCoderAPIError.invalid("invalid message type") } }
            guard let roleName = row["role"] as? String, ["system", "user", "assistant"].contains(roleName), let role = ChatMessage.Role(rawValue: roleName) else { throw PhoneCoderAPIError.invalid("invalid role") }
            let content: String
            if let text = row["content"] as? String { content = text }
            else if responses, let parts = row["content"] as? [[String: Any]], !parts.isEmpty {
                content = try parts.map { part in
                    try keys(part, allowed: ["type", "text"])
                    guard let type = part["type"] as? String, ["input_text", "output_text"].contains(type), let text = part["text"] as? String else { throw PhoneCoderAPIError.invalid("only text content is supported") }
                    return text
                }.joined()
            } else { throw PhoneCoderAPIError.invalid("only text content is supported") }
            guard !content.isEmpty else { throw PhoneCoderAPIError.invalid("empty message") }
            return ChatMessage(role: role, content: content)
        }
        guard messages.last?.role == .user else { throw PhoneCoderAPIError.invalid("final message must be user") }
        return messages
    }
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }
    static func options(_ raw: [String: Any], tokenKeys: [String]) throws -> (stream: Bool, usage: Bool, maxTokens: Int?, temperature: Double?, topP: Double?, stop: [String]) {
        func boolean(_ value: Any?, default fallback: Bool) throws -> Bool {
            guard let value else { return fallback }
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw PhoneCoderAPIError.invalid("Expected boolean") }
            return number.boolValue
        }
        let stream = try boolean(raw["stream"], default: false)
        var usage = false
        if let value = raw["stream_options"] {
            guard let object = value as? [String: Any] else { throw PhoneCoderAPIError.invalid("Invalid stream_options") }
            try keys(object, allowed: ["include_usage"])
            usage = try boolean(object["include_usage"], default: false)
        }
        var tokens: Int?
        for key in tokenKeys where raw[key] != nil {
            guard let n = number(raw[key]), n.isFinite, n.rounded() == n, n >= 1, n <= 1_000_000 else { throw PhoneCoderAPIError.invalid("Invalid token limit") }
            if tokens == nil { tokens = Int(n) }
        }
        func bounded(_ key: String, minimum: Double, maximum: Double, exclusiveMinimum: Bool = false) throws -> Double? {
            guard let value = raw[key] else { return nil }
            guard let n = number(value), n.isFinite, (exclusiveMinimum ? n > minimum : n >= minimum), n <= maximum else { throw PhoneCoderAPIError.invalid("Invalid \(key)") }
            return n
        }
        let temperature = try bounded("temperature", minimum: 0, maximum: 2)
        let topP = try bounded("top_p", minimum: 0, maximum: 1, exclusiveMinimum: true)
        var stop: [String] = []
        if let value = raw["stop"] {
            if let string = value as? String { stop = [string] }
            else if let strings = value as? [String] { stop = strings }
            else { throw PhoneCoderAPIError.invalid("Invalid stop") }
            guard (1...4).contains(stop.count), stop.allSatisfy({ !$0.isEmpty }) else { throw PhoneCoderAPIError.invalid("Invalid stop") }
        }
        return (stream, usage, tokens, temperature, topP, stop)
    }
    static func tools(_ value: Any?) throws -> [LocalAPIToolDefinition] {
        guard let value else { return [] }
        guard let rows = value as? [[String: Any]] else { throw PhoneCoderAPIError.invalid("Invalid tools") }
        var names = Set<String>()
        return try rows.map { row in
            try keys(row, allowed: ["type", "name", "description", "parameters"])
            guard row["type"] as? String == "function", let name = row["name"] as? String, !name.isEmpty, names.insert(name).inserted else { throw PhoneCoderAPIError.invalid("Invalid or duplicate tool") }
            if let description = row["description"], !(description is String) { throw PhoneCoderAPIError.invalid("Invalid tool description") }
            let parameters = row["parameters"] ?? ["type": "object", "properties": [:]]
            guard let schema = parameters as? [String: Any], schema["type"] as? String == "object", JSONSerialization.isValidJSONObject(schema), let encoded = try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), let json = String(data: encoded, encoding: .utf8) else { throw PhoneCoderAPIError.invalid("Invalid tool schema") }
            return LocalAPIToolDefinition(name: name, description: row["description"] as? String, parametersJSON: json)
        }
    }
}

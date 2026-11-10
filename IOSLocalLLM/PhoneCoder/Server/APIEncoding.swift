import Foundation

struct PhoneCoderCompletionContext: Equatable, Sendable {
    let id: String
    let model: String
    let created: Int
}

struct PhoneCoderUsage: Equatable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    var chat: [String: Int] { ["prompt_tokens": inputTokens, "completion_tokens": outputTokens, "total_tokens": inputTokens + outputTokens] }
    var responses: [String: Int] { ["input_tokens": inputTokens, "output_tokens": outputTokens, "total_tokens": inputTokens + outputTokens] }
}

enum PhoneCoderFinishReason: String, Equatable, Sendable {
    case stop, length, toolCalls = "tool_calls"
}

enum PhoneCoderResponseItem: Equatable, Sendable {
    case message(id: String, text: String)
    case function(id: String, callID: String, name: String, arguments: String)

    var object: [String: Any] {
        switch self {
        case let .message(id, text):
            return ["id": id, "type": "message", "status": "completed", "role": "assistant", "content": [["type": "output_text", "text": text, "annotations": []]]]
        case let .function(id, callID, name, arguments):
            return ["id": id, "type": "function_call", "status": "completed", "call_id": callID, "name": name, "arguments": arguments]
        }
    }
}

enum PhoneCoderStreamEvent: Equatable, Sendable {
    case chatStart(PhoneCoderCompletionContext)
    case chatText(PhoneCoderCompletionContext, String)
    case chatFinish(PhoneCoderCompletionContext, PhoneCoderFinishReason)
    case chatUsage(PhoneCoderCompletionContext, PhoneCoderUsage)
    case responseCreated(PhoneCoderCompletionContext)
    case responseInProgress(PhoneCoderCompletionContext)
    case responseMessageAdded(PhoneCoderCompletionContext, itemID: String, outputIndex: Int)
    case responseContentPartAdded(PhoneCoderCompletionContext, itemID: String, outputIndex: Int, contentIndex: Int)
    case responseTextDelta(PhoneCoderCompletionContext, itemID: String, outputIndex: Int, contentIndex: Int, delta: String)
    case responseTextDone(PhoneCoderCompletionContext, itemID: String, outputIndex: Int, contentIndex: Int, text: String)
    case responseContentPartDone(PhoneCoderCompletionContext, itemID: String, outputIndex: Int, contentIndex: Int, text: String)
    case responseFunctionAdded(PhoneCoderCompletionContext, itemID: String, outputIndex: Int, callID: String, name: String)
    case responseFunctionArgumentsDelta(PhoneCoderCompletionContext, itemID: String, outputIndex: Int, delta: String)
    case responseFunctionArgumentsDone(PhoneCoderCompletionContext, itemID: String, outputIndex: Int, arguments: String)
    case responseItemDone(PhoneCoderCompletionContext, outputIndex: Int, item: PhoneCoderResponseItem)
    case responseCompleted(PhoneCoderCompletionContext, usage: PhoneCoderUsage, output: [PhoneCoderResponseItem] = [])
    case responseError(PhoneCoderAPIError, param: String? = nil)
    case error(PhoneCoderAPIError)
    case done
}

enum PhoneCoderAPIEncoder {
    static func chatCompletion(context: PhoneCoderCompletionContext, text: String, finish: PhoneCoderFinishReason, usage: PhoneCoderUsage) throws -> Data {
        try encoded(["id": context.id, "object": "chat.completion", "created": context.created, "model": context.model,
                     "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": finish.rawValue]], "usage": usage.chat])
    }

    static func responsesCompletion(context: PhoneCoderCompletionContext, output: [PhoneCoderResponseItem], usage: PhoneCoderUsage) throws -> Data {
        try encoded(response(context, status: "completed", usage: usage, output: output))
    }

    static func sse(id: Int, event: PhoneCoderStreamEvent) throws -> Data {
        guard id > 0 else { throw PhoneCoderAPIError.invalid("Invalid event ID") }
        let name: String?
        let object: [String: Any]?
        switch event {
        case .chatStart(let c): name = nil; object = chunk(c, delta: ["role": "assistant"], finish: nil)
        case .chatText(let c, let text): name = nil; object = chunk(c, delta: ["content": text], finish: nil)
        case .chatFinish(let c, let finish): name = nil; object = chunk(c, delta: [:], finish: finish)
        case .chatUsage(let c, let usage):
            name = nil; object = ["id": c.id, "object": "chat.completion.chunk", "created": c.created, "model": c.model, "choices": [], "usage": usage.chat]
        case .responseCreated(let c): name = "response.created"; object = ["response": response(c, status: "in_progress")]
        case .responseInProgress(let c): name = "response.in_progress"; object = ["response": response(c, status: "in_progress")]
        case let .responseMessageAdded(c, itemID, index):
            name = "response.output_item.added"; object = ["response_id": c.id, "output_index": index, "item": ["id": itemID, "type": "message", "status": "in_progress", "role": "assistant", "content": []]]
        case let .responseContentPartAdded(c, itemID, index, contentIndex):
            name = "response.content_part.added"; object = part(c, itemID, index, contentIndex, text: "")
        case let .responseTextDelta(c, itemID, index, contentIndex, delta):
            name = "response.output_text.delta"; object = ["response_id": c.id, "item_id": itemID, "output_index": index, "content_index": contentIndex, "delta": delta]
        case let .responseTextDone(c, itemID, index, contentIndex, text):
            name = "response.output_text.done"; object = ["response_id": c.id, "item_id": itemID, "output_index": index, "content_index": contentIndex, "text": text]
        case let .responseContentPartDone(c, itemID, index, contentIndex, text):
            name = "response.content_part.done"; object = part(c, itemID, index, contentIndex, text: text)
        case let .responseFunctionAdded(c, itemID, index, callID, functionName):
            name = "response.output_item.added"; object = ["response_id": c.id, "output_index": index, "item": ["id": itemID, "type": "function_call", "status": "in_progress", "call_id": callID, "name": functionName, "arguments": ""]]
        case let .responseFunctionArgumentsDelta(c, itemID, index, delta):
            name = "response.function_call_arguments.delta"; object = ["response_id": c.id, "item_id": itemID, "output_index": index, "delta": delta]
        case let .responseFunctionArgumentsDone(c, itemID, index, arguments):
            name = "response.function_call_arguments.done"; object = ["response_id": c.id, "item_id": itemID, "output_index": index, "arguments": arguments]
        case let .responseItemDone(c, index, item):
            name = "response.output_item.done"; object = ["response_id": c.id, "output_index": index, "item": item.object]
        case let .responseCompleted(c, usage, output):
            name = "response.completed"; object = ["response": response(c, status: "completed", usage: usage, output: output)]
        case let .responseError(error, param): name = "error"; object = ["code": error.code, "message": error.message, "param": param as Any? ?? NSNull()]
        case .error(let error): name = "error"; object = ["error": ["code": error.code, "message": error.message]]
        case .done: name = nil; object = nil
        }
        var body = object
        if let name { body?["type"] = name }
        switch event {
        case .chatStart, .chatText, .chatFinish, .chatUsage, .error, .done:
            break
        default:
            body?["sequence_number"] = id
        }
        let payload: String
        if let body {
            guard let text = String(data: try encoded(body), encoding: .utf8) else { throw PhoneCoderAPIError.invalid("Invalid UTF-8") }
            payload = text
        } else { payload = "[DONE]" }
        return Data(("id: \(id)\n" + (name.map { "event: \($0)\n" } ?? "") + "data: \(payload)\n\n").utf8)
    }

    private static func chunk(_ c: PhoneCoderCompletionContext, delta: [String: Any], finish: PhoneCoderFinishReason?) -> [String: Any] {
        ["id": c.id, "object": "chat.completion.chunk", "created": c.created, "model": c.model,
         "choices": [["index": 0, "delta": delta, "finish_reason": finish?.rawValue as Any? ?? NSNull()]]]
    }
    private static func response(_ c: PhoneCoderCompletionContext, status: String, usage: PhoneCoderUsage? = nil, output: [PhoneCoderResponseItem] = []) -> [String: Any] {
        ["id": c.id, "object": "response", "created_at": c.created, "model": c.model, "status": status, "output": output.map(\.object), "usage": usage?.responses as Any? ?? NSNull()]
    }
    private static func part(_ c: PhoneCoderCompletionContext, _ id: String, _ index: Int, _ contentIndex: Int, text: String) -> [String: Any] {
        ["response_id": c.id, "item_id": id, "output_index": index, "content_index": contentIndex, "part": ["type": "output_text", "text": text, "annotations": []]]
    }
    private static func encoded(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

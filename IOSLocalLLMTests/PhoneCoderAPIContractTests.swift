import Foundation
import XCTest
@testable import PhoneCoder

final class PhoneCoderAPIContractTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testChatTextAndGenerationOptions() throws {
        let request = try PhoneCoderChatRequest.decode(data(#"{"model":"m","messages":[{"role":"system","content":"s"},{"role":"user","content":"hello"}],"max_tokens":12,"max_completion_tokens":8,"temperature":2,"top_p":0.5,"stop":["end"],"stream":true,"stream_options":{"include_usage":true}}"#))
        XCTAssertEqual(request.messages.map(\.content), ["s", "hello"])
        XCTAssertEqual(request.maxTokens, 8)
        XCTAssertEqual(request.temperature, 2)
        XCTAssertEqual(request.topP, 0.5)
        XCTAssertEqual(request.stop, ["end"])
        XCTAssertTrue(request.streamIncludeUsage)
        XCTAssertEqual(try PhoneCoderChatRequest.decode(data(#"{"model":"m","messages":[{"role":"user","content":"hello"}]}"#)), try PhoneCoderChatRequest.decode(data(#"{"model":"m","messages":[{"role":"user","content":"hello"}]}"#)))
    }

    func testInvalidChatRequestsAreRejected() {
        let bodies = [
            #"{"model":"m","messages":[]}"#,
            #"{"model":"m","messages":[{"role":"assistant","content":"x"}]}"#,
            #"{"model":"m","messages":[{"role":"user","content":"x"}],"temperature":2.1}"#,
            #"{"model":"m","messages":[{"role":"user","content":"x"}],"temperature":-0.1}"#,
            #"{"model":"m","messages":[{"role":"user","content":"x"}],"top_p":0}"#,
            #"{"model":"m","messages":[{"role":"user","content":"x"}],"top_p":1.1}"#,
            #"{"model":"m","messages":[{"role":"user","content":"x","extra":1}]}"#,
            #"{"model":"m","messages":[{"role":"user","content":"x"}],"max_tokens":true}"#,
            #"{"model":"m","messages":[{"role":"user","content":"x"}],"stream":1}"#,
            #"{"model":"m","messages":[{"role":"user","content":"x"}],"stop":["a","b","c","d","e"]}"#,
            #"{"model":"m","messages":[{"role":"user","content":"x"}],"unknown":1}"#,
            #"{"model":"m","messages":[{"role":"user","content":[{"type":"image_url","image_url":{"url":"https://example.com/a"}}]}]}"#,
            #"{"model":"m","messages":[{"role":"user","content":"x"}],"stream_options":{"other":true}}"#,
            "{"
        ]
        for body in bodies { XCTAssertThrowsError(try PhoneCoderChatRequest.decode(data(body)), body) }
        XCTAssertThrowsError(try PhoneCoderChatRequest.decode(Data(repeating: 32, count: PhoneCoderChatRequest.maximumBodyBytes + 1))) { error in
            XCTAssertEqual((error as? PhoneCoderAPIError)?.code, "body_too_large")
        }
    }

    func testToolSchemasRejectMalformedAndUnsupportedNestedConstraints() throws {
        let invalid = [#"{"type":"object","properties":7,"required":"x"}"#,
                       #"{"type":"object","properties":{"x":{"type":"array","items":7}}}"#,
                       #"{"type":"object","properties":{"x":{"type":"string","pattern":".*"}}}"#,
                       #"{"type":"object","properties":{"x":{"type":"string"}},"required":["missing"]}"#,
                       #"{"type":"object","additionalProperties":"yes"}"#]
        for schema in invalid {
            XCTAssertThrowsError(try PhoneCoderResponsesRequest.decode(data("{\"model\":\"m\",\"input\":\"hi\",\"tools\":[{\"type\":\"function\",\"name\":\"f\",\"parameters\":\(schema)}]}")), schema)
        }
        let valid = #"{"model":"m","input":"hi","tools":[{"type":"function","name":"f","parameters":{"type":"object","properties":{"x":{"type":"array","items":{"type":"string","enum":["a","b"]}}},"required":["x"],"additionalProperties":false}}]}"#
        XCTAssertEqual(try PhoneCoderResponsesRequest.decode(data(valid)).tools.count, 1)
    }

    func testChatWireEnvelopesAndTerminalFrames() throws {
        let context = PhoneCoderCompletionContext(id: "chat-1", model: "m", created: 123)
        let usage = PhoneCoderUsage(inputTokens: 2, outputTokens: 3)
        let start = try payload(.chatStart(context))
        XCTAssertEqual(start["object"] as? String, "chat.completion.chunk")
        let choice = try XCTUnwrap((start["choices"] as? [[String: Any]])?.first)
        XCTAssertEqual((choice["delta"] as? [String: String])?["role"], "assistant")
        let delta = try payload(.chatText(context, "hello"))
        XCTAssertEqual((((delta["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: String])?["content"], "hello")
        let finish = try payload(.chatFinish(context, .stop))
        XCTAssertEqual(((finish["choices"] as? [[String: Any]])?.first)?["finish_reason"] as? String, "stop")
        let usageChunk = try payload(.chatUsage(context, usage))
        XCTAssertEqual((usageChunk["choices"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual((usageChunk["usage"] as? [String: Int])?["total_tokens"], 5)
        let completion = try JSONSerialization.jsonObject(with: PhoneCoderAPIEncoder.chatCompletion(context: context, text: "hello", finish: .stop, usage: usage)) as? [String: Any]
        XCTAssertEqual(completion?["object"] as? String, "chat.completion")
        let message = ((completion?["choices"] as? [[String: Any]])?.first)?["message"] as? [String: String]
        XCTAssertEqual(message?["content"], "hello")
        XCTAssertEqual(message?["role"], "assistant")
        XCTAssertEqual(String(data: try PhoneCoderAPIEncoder.sse(id: 9, event: .done), encoding: .utf8), "id: 9\ndata: [DONE]\n\n")
        let error = try payload(.error(.invalid("bad")))
        XCTAssertEqual((error["error"] as? [String: String])?["code"], "invalid_request")
    }

    func testResponsesNamedEventsHaveTypedPayloads() throws {
        let context = PhoneCoderCompletionContext(id: "resp-1", model: "m", created: 123)
        let events: [(PhoneCoderStreamEvent, String)] = [
            (.responseCreated(context), "response.created"),
            (.responseMessageAdded(context, itemID: "msg-1", outputIndex: 0), "response.output_item.added"),
            (.responseTextDelta(context, itemID: "msg-1", outputIndex: 0, contentIndex: 0, delta: "é"), "response.output_text.delta"),
            (.responseTextDone(context, itemID: "msg-1", outputIndex: 0, contentIndex: 0, text: "é"), "response.output_text.done"),
            (.responseFunctionAdded(context, itemID: "fc-1", outputIndex: 1, callID: "call-1", name: "read"), "response.output_item.added"),
            (.responseFunctionArgumentsDelta(context, itemID: "fc-1", outputIndex: 1, delta: "{}"), "response.function_call_arguments.delta"),
            (.responseFunctionArgumentsDone(context, itemID: "fc-1", outputIndex: 1, arguments: "{}"), "response.function_call_arguments.done"),
            (.responseCompleted(context, usage: PhoneCoderUsage(inputTokens: 1, outputTokens: 2)), "response.completed"),
            (.responseError(.invalid("bad")), "error")
        ]
        for (event, name) in events {
            let frame = try XCTUnwrap(String(data: PhoneCoderAPIEncoder.sse(id: 1, event: event), encoding: .utf8))
            XCTAssertTrue(frame.contains("event: \(name)\n"))
            XCTAssertEqual(try payload(event)["type"] as? String, name)
        }
        let functionItem = try payload(events[4].0)["item"] as? [String: Any]
        XCTAssertEqual(functionItem?["call_id"] as? String, "call-1")
        XCTAssertEqual(functionItem?["name"] as? String, "read")
        XCTAssertEqual(try payload(events[5].0)["delta"] as? String, "{}")
        XCTAssertEqual(try payload(events[6].0)["arguments"] as? String, "{}")
        XCTAssertEqual(try payload(events[2].0)["delta"] as? String, "é")
        let completed = try payload(events[7].0)["response"] as? [String: Any]
        XCTAssertEqual((completed?["usage"] as? [String: Int])?["total_tokens"], 3)
        let item = PhoneCoderResponseItem.function(id: "fc-1", callID: "call-1", name: "read", arguments: "{}")
        let doneItem = try payload(.responseItemDone(context, outputIndex: 1, item: item))
        XCTAssertEqual((doneItem["item"] as? [String: Any])?["status"] as? String, "completed")
        let completedWithItem = try payload(.responseCompleted(context, usage: PhoneCoderUsage(inputTokens: 1, outputTokens: 2), output: [item]))
        let response = completedWithItem["response"] as? [String: Any]
        XCTAssertEqual(((response?["output"] as? [[String: Any]])?.first)?["arguments"] as? String, "{}")
        let nonstream = try XCTUnwrap(JSONSerialization.jsonObject(with: PhoneCoderAPIEncoder.responsesCompletion(context: context, output: [item], usage: PhoneCoderUsage(inputTokens: 1, outputTokens: 2))) as? [String: Any])
        XCTAssertEqual(nonstream["object"] as? String, "response")
        XCTAssertEqual(((nonstream["output"] as? [[String: Any]])?.first)?["call_id"] as? String, "call-1")
    }

    func testResponsesEventsCarrySSESequenceAndTopLevelErrorFields() throws {
        let c = PhoneCoderCompletionContext(id: "r", model: "m", created: 1)
        let item = PhoneCoderResponseItem.message(id: "i", text: "hi")
        let error = PhoneCoderAPIError.invalid("bad input")
        let events: [PhoneCoderStreamEvent] = [
            .responseCreated(c), .responseInProgress(c),
            .responseMessageAdded(c, itemID: "i", outputIndex: 0),
            .responseContentPartAdded(c, itemID: "i", outputIndex: 0, contentIndex: 0),
            .responseTextDelta(c, itemID: "i", outputIndex: 0, contentIndex: 0, delta: "hi"),
            .responseTextDone(c, itemID: "i", outputIndex: 0, contentIndex: 0, text: "hi"),
            .responseContentPartDone(c, itemID: "i", outputIndex: 0, contentIndex: 0, text: "hi"),
            .responseFunctionAdded(c, itemID: "f", outputIndex: 1, callID: "call", name: "read"),
            .responseFunctionArgumentsDelta(c, itemID: "f", outputIndex: 1, delta: "{}"),
            .responseFunctionArgumentsDone(c, itemID: "f", outputIndex: 1, arguments: "{}"),
            .responseItemDone(c, outputIndex: 0, item: item),
            .responseCompleted(c, usage: PhoneCoderUsage(inputTokens: 1, outputTokens: 1)),
            .responseError(error), .responseError(error, param: "input")
        ]
        for (offset, event) in events.enumerated() {
            let id = offset + 10
            let frame = try XCTUnwrap(String(data: PhoneCoderAPIEncoder.sse(id: id, event: event), encoding: .utf8))
            XCTAssertTrue(frame.hasPrefix("id: \(id)\n"))
            let line = try XCTUnwrap(frame.components(separatedBy: "\n").first { $0.hasPrefix("data: ") })
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any])
            XCTAssertEqual(body["sequence_number"] as? Int, id)
        }
        let absent = try payload(.responseError(error))
        XCTAssertEqual(absent["type"] as? String, "error")
        XCTAssertEqual(absent["code"] as? String, "invalid_request")
        XCTAssertEqual(absent["message"] as? String, "bad input")
        XCTAssertTrue(absent["param"] is NSNull)
        XCTAssertNil(absent["error"])
        let present = try payload(.responseError(error, param: "input"))
        XCTAssertEqual(present["param"] as? String, "input")
        XCTAssertNil(try payload(.chatText(c, "hi"))["sequence_number"])
    }

    private func payload(_ event: PhoneCoderStreamEvent) throws -> [String: Any] {
        let frame = try XCTUnwrap(String(data: PhoneCoderAPIEncoder.sse(id: 1, event: event), encoding: .utf8))
        let line = try XCTUnwrap(frame.components(separatedBy: "\n").first { $0.hasPrefix("data: ") })
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any])
    }

    func testResponsesToolsAndChoice() throws {
        let request = try PhoneCoderResponsesRequest.decode(data(#"{"model":"m","input":"hello","tools":[{"type":"function","name":"read","parameters":{"type":"object","properties":{}}}],"tool_choice":"required","max_output_tokens":20}"#))
        XCTAssertEqual(request.messages.last?.content, "hello")
        XCTAssertEqual(request.tools.map(\.name), ["read"])
        XCTAssertEqual(request.toolChoice, .required)
        XCTAssertEqual(request.maxTokens, 20)
        XCTAssertThrowsError(try PhoneCoderResponsesRequest.decode(data(#"{"model":"m","input":"hi","tools":[{"type":"function","name":"x"},{"type":"function","name":"x"}]}"#)))
        XCTAssertThrowsError(try PhoneCoderResponsesRequest.decode(data(#"{"model":"m","input":"hi","tool_choice":"required"}"#)))
        let messages = try PhoneCoderResponsesRequest.decode(data(#"{"model":"m","input":[{"type":"message","role":"user","content":[{"type":"input_text","text":"hello"}]}],"stream_options":{"include_usage":true}}"#))
        XCTAssertEqual(messages.messages.last?.content, "hello")
        XCTAssertTrue(messages.streamIncludeUsage)
        XCTAssertThrowsError(try PhoneCoderResponsesRequest.decode(data(#"{"model":"m","input":"hi","extra":true}"#)))
        XCTAssertThrowsError(try PhoneCoderResponsesRequest.decode(data(#"{"model":"m","input":[{"role":"assistant","content":"hi"}]}"#)))
    }

    func testStableErrorsAndUTF8SSE() throws {
        XCTAssertThrowsError(try PhoneCoderChatRequest.decode(data("{"))) { error in
            XCTAssertEqual((error as? PhoneCoderAPIError)?.code, "invalid_request")
        }
        let pieces = ["é", "👩", "\u{200d}", "💻"]
        let context = PhoneCoderCompletionContext(id: "chat-1", model: "m", created: 123)
        let frames = try pieces.enumerated().map { try PhoneCoderAPIEncoder.sse(id: $0.offset + 1, event: .chatText(context, $0.element)) }
        for (index, frame) in frames.enumerated() {
            let string = try XCTUnwrap(String(data: frame, encoding: .utf8))
            XCTAssertTrue(string.hasPrefix("id: \(index + 1)\n"))
            XCTAssertTrue(string.hasSuffix("\n\n"))
            let line = try XCTUnwrap(string.components(separatedBy: "\n").first { $0.hasPrefix("data: ") })
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any])
            let choice = try XCTUnwrap((object["choices"] as? [[String: Any]])?.first)
            XCTAssertEqual((choice["delta"] as? [String: String])?["content"], pieces[index])
        }
    }
}

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
            #"{"model":"m","messages":[{"role":"user","content":""}],"temperature":2.1}"#,
            #"{"model":"m","messages":[{"role":"user","content":"x"}],"top_p":0}"#,
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
        let frames = try pieces.enumerated().map { try PhoneCoderAPIEncoder.sse(id: $0.offset + 1, event: .textDelta($0.element)) }
        for (index, frame) in frames.enumerated() {
            let string = try XCTUnwrap(String(data: frame, encoding: .utf8))
            XCTAssertTrue(string.hasPrefix("id: \(index + 1)\n"))
            XCTAssertTrue(string.hasSuffix("\n\n"))
            let line = try XCTUnwrap(string.components(separatedBy: "\n").first { $0.hasPrefix("data: ") })
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: String])
            XCTAssertEqual(object["delta"], pieces[index])
        }
    }
}

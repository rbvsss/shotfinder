#if DEBUG
import Foundation

/// Lets the UI tests drive the whole app on a simulator, which has no camera, using a fake Claude.
/// None of this exists in the build that goes on the phone.
enum Staging {
    static var hasKey: Bool {
        ProcessInfo.processInfo.arguments.contains("-stagedKey")
    }

    static var photoPath: String? {
        ProcessInfo.processInfo.environment["STAGED_PHOTO"]
    }

    static var scanReply: String {
        ProcessInfo.processInfo.environment["STAGED_SCAN"] ?? "centered"
    }
}

final class FakeClaude: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.anthropic.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    private static func answer(x: Int, y: Int, lens: String) -> String {
        let shot = #"{\"label\":\"distant church spires\",\"tip\":\"Keep the horizon low.\",\"x\":\#(x),\"y\":\#(y),\"lens\":\"\#(lens)\",\"look\":\"mist\"}"#
        return #"{"content":[{"type":"text","text":"\#(shot)"}],"stop_reason":"end_turn"}"#
    }

    override func startLoading() {
        let reply: (status: Int, body: String)
        switch Staging.scanReply {
        case "offline":
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        case "off-center": reply = (200, Self.answer(x: 650, y: 820, lens: "1.5"))
        case "bad-key": reply = (401, #"{"error":{"message":"invalid x-api-key"}}"#)
        case "no-credits": reply = (400, #"{"error":{"message":"Your credit balance is too low"}}"#)
        case "busy": reply = (529, #"{"error":{"message":"Overloaded"}}"#)
        case "refused": reply = (200, #"{"content":[],"stop_reason":"refusal"}"#)
        case "garbled": reply = (200, "not json")
        default: reply = (200, Self.answer(x: 450, y: 600, lens: "1"))
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
#endif

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

    private static func answer(x1: Int, y1: Int, x2: Int, y2: Int) -> String {
        let shot = #"{\"label\":\"distant church spires\",\"tip\":\"Keep the horizon low.\",\"x1\":\#(x1),\"y1\":\#(y1),\"x2\":\#(x2),\"y2\":\#(y2)}"#
        return #"{"content":[{"type":"text","text":"\#(shot)"}],"stop_reason":"end_turn"}"#
    }

    override func startLoading() {
        let reply: (status: Int, body: String)
        switch Staging.scanReply {
        case "offline":
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        case "off-center": reply = (200, Self.answer(x1: 515, y1: 730, x2: 785, y2: 910))
        case "bad-key": reply = (401, #"{"error":{"message":"invalid x-api-key"}}"#)
        case "no-credits": reply = (400, #"{"error":{"message":"Your credit balance is too low"}}"#)
        case "busy": reply = (529, #"{"error":{"message":"Overloaded"}}"#)
        case "refused": reply = (200, #"{"content":[],"stop_reason":"refusal"}"#)
        case "garbled": reply = (200, "not json")
        default: reply = (200, Self.answer(x1: 248, y1: 465, x2: 653, y2: 735))
        }

        // "slow" holds the scan long enough for a test to catch it running.
        DispatchQueue.global().asyncAfter(deadline: .now() + (Staging.scanReply == "slow" ? 3 : 0.4)) { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
#endif

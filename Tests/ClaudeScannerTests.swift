import XCTest
@testable import ShotFinder

/// Answers the scanner's requests locally. No real call is made to Claude in these tests.
final class StubProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var error: URLError?
    static var lastRequest: URLRequest?
    static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.lastBody = data
        }
        if let error = Self.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ClaudeScannerTests: XCTestCase {
    override func setUp() {
        URLProtocol.registerClass(StubProtocol.self)
        StubProtocol.status = 200
        StubProtocol.body = Data()
        StubProtocol.error = nil
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubProtocol.self)
    }

    private func scan() async throws -> ScanResult {
        try await ClaudeScanner.scan(jpeg: Data([1, 2, 3]), ratio: .fourFive, apiKey: "test-key")
    }

    private func assertFails(status: Int, json: String, matching check: (ScanError) -> Bool) async {
        StubProtocol.status = status
        StubProtocol.body = Data(json.utf8)
        do {
            _ = try await scan()
            XCTFail("Expected the scan to fail")
        } catch let error as ScanError {
            XCTAssertTrue(check(error), "Unexpected error: \(error)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReadsTheShotPastOtherBlocks() async throws {
        let shot = #"{\"label\":\"old barn\",\"tip\":\"step left\",\"center_x\":0.4,\"center_y\":0.6,\"size\":0.5}"#
        StubProtocol.body = Data(#"""
        {"content":[{"type":"thinking","thinking":""},{"type":"text","text":"\#(shot)"}],"stop_reason":"end_turn"}
        """#.utf8)

        let result = try await scan()

        XCTAssertEqual(result.label, "old barn")
        XCTAssertEqual(result.centerX, 0.4)
        XCTAssertEqual(result.size, 0.5)
    }

    func testSendsTheDocumentedRequest() async throws {
        let shot = #"{\"label\":\"a\",\"tip\":\"b\",\"center_x\":0.5,\"center_y\":0.5,\"size\":0.5}"#
        StubProtocol.body = Data(#"{"content":[{"type":"text","text":"\#(shot)"}],"stop_reason":"end_turn"}"#.utf8)

        _ = try await scan()

        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(StubProtocol.lastBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["temperature"])
    }

    func testBadKey() async {
        await assertFails(status: 401, json: #"{"error":{"message":"invalid x-api-key"}}"#) {
            if case .rejectedKey = $0 { return true }
            return false
        }
    }

    func testNoCredits() async {
        await assertFails(status: 400, json: #"{"error":{"message":"Your credit balance is too low"}}"#) {
            if case .noCredits = $0 { return true }
            return false
        }
    }

    func testBusy() async {
        await assertFails(status: 529, json: #"{"error":{"message":"Overloaded"}}"#) {
            if case .busy = $0 { return true }
            return false
        }
    }

    func testRefusal() async {
        await assertFails(status: 200, json: #"{"content":[],"stop_reason":"refusal"}"#) {
            if case .refused = $0 { return true }
            return false
        }
    }

    func testCutOffOrGarbledAnswers() async {
        let isBad: (ScanError) -> Bool = {
            if case .badResponse = $0 { return true }
            return false
        }
        await assertFails(status: 200, json: #"{"content":[{"type":"text","text":"{\"la"}],"stop_reason":"max_tokens"}"#, matching: isBad)
        await assertFails(status: 200, json: "not json", matching: isBad)
    }

    func testNoInternet() async {
        StubProtocol.error = URLError(.notConnectedToInternet)
        do {
            _ = try await scan()
            XCTFail("Expected the scan to fail")
        } catch let error as ScanError {
            guard case .noInternet = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

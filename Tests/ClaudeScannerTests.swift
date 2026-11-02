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

    private func scan(scanLens: Double = 0.5) async throws -> ScanResult {
        let frame = ScanFrame(jpeg: Data([1, 2, 3]), width: 900, height: 1200, zoomFactor: 1)
        return try await ClaudeScanner.scan(frame: frame, ratio: .square, scanLens: scanLens, apiKey: "test-key")
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

    private func answer(x1: Double, y1: Double, x2: Double, y2: Double) -> Data {
        let shot = #"{\"label\":\"old barn\",\"tip\":\"Step left.\",\"x1\":\#(x1),\"y1\":\#(y1),\"x2\":\#(x2),\"y2\":\#(y2)}"#
        return Data(#"""
        {"content":[{"type":"thinking","thinking":""},{"type":"text","text":"\#(shot)"}],"stop_reason":"end_turn"}
        """#.utf8)
    }

    func testSubjectSetsTheCentreAndTheLensThatHoldsIt() async throws {
        // A subject about a sixth of the view needs 2.25x, so it gets the 2x lens.
        StubProtocol.body = answer(x1: 280, y1: 600, x2: 440, y2: 720)

        let result = try await scan()

        XCTAssertEqual(result.label, "old barn")
        XCTAssertEqual(result.centerX, 0.4, accuracy: 0.0001)
        XCTAssertEqual(result.centerY, 0.55, accuracy: 0.0001)
        XCTAssertEqual(result.size, 0.25, accuracy: 0.0001)
    }

    func testBigSubjectUsesTheWholeView() async throws {
        StubProtocol.body = answer(x1: 0, y1: 0, x2: 900, y2: 1200)

        let result = try await scan()

        XCTAssertEqual(result.size, 1, accuracy: 0.0001)
        XCTAssertEqual(result.centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.centerY, 0.5, accuracy: 0.0001)
    }

    func testFrameNearAnEdgeIsPulledInsideTheImage() async throws {
        StubProtocol.body = answer(x1: 0, y1: 1100, x2: 90, y2: 1200)

        let result = try await scan()

        XCTAssertEqual(result.size, 0.5 / 3, accuracy: 0.0001)
        XCTAssertEqual(result.centerX, 0.5 / 3 / 2, accuracy: 0.0001)
        XCTAssertEqual(result.centerY, 1 - 0.0625, accuracy: 0.0001)
    }

    func testEmptySubjectIsRejected() async {
        await assertFails(status: 200, json: String(decoding: answer(x1: 500, y1: 500, x2: 400, y2: 400), as: UTF8.self)) {
            if case .badResponse = $0 { return true }
            return false
        }
    }

    func testSendsTheDocumentedRequest() async throws {
        StubProtocol.body = answer(x1: 300, y1: 300, x2: 500, y2: 500)

        _ = try await scan()

        let request = try XCTUnwrap(StubProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(StubProtocol.lastBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(body["fallbacks"] as? String, "default")
        XCTAssertEqual((body["output_config"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertNil(body["thinking"])
        XCTAssertNil(body["temperature"])
        let sent = String(decoding: try XCTUnwrap(StubProtocol.lastBody), as: UTF8.self)
        XCTAssertTrue(sent.contains("900x1200 pixels"))
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

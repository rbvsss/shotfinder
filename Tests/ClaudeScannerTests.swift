import CoreImage
import UIKit
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

    private func scan(scanLens: Double = 0.5, isClose: Bool = false) async throws -> ScanResult {
        let frame = ScanFrame(jpeg: Data([1, 2, 3]), width: 900, height: 1200, zoomFactor: 1)
        return try await ClaudeScanner.scan(frame: frame, ratio: .square, scanLens: scanLens, isClose: isClose, apiKey: "test-key")
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

    private func answer(x1: Double, y1: Double, x2: Double, y2: Double, extra: String = "") -> Data {
        let shot = #"{\"label\":\"old barn\",\"tip\":\"Step left.\",\"x1\":\#(x1),\"y1\":\#(y1),\"x2\":\#(x2),\"y2\":\#(y2)\#(extra)}"#
        return Data(#"""
        {"content":[{"type":"thinking","thinking":""},{"type":"text","text":"\#(shot)"}],"stop_reason":"end_turn"}
        """#.utf8)
    }

    func testSubjectSetsTheCentreAndTheLensThatHoldsIt() async throws {
        // A subject under a fifth of the view wide needs 2.5x to fill nine tenths of the frame.
        StubProtocol.body = answer(x1: 279, y1: 600, x2: 441, y2: 720)

        let result = try await scan()

        XCTAssertEqual(result.label, "old barn")
        XCTAssertEqual(result.centerX, 0.4, accuracy: 0.0001)
        XCTAssertEqual(result.centerY, 0.55, accuracy: 0.0001)
        XCTAssertEqual(result.size, 0.2, accuracy: 0.0001)
    }

    func testSidewaysScanIsSentUprightAndMappedBack() throws {
        // A white patch near the top right of a portrait viewfinder, 30 by 40 pixels.
        let size = CGSize(width: 30, height: 40)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            context.fill(CGRect(x: 18, y: 4, width: 9, height: 8))
        }
        let source = CIImage(cgImage: try XCTUnwrap(drawn.cgImage))

        for turns in [-1, 0, 1, 2] {
            let upright = CameraController.upright(source, quarterTurns: turns)
            let image = try XCTUnwrap(CIContext().createCGImage(upright, from: upright.extent))
            let found = try XCTUnwrap(whiteBox(in: image), "turns \(turns)")
            let frame = ScanFrame(jpeg: Data(), width: image.width, height: image.height, zoomFactor: 1, quarterTurns: turns)

            let back = frame.viewBox(found)
            XCTAssertEqual(back.minX, 0.6, accuracy: 0.01, "turns \(turns)")
            XCTAssertEqual(back.minY, 0.1, accuracy: 0.01, "turns \(turns)")
            XCTAssertEqual(back.width, 0.3, accuracy: 0.01, "turns \(turns)")
            XCTAssertEqual(back.height, 0.2, accuracy: 0.01, "turns \(turns)")

            if turns == -1 {
                // Turned anticlockwise, the right of the viewfinder is the top of the scene.
                XCTAssertEqual(image.width, 40)
                XCTAssertLessThan(found.midY, 0.5)
                XCTAssertLessThan(found.midX, 0.5)
            }
        }
    }

    /// The white area of an image, as fractions measured from its top left.
    private func whiteBox(in image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4] > 128 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(
            x: Double(minX) / Double(width),
            y: Double(minY) / Double(height),
            width: Double(maxX - minX + 1) / Double(width),
            height: Double(maxY - minY + 1) / Double(height)
        )
    }

    func testClaudesOwnFrameSetsTheZoomAndTheLook() async throws {
        // A frame half the view wide and high, around a subject well inside it. The square crop is
        // three quarters of the view high, so it takes two thirds of the view: 0.7x, a tenth down.
        StubProtocol.body = answer(x1: 279, y1: 600, x2: 441, y2: 720, extra: #",\"fx1\":225,\"fy1\":300,\"fx2\":675,\"fy2\":900,\"look\":\"cinder\""#)

        let result = try await scan()

        XCTAssertEqual(result.size, 0.5 / 0.7, accuracy: 0.0001)
        XCTAssertEqual(result.centerX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.centerY, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.look, .cinder)
    }

    func testCloseFramingTightensALooseFrame() async throws {
        // The same loose frame, but close framing lets the subject fill no less than three quarters:
        // 0.18 of the view wide needs 0.24 of it, which is 2x after rounding down.
        StubProtocol.body = answer(x1: 279, y1: 600, x2: 441, y2: 720, extra: #",\"fx1\":225,\"fy1\":300,\"fx2\":675,\"fy2\":900,\"look\":\"cinder\""#)

        let result = try await scan(isClose: true)

        XCTAssertEqual(result.size, 0.25, accuracy: 0.0001)
    }

    func testFrameIsMovedToHoldTheWholeSubject() async throws {
        // The frame sits in the top left corner, but the subject reaches lower than it does.
        StubProtocol.body = answer(x1: 279, y1: 600, x2: 441, y2: 720, extra: #",\"fx1\":0,\"fy1\":0,\"fx2\":450,\"fy2\":600,\"look\":\"natural\""#)

        let result = try await scan()

        // Down until the subject's lower edge is in with a little air, and right until the frame is inside the image.
        XCTAssertEqual(result.size, 0.5 / 0.7, accuracy: 0.0001)
        XCTAssertEqual(result.centerX, 0.5 / 0.7 / 2, accuracy: 0.0001)
        XCTAssertEqual(result.centerY, 0.6 - 0.9 * (0.5 / 0.7 * 0.75 / 2), accuracy: 0.0001)
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

        XCTAssertEqual(result.size, 0.125, accuracy: 0.0001)
        XCTAssertEqual(result.centerX, 0.0625, accuracy: 0.0001)
        XCTAssertEqual(result.centerY, 1 - 0.125 * 0.75 / 2, accuracy: 0.0001)
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
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
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

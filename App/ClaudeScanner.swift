import Foundation

/// A video frame prepared for scanning. Its size is sent with it so Claude's pixels map back exactly.
struct ScanFrame {
    let jpeg: Data
    let width: Int
    let height: Int
    let zoomFactor: Double
}

/// The shot Claude picked. Coordinates are fractions of the image, measured from the top left.
struct ScanResult {
    let label: String
    let tip: String
    let centerX: Double
    let centerY: Double
    /// The shot's width as a fraction of the image width.
    let size: Double
    let look: Look
}

enum ScanError: LocalizedError {
    case rejectedKey
    case noCredits
    case busy
    case noInternet
    case timedOut
    case api(String)
    case refused
    case badResponse
    case cameraNotReady

    var errorDescription: String? {
        switch self {
        case .cameraNotReady: return "The camera isn't ready. Try again."
        case .rejectedKey: return "Claude didn't accept this API key."
        case .noCredits: return "Your Claude API credits have run out."
        case .busy: return "Claude is busy. Try again in a moment."
        case .noInternet: return "No internet. Scanning needs a connection."
        case .timedOut: return "The scan took too long. Try again."
        case .api(let message): return message
        case .refused: return "Claude declined to scan this scene."
        case .badResponse: return "The scan failed. Try again."
        }
    }
}

enum ClaudeScanner {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let systemPrompt = """
    You are a picture editor with a sharp eye. This is the ultra-wide view from a phone. Pick the one \
    photograph worth taking inside it. The photographer will turn to your frame, zoom in and shoot \
    exactly what it holds.

    How to choose:
    - Pick one clear subject: a thing or tight group with light on it, colour, texture, or a shape that \
    stands apart from its surroundings. Choose the obvious best subject, not a clever one, so the same \
    scene gets the same answer.
    - Frame it tightly. Zooming compresses depth and removes clutter, so a 2x to 4x frame almost always \
    beats a wide one. Go wider only when the breadth itself is the picture, such as a landscape, a \
    skyline or a dramatic sky.
    - Keep layers when they are there: something in front of or behind the subject gives depth.
    - Centre the frame on the subject itself, then check the edges: nothing important cut, no bright \
    scraps at the border, and no more than a third of the frame empty wall, ceiling or sky, or plain \
    foreground such as a tablecloth, floor or road.

    Never choose:
    - A screen, poster or picture as the subject.
    - The photographer's own legs, feet, lap or hands, which often show at the bottom of the view.
    - Anything lost in shadow, or too small and far away to be sharp.
    - A ceiling or wall with little else in the frame.

    Return:
    - label: what the shot shows, in 2 to 4 specific lowercase words.
    - tip: one short sentence under 9 words, ending in a full stop, on what makes this frame work and \
    how to hold it. It must be possible with only the phone: never ask to move things, change lights or \
    wait for something unlikely. Examples: "Keep the bowls low in the frame." "Let the lamp glow \
    against the dark wall."
    - x, y: the centre of your frame, in pixels of this image, where 0,0 is the top left corner.
    - lens: the lens for your frame, from the list given with the image.
    - look: the colour treatment that suits this picture.
      natural: true colour.
      honey: warm and golden, for lamplight, skin and evening.
      noon: clean and bright, for daylight.
      mist: cool soft pastels, for overcast light, water and greenery.
      reef: saturated, for blue skies, foliage and strong colour.
      lantern: teal shadows and ember highlights, for night, lamps and streets.
      attic: a faded old print, for quiet interiors and old things.
      riot: punchy and high contrast, for flash, bold colour and the city.
      soot: black and white, for hard shapes or when the colours are ugly.
    """

    /// The zooms Claude can choose from. Whole frames only, so the box always matches a real view.
    private static let lenses = ["0.7", "1", "1.5", "2", "2.5", "3", "4"]

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "label": ["type": "string"],
            "tip": ["type": "string"],
            "x": ["type": "number"],
            "y": ["type": "number"],
            "lens": ["type": "string", "enum": lenses],
            "look": ["type": "string", "enum": Look.allCases.map(\.rawValue)]
        ],
        "required": ["label", "tip", "x", "y", "lens", "look"],
        "additionalProperties": false
    ]

    static func scan(frame: ScanFrame, ratio: CaptureRatio, scanLens: Double, apiKey: String) async throws -> ScanResult {
        let crop = ratio.cropInViewfinder
        let frames = lenses.compactMap { name -> String? in
            guard let lens = Double(name) else { return nil }
            let scale = min(scanLens / lens, 1)
            let width = Int(Double(frame.width) * Double(crop.width) * scale)
            let height = Int(Double(frame.height) * Double(crop.height) * scale)
            return "\(name): \(width)x\(height)"
        }
        let request = """
        This image is \(frame.width)x\(frame.height) pixels. Your frame is \(ratio.rawValue) (width to height). \
        Each lens gives a frame of this size in pixels of this image: \(frames.joined(separator: ", ")).
        """
        let body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 6000,
            "fallbacks": "default",
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema]
            ],
            "system": systemPrompt,
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": frame.jpeg.base64EncodedString()
                        ]
                    ],
                    ["type": "text", "text": request]
                ]
            ]]
        ]

        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 60)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .cannotFindHost, .cannotConnectToHost:
                throw ScanError.noInternet
            case .timedOut:
                throw ScanError.timedOut
            default:
                throw error
            }
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw failure(status: status, data: data)
        }

        guard let message = try? JSONDecoder().decode(APIMessage.self, from: data) else {
            throw ScanError.badResponse
        }
        if message.stopReason == "refusal" { throw ScanError.refused }
        guard message.stopReason != "max_tokens",
              let text = message.content.first(where: { $0.type == "text" })?.text,
              let shot = try? JSONDecoder().decode(Shot.self, from: Data(text.utf8)),
              let result = shot.result(in: frame, crop: crop, scanLens: scanLens) else {
            throw ScanError.badResponse
        }
        return result
    }

    private struct Shot: Decodable {
        let label: String
        let tip: String
        let x: Double
        let y: Double
        let lens: String
        let look: Look

        /// The lens sets the frame's size, and the frame is then kept inside the image.
        func result(in frame: ScanFrame, crop: CGSize, scanLens: Double) -> ScanResult? {
            guard let zoom = Double(lens), zoom > 0 else { return nil }
            let scale = min(scanLens / zoom, 1)
            let halfWidth = scale * Double(crop.width) / 2
            let halfHeight = scale * Double(crop.height) / 2
            return ScanResult(
                label: label,
                tip: tip,
                centerX: min(max(x / Double(frame.width), halfWidth), 1 - halfWidth),
                centerY: min(max(y / Double(frame.height), halfHeight), 1 - halfHeight),
                size: scale * Double(crop.width),
                look: look
            )
        }
    }

    private static func failure(status: Int, data: Data) -> ScanError {
        let message = (try? JSONDecoder().decode(APIFailure.self, from: data))?.error.message
        if message?.lowercased().contains("credit") == true { return .noCredits }
        switch status {
        case 401, 403: return .rejectedKey
        case 402: return .noCredits
        case 429, 500, 503, 529: return .busy
        default: return .api(message ?? "The scan failed (error \(status)).")
        }
    }

    private struct APIMessage: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    private struct APIFailure: Decodable {
        struct Detail: Decodable {
            let message: String
        }
        let error: Detail
    }
}

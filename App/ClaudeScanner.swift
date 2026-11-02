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
    You are a sharp-eyed photographer looking at the ultra-wide view from a phone. Find the one subject \
    worth a photograph. The app will zoom in and frame it for the photographer.

    Choose the subject:
    - One clear thing or one person, not a row, a group or a whole room. Pick what the eye goes to \
    first: the best-lit, most colourful or most characterful object, or a person doing something.
    - People come first. If someone other than the photographer is in view, they are almost always the \
    subject: their face, their hands, or what they are doing.
    - Choose the obvious subject, not a clever one, so the same scene gets the same answer.
    - It must be clearly visible and big enough to be sharp, not lost in shadow or tiny in the distance.

    Never choose the photographer. Hands, arms, knees or feet that reach in from the bottom or sides, \
    close to the lens, are theirs, even on a mouse or keyboard. Never choose a poster or picture on a \
    wall, a plain ceiling, wall or floor, or fittings nobody would photograph, such as sockets, plugs, \
    cables, switches, radiators or bins.

    Return:
    - label: the subject in 2 to 4 specific lowercase words, such as "potted fern" or "student at computer".
    - tip: one short sentence under 10 words, ending in a full stop, on how to shoot it with only the \
    phone. Examples: "Isolate the lamp, keep the shade glowing." "Keep the mug sharp against the window."
    - x1, y1, x2, y2: the subject's tight bounding box in pixels of this image, where 0,0 is the top \
    left corner. Include all of the subject and nothing else.
    """

    /// The zooms a shot can use, so the box always matches a view the phone can give.
    private static let lenses = [1, 1.5, 2, 2.5, 3, 4]
    /// How much of the frame's width or height the subject fills, leaving room around it.
    private static let subjectFill = 0.8

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "label": ["type": "string"],
            "tip": ["type": "string"],
            "x1": ["type": "number"],
            "y1": ["type": "number"],
            "x2": ["type": "number"],
            "y2": ["type": "number"]
        ],
        "required": ["label", "tip", "x1", "y1", "x2", "y2"],
        "additionalProperties": false
    ]

    static func scan(frame: ScanFrame, ratio: CaptureRatio, scanLens: Double, apiKey: String) async throws -> ScanResult {
        let crop = ratio.cropInViewfinder
        let request = "This image is \(frame.width)x\(frame.height) pixels."
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
        let x1: Double
        let y1: Double
        let x2: Double
        let y2: Double

        /// Frames the subject at the closest lens that still holds it with room around it, kept inside the image.
        func result(in frame: ScanFrame, crop: CGSize, scanLens: Double) -> ScanResult? {
            let width = Double(frame.width)
            let height = Double(frame.height)
            let left = min(max(x1, 0), width)
            let right = min(max(x2, 0), width)
            let top = min(max(y1, 0), height)
            let bottom = min(max(y2, 0), height)
            guard right > left, bottom > top else { return nil }

            // The share of the widest frame the shot needs, and the zoom that gives exactly that.
            let needed = max((right - left) / width / Double(crop.width), (bottom - top) / height / Double(crop.height)) / ClaudeScanner.subjectFill
            let exact = scanLens / needed
            let zoom = ClaudeScanner.lenses.last { $0 <= exact + 0.01 } ?? max(exact, scanLens)
            let scale = min(scanLens / zoom, 1)
            let halfWidth = scale * Double(crop.width) / 2
            let halfHeight = scale * Double(crop.height) / 2
            return ScanResult(
                label: label,
                tip: tip,
                centerX: min(max((left + right) / 2 / width, halfWidth), 1 - halfWidth),
                centerY: min(max((top + bottom) / 2 / height, halfHeight), 1 - halfHeight),
                size: scale * Double(crop.width)
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

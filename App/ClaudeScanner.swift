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
    You are an experienced photographer standing beside a friend, looking at the wide view from \
    their phone camera. They will frame and take exactly the box you choose, so choose the one \
    picture you would stop and take yourself.

    A strong shot has one clear subject, or one clear idea such as a line, a pattern or a patch \
    of light, set against the simplest background this view allows. Frame to that and leave out \
    what competes with it. Give the subject room, especially on the side it faces, and let it sit \
    off centre when that looks better.

    Check all four edges of the box before you answer. Each thing the box meets should be either \
    well inside it or cut decisively; a sliver or a clipped end looks like a mistake. Cut people \
    between joints, never at the neck, wrist, knee or ankle.

    This applies to any scene, from a room to a landscape. When nothing stands out, commit to the \
    best shape, light or texture there is. When the whole scene is the picture, frame it wide.

    Return:
    - label: what the shot shows, in 2 to 4 specific words, never a generic word like "subject".
    - tip: one short instruction for this scene that framing alone can't do, under 8 words, in \
    sentence case with no full stop. Examples: "Step left to clear the pole", "Wait for someone \
    to cross", "Keep the shelf edge level".
    - x1, y1, x2, y2: the top left and bottom right corners of the box, in pixels of this image, \
    where 0,0 is the top left corner.
    """

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

    static func scan(frame: ScanFrame, ratio: CaptureRatio, apiKey: String) async throws -> ScanResult {
        let crop = ratio.cropInViewfinder
        let widest = Int(Double(frame.width) * Double(crop.width))
        let tallness = String(format: "%.3f", 1 / Double(ratio.widthOverHeight))
        let request = """
        This image is \(frame.width)x\(frame.height) pixels. The box must be \(ratio.rawValue) (width to \
        height), so its height is \(tallness) times its width. It can be from \(frame.width / 10) to \
        \(widest) pixels wide and must stay inside the image.
        """
        let body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 16000,
            "fallbacks": "default",
            "output_config": [
                "effort": "medium",
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

        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 45)
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
              let box = try? JSONDecoder().decode(ShotBox.self, from: Data(text.utf8)),
              let result = box.result(in: frame, crop: crop) else {
            throw ScanError.badResponse
        }
        return result
    }

    private struct ShotBox: Decodable {
        let label: String
        let tip: String
        let x1: Double
        let y1: Double
        let x2: Double
        let y2: Double

        /// Grows to the smallest frame that holds the box, then keeps that frame inside the image.
        func result(in frame: ScanFrame, crop: CGSize) -> ScanResult? {
            let width = Double(frame.width)
            let height = Double(frame.height)
            let cropWidth = Double(crop.width)
            let cropHeight = Double(crop.height)
            let left = min(max(x1, 0), width)
            let right = min(max(x2, 0), width)
            let top = min(max(y1, 0), height)
            let bottom = min(max(y2, 0), height)
            guard right > left, bottom > top else { return nil }

            let scale = min(max((right - left) / width / cropWidth, (bottom - top) / height / cropHeight), 1)
            let halfWidth = scale * cropWidth / 2
            let halfHeight = scale * cropHeight / 2
            return ScanResult(
                label: label,
                tip: tip,
                centerX: min(max((left + right) / 2 / width, halfWidth), 1 - halfWidth),
                centerY: min(max((top + bottom) / 2 / height, halfHeight), 1 - halfHeight),
                size: scale * cropWidth
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

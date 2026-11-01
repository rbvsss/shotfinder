import Foundation

/// The shot Claude picked. Coordinates are fractions of the image, measured from the top left.
struct ScanResult: Decodable {
    let label: String
    let tip: String
    let centerX: Double
    let centerY: Double
    let size: Double

    enum CodingKeys: String, CodingKey {
        case label, tip, size
        case centerX = "center_x"
        case centerY = "center_y"
    }
}

enum ScanError: LocalizedError {
    case missingKey
    case rejectedKey
    case noCredits
    case busy
    case noInternet
    case timedOut
    case api(String)
    case refused
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your Claude API key to scan."
        case .rejectedKey: return "Claude didn't accept this API key."
        case .noCredits: return "Your Claude API credits have run out."
        case .busy: return "Claude is busy. Try again in a moment."
        case .noInternet: return "No internet. Scanning needs a connection."
        case .timedOut: return "The scan took too long. Try again."
        case .api(let message): return message
        case .refused: return "Claude declined to scan this scene."
        case .badResponse: return "The scan didn't come back right. Try again."
        }
    }
}

enum ClaudeScanner {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let systemPrompt = """
    You are an experienced photographer looking through a camera with a friend. The image is \
    the wide view from their phone. Find the single most rewarding photo available inside this \
    view and mark where it is.

    Return:
    - label: what the shot is, in 2 to 4 lowercase words, such as "distant church spires".
    - tip: one short lowercase instruction for getting the shot, under 8 words.
    - center_x, center_y: the centre of the shot as fractions of the image from 0 to 1, where \
    0,0 is the top left corner.
    - size: the width of the shot as a fraction of the image width. Place the shot so that the \
    subject sits well in the frame, and keep the whole shot inside the image.
    """

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "label": ["type": "string"],
            "tip": ["type": "string"],
            "center_x": ["type": "number"],
            "center_y": ["type": "number"],
            "size": ["type": "number"]
        ],
        "required": ["label", "tip", "center_x", "center_y", "size"],
        "additionalProperties": false
    ]

    static func scan(jpeg: Data, ratio: CaptureRatio, apiKey: String) async throws -> ScanResult {
        let maximumSize = String(format: "%.2f", ratio.cropInViewfinder.width)
        let request = """
        Find the shot. It will be cropped to a \(ratio.rawValue) shape (width to height, portrait), \
        so size can be anywhere from 0.15 to \(maximumSize).
        """
        let body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 4000,
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
                            "data": jpeg.base64EncodedString()
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
              let result = try? JSONDecoder().decode(ScanResult.self, from: Data(text.utf8)),
              result.centerX.isFinite, result.centerY.isFinite, result.size.isFinite else {
            throw ScanError.badResponse
        }
        return result
    }

    private static func failure(status: Int, data: Data) -> ScanError {
        let message = (try? JSONDecoder().decode(APIFailure.self, from: data))?.error.message
        if message?.lowercased().contains("credit") == true { return .noCredits }
        switch status {
        case 401, 403: return .rejectedKey
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

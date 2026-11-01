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
    case api(String)
    case refused
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your Claude API key in settings first."
        case .rejectedKey: return "Claude rejected this API key. Check it in settings."
        case .api(let message): return message
        case .refused: return "Claude declined to scan this scene."
        case .badResponse: return "Claude sent an answer the app couldn't read. Try again."
        }
    }
}

enum ClaudeScanner {
    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    private static let systemPrompt = """
    You are an experienced photographer looking through a camera with a friend. The image is \
    the wide view from their phone, held in portrait. Find the single most rewarding photo \
    available inside this view and mark where it is.

    Return:
    - label: what the shot is, in 2 to 4 lowercase words, such as "distant church spires".
    - tip: one short lowercase instruction for getting the shot, under 8 words.
    - center_x, center_y: the centre of the shot as fractions of the image from 0 to 1, where \
    0,0 is the top left corner.
    - size: the width of the shot as a fraction of the image width, from 0.15 to 1. The shot \
    keeps the same 3:4 shape as the image, so its height is the same fraction of the image \
    height. Place it so that the subject sits well in the frame, and keep it inside the image.
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

    static func scan(jpeg: Data, apiKey: String) async throws -> ScanResult {
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
                    ["type": "text", "text": "Find the shot."]
                ]
            ]]
        ]

        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 { throw ScanError.rejectedKey }
            let failure = try? JSONDecoder().decode(APIFailure.self, from: data)
            throw ScanError.api(failure?.error.message ?? "Claude returned error \(status).")
        }

        let message = try JSONDecoder().decode(APIMessage.self, from: data)
        if message.stopReason == "refusal" { throw ScanError.refused }
        guard message.stopReason != "max_tokens",
              let text = message.content.first(where: { $0.type == "text" })?.text,
              let result = try? JSONDecoder().decode(ScanResult.self, from: Data(text.utf8)),
              result.centerX.isFinite, result.centerY.isFinite, result.size.isFinite else {
            throw ScanError.badResponse
        }
        return result
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

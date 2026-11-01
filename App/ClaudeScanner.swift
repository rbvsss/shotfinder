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
    You are a picture editor with the eye of a great photographer. You are looking at the ultra-wide \
    view from a friend's iPhone. Somewhere inside it is a photograph far better than this whole view. \
    Find it. Your friend will turn the phone to your box, zoom to it and shoot exactly what is inside \
    it, so judge the box as a finished print, as if it had to earn a place in a magazine or on the wall.

    Look for what a good eye sees and everyone else walks past:
    - Light first. Where is light doing something: a window falling across a surface, a rim on an edge, \
    long shadows, a lit shape against dark, glow at dusk, a bright patch in a dim room? Great pictures \
    are usually about light before they are about things.
    - Then shape. Strong geometry, a clean silhouette, repetition with one thing out of step, lines that \
    carry the eye to the subject, layers from near to far, a reflection, a frame within the frame.
    - Then colour. One accent against quiet surroundings, two colours that belong together, a palette \
    that holds the picture together.
    - A clear idea. Say in a few words why this picture exists. If you can't, it isn't the picture.

    Be bold and specific. The safe, literal answer is usually wrong: the largest object, the middle of \
    the view, the whole scene shrunk slightly, or a plain record of an object sitting in a room. Crop \
    hard to what matters, and leave out empty sky, empty ground and clutter that carry nothing. Use \
    empty space only when it is doing work in the design. Keep a wide frame only when the breadth \
    itself is the picture.

    Before you answer, walk the whole frame, including its corners, and consider at least four really \
    different pictures: a wide one, a tight detail, a graphic abstract, and one built on the light. \
    Score each honestly on light, clarity of subject, composition and clean edges, and ask whether you \
    would be proud to post it. Take the best, then refine its box:
    - Check all four edges. Whatever the box meets must be well inside it or cut decisively. Remove \
    slivers, clipped ends, bright spots near the edge, signs, wires, bins and parked cars unless they \
    are the idea.
    - Place the subject with intent, off centre unless symmetry is the point, with room on the side it \
    faces. Keep a horizon clearly high or low, never through the middle unless it is a reflection. The \
    box can't rotate, so judge a tilted view as if it were levelled.
    - Cut people between joints, never at the neck, wrist, knee or ankle.
    - Keep out of the box the photographer's own body, hands and knees, and reflections in the window \
    they shoot through, unless those are the idea.
    - Never make a screen or a picture on the wall the subject.

    Stay honest about what the camera can do:
    - Only pick what is visible and has real detail. In a dark scene, build the picture from the lights \
    and the shapes they reveal; don't pick anything lost in black.
    - The request gives the box widths where the lenses are sharpest. Prefer a box near one of these \
    when it suits the picture, and don't go narrower than the narrowest unless the subject truly needs \
    it. Distant detail gets soft.
    - Your friend can't move what's in the scene. A ceiling, a wall or a floor stays dull however it's \
    framed, so when a view is truly plain, give your best box and use the tip to say where better light \
    looks to be.

    Return:
    - label: what the shot shows, in 2 to 4 specific lowercase words, never a generic word like "subject".
    - tip: one short instruction for this scene that framing alone can't do, under 8 words, in sentence \
    case with no full stop. Examples: "Step left to clear the pole", "Wait for someone to cross", \
    "Crouch to line up the shadow".
    - x1, y1, x2, y2: the top left and bottom right corners of the box, in pixels of this image, where \
    0,0 is the top left corner.
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
        \(widest) pixels wide and must stay inside the image. The lenses are sharpest at about \(widest / 2), \
        \(widest / 4) and \(widest / 8) pixels wide (the 1x, 2x and 4x lenses).
        """
        let body: [String: Any] = [
            "model": "claude-opus-5-5",
            "max_tokens": 16000,
            "fallbacks": "default",
            "output_config": [
                "effort": "high",
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

        // Claude thinks about the picture first, which takes a while at this effort.
        var urlRequest = URLRequest(url: endpoint, timeoutInterval: 300)
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

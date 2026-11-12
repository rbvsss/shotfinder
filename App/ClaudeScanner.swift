import Foundation

/// A video frame prepared for scanning. Its size is sent with it so Claude's pixels map back exactly.
struct ScanFrame {
    let jpeg: Data
    let width: Int
    let height: Int
    let zoomFactor: Double
    /// Quarter turns clockwise the phone was held at. The image is sent turned upright to match.
    var quarterTurns = 0

    /// Takes a box given as fractions of the upright image back to fractions of the viewfinder.
    func viewBox(_ box: CGRect) -> CGRect {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return CGRect(x: box.minY, y: 1 - box.maxX, width: box.height, height: box.width)
        case 2: return CGRect(x: 1 - box.maxX, y: 1 - box.maxY, width: box.width, height: box.height)
        case 3: return CGRect(x: 1 - box.maxY, y: box.minX, width: box.height, height: box.width)
        default: return box
        }
    }
}

/// The shot Claude picked. Coordinates are fractions of the image, measured from the top left.
struct ScanResult {
    let label: String
    let tip: String
    let centerX: Double
    let centerY: Double
    /// The shot's width as a fraction of the image width.
    let size: Double
    /// The subject itself, as fractions of the image, for following it in the live picture.
    var subject: CGRect?
    /// The colour look Claude suggests for this shot.
    var look: Look?
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
    You are a professional photographer scouting a scene through the ultra-wide view of a phone. Find \
    the one shot a pro would walk over and take, and frame it. The app zooms in and guides the \
    photographer to your frame.

    Pick the subject:
    - Pull: what the eye goes to first. Strong colour against a quiet background, a pool of light, bold \
    graphics or lettering, a rich texture, a striking shape.
    - People first: anyone other than the photographer, with their face, hands or what they are doing, \
    is almost always the shot.
    - One thing that reads clearly on its own, big enough to stay sharp when zoomed. Not a row, a group \
    or a whole room.
    - The obvious best subject, not a clever one, so the same scene always gets the same answer.
    - Never the photographer's own hands, arms, knees or feet. Never an empty wall, ceiling or floor, or \
    fittings nobody photographs: vents, sockets, cables, switches, radiators, bins, plain ceiling \
    lights.

    Compose the frame, a crop of this image in the shape given with it, the way a film still is \
    composed:
    - Go in close. The subject fills two thirds to three quarters of the frame's width or height. When \
    unsure, go tighter: a frame that is nearly all subject beats one that is half surroundings.
    - Place it with intent: on a third with space in the direction it faces or moves, or dead centre \
    when the scene is symmetrical.
    - Keep what adds to the picture, such as light falling on it, a leading line, a foreground edge or a \
    reflection. Leave out clutter, bright distractions and anything cut off awkwardly at the frame edge.
    - Every part of the subject is inside the frame with a little air around it: no clipped tips, feet, \
    wheels, letters or edges. The frame stays inside the image.

    Return:
    - label: the subject in 2 or 3 plain lowercase words, the way you would say it out loud, such as \
    "red neon sign" or "woman reading".
    - tip: the one thing that makes this exact shot better, which the app cannot do itself. The app \
    already aims and zooms, so never say to step back, move closer, zoom or centre. Choose whatever \
    matters most here: a moment to wait for, where to tap to focus or expose, an angle, a line to keep \
    straight, a reflection or shadow to include. Name the actual thing in the scene. Do not suggest \
    crouching unless the subject is on the ground. Two short instructions joined by a comma, 4 to 7 \
    words in all, ending in a full stop.
    - x1, y1, x2, y2: the subject's tight bounding box in pixels of this image, where 0,0 is the top \
    left corner.
    - fx1, fy1, fx2, fy2: the frame, in the same pixels.
    - look: the colour that suits this shot. "natural" is true colour, for when nothing else clearly \
    fits. "kiln" is warm, soft and honeyed, for people and gentle indoor light. "amber" is golden with \
    teal shadows and firm contrast, for sunsets, low sun and warm lamps. "fjord" is cool, airy and \
    pastel, for daylight, water and greenery. "moss" is faded and earthy with matte blacks, for quiet, \
    worn or overcast scenes. "cinder" is dark and dense with teal shadows, for moody rooms and dim \
    streets. "neon" is violet shadows with hot magenta and cyan, for city lights and signs at night. \
    "salt" is pale, bright and chalky, for minimal high-key scenes. "graphite" is black and white, for \
    strong shapes, shadows and silhouettes.
    """

    /// The longest zoom a shot can ask for, where the telephoto still gives a clean picture.
    private static let longestZoom = 4.0
    /// The most of the frame the subject may fill, which leaves a little air on every side.
    private static let subjectFill = 0.9
    /// The least it fills with close framing on, however loose a frame Claude draws.
    private static let closeFill = 0.75

    private static let schema: [String: Any] = [
        "type": "object",
        "properties": [
            "label": ["type": "string"],
            "tip": ["type": "string"],
            "x1": ["type": "number"],
            "y1": ["type": "number"],
            "x2": ["type": "number"],
            "y2": ["type": "number"],
            "fx1": ["type": "number"],
            "fy1": ["type": "number"],
            "fx2": ["type": "number"],
            "fy2": ["type": "number"],
            "look": ["type": "string", "enum": Look.allCases.map(\.rawValue)]
        ],
        "required": ["label", "tip", "x1", "y1", "x2", "y2", "fx1", "fy1", "fx2", "fy2", "look"],
        "additionalProperties": false
    ]

    /// `isClose` keeps the frame tight on the subject. Without it Claude's own, wider frame is used as drawn.
    static func scan(frame: ScanFrame, ratio: CaptureRatio, scanLens: Double, isClose: Bool = false, apiKey: String) async throws -> ScanResult {
        let crop = ratio.cropInViewfinder
        // The photo's shape in the scene: the chosen ratio, on its side when the phone is.
        let sides = ratio.rawValue.split(separator: ":")
        let shape = frame.quarterTurns % 2 == 0 ? ratio.rawValue : sides.reversed().joined(separator: ":")
        let request = "This image is \(frame.width)x\(frame.height) pixels. The frame is \(shape), width to height."
        let body: [String: Any] = [
            "model": "claude-sonnet-5-5",
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
              let result = shot.result(in: frame, crop: crop, scanLens: scanLens, isClose: isClose) else {
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
        let fx1: Double?
        let fy1: Double?
        let fx2: Double?
        let fy2: Double?
        let look: String?

        /// A box in the image's pixels as fractions of the viewfinder. Nil when it is empty.
        /// The image was sent upright, so an answer from a sideways phone is turned back.
        private static func viewBox(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, in frame: ScanFrame) -> CGRect? {
            let width = Double(frame.width)
            let height = Double(frame.height)
            let left = min(max(x1, 0), width)
            let right = min(max(x2, 0), width)
            let top = min(max(y1, 0), height)
            let bottom = min(max(y2, 0), height)
            guard right > left, bottom > top else { return nil }
            return frame.viewBox(CGRect(x: left / width, y: top / height, width: (right - left) / width, height: (bottom - top) / height))
        }

        /// The nearest middle to `middle` for a span of `half` each way that still covers `low` to `high`.
        /// A subject too big for the span is centred in it.
        private static func holding(_ low: Double, _ high: Double, from middle: Double, half: Double) -> Double {
            guard high - low <= 2 * half else { return (low + high) / 2 }
            return min(max(middle, high - half), low + half)
        }

        /// The zoom and place of Claude's frame, never too tight for the subject and kept inside the image.
        func result(in frame: ScanFrame, crop: CGSize, scanLens: Double, isClose: Bool) -> ScanResult? {
            guard let subject = Self.viewBox(x1, y1, x2, y2, in: frame) else { return nil }
            let cropWidth = Double(crop.width)
            let cropHeight = Double(crop.height)
            let subjectShare = max(Double(subject.width) / cropWidth, Double(subject.height) / cropHeight)

            // The share of the widest view the shot needs, and where its middle is.
            var needed = subjectShare / ClaudeScanner.subjectFill
            var middle = CGPoint(x: subject.midX, y: subject.midY)
            if let fx1, let fy1, let fx2, let fy2, let composed = Self.viewBox(fx1, fy1, fx2, fy2, in: frame) {
                needed = max(Double(composed.width) / cropWidth, Double(composed.height) / cropHeight, needed)
                middle = CGPoint(x: composed.midX, y: composed.midY)
            }
            if isClose {
                needed = min(needed, subjectShare / ClaudeScanner.closeFill)
            }
            // To a tenth, as the zoom row shows it, and downwards so the frame is never tighter than asked.
            let exact = (scanLens / needed * 10 + 0.0001).rounded(.down) / 10
            let zoom = min(max(exact, scanLens), ClaudeScanner.longestZoom)
            let scale = min(scanLens / zoom, 1)
            let halfWidth = scale * Double(crop.width) / 2
            let halfHeight = scale * Double(crop.height) / 2
            // Slide the frame so the subject and the air around it are inside, then keep it inside the image.
            let air = 1 - ClaudeScanner.subjectFill
            let centerX = Self.holding(
                Double(subject.minX) - halfWidth * air,
                Double(subject.maxX) + halfWidth * air,
                from: Double(middle.x),
                half: halfWidth
            )
            let centerY = Self.holding(
                Double(subject.minY) - halfHeight * air,
                Double(subject.maxY) + halfHeight * air,
                from: Double(middle.y),
                half: halfHeight
            )
            return ScanResult(
                label: label,
                tip: tip,
                centerX: min(max(centerX, halfWidth), 1 - halfWidth),
                centerY: min(max(centerY, halfHeight), 1 - halfHeight),
                size: scale * Double(crop.width),
                subject: subject,
                look: look.flatMap(Look.init(rawValue:))
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

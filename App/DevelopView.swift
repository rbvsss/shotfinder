import SwiftUI

/// The screen after the shot: choose a look, grain and frame, then save.
struct DevelopView: View {
    private enum Panel: String, CaseIterable {
        case look = "Look"
        case grain = "Grain"
        case frame = "Frame"
    }

    let photo: CapturedPhoto
    let ratio: CaptureRatio
    let onSaved: (_ thumbnail: UIImage?, _ rawSaved: Bool) -> Void
    let onDiscard: () -> Void

    @AppStorage("develop.look") private var savedLook = Look.natural.rawValue
    @AppStorage("develop.grain") private var savedGrain = 0.0
    @AppStorage("develop.frame") private var savedFrame = PhotoFrame.none.rawValue

    @State private var developer: PhotoDeveloper?
    @State private var settings = DevelopSettings()
    @State private var preview: UIImage?
    @State private var thumbnails: [Look: UIImage] = [:]
    @State private var panel = Panel.look
    @State private var isSaving = false
    @State private var message: String?
    @State private var confirmingDiscard = false
    @State private var pendingRender: DevelopSettings?
    @State private var isRendering = false
    @State private var hasLoadedSettings = false

    var body: some View {
        VStack(spacing: 12) {
            photoArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Picker("Edit", selection: $panel) {
                ForEach(Panel.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)

            panelContent
                .frame(height: 112)

            actions
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear(perform: loadSettings)
        .task(id: photo.data != nil) { await prepare() }
        .onChange(of: settings) { _, _ in requestRender() }
    }

    @ViewBuilder
    private var photoArea: some View {
        if let preview {
            Image(uiImage: preview)
                .resizable()
                .scaledToFit()
                .overlay {
                    // A black frame would otherwise vanish into the dark screen.
                    if settings.frame == .black {
                        Rectangle().strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    }
                }
        } else if let placeholder = photo.placeholder {
            Color.clear
                .aspectRatio(ratio.widthOverHeight, contentMode: .fit)
                .overlay {
                    Image(uiImage: placeholder)
                        .resizable()
                        .scaledToFill()
                }
                .clipped()
        } else if message == nil {
            ProgressView()
        }
    }

    @ViewBuilder
    private var panelContent: some View {
        switch panel {
        case .look:
            lookPicker
        case .grain:
            grainControl
        case .frame:
            framePicker
        }
    }

    private var lookPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Look.allCases) { look in
                    Button {
                        settings.look = look
                        savedLook = look.rawValue
                    } label: {
                        VStack(spacing: 6) {
                            Group {
                                if let thumbnail = thumbnails[look] {
                                    Image(uiImage: thumbnail)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Theme.control
                                }
                            }
                            .frame(width: 64, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                if settings.look == look {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                }
                            }

                            Text(look.title)
                                .font(.caption)
                                .foregroundStyle(settings.look == look ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(settings.look == look ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var grainControl: some View {
        HStack(spacing: 14) {
            Slider(value: $settings.grain, in: 0...1) { editing in
                if !editing { savedGrain = settings.grain }
            }
            .accessibilityLabel("Grain")

            Text("\(Int((settings.grain * 100).rounded()))")
                .font(.subheadline)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 20)
    }

    private var framePicker: some View {
        HStack(spacing: 10) {
            ForEach(PhotoFrame.allCases) { frame in
                Button {
                    settings.frame = frame
                    savedFrame = frame.rawValue
                } label: {
                    VStack(spacing: 6) {
                        FrameGlyph(frame: frame)
                            .frame(width: 56, height: 70)
                            .overlay {
                                if settings.frame == frame {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                        .padding(-4)
                                }
                            }

                        Text(frame.title)
                            .font(.caption)
                            .foregroundStyle(settings.frame == frame ? .primary : .secondary)
                            .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(settings.frame == frame ? .isSelected : [])
            }
        }
        .padding(.horizontal, 16)
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Discard") {
                confirmingDiscard = true
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .confirmationDialog("Discard this photo?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive, action: onDiscard)
            }

            Button(action: save) {
                Group {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSaving || developer == nil)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .disabled(isSaving)
    }

    private func loadSettings() {
        guard !hasLoadedSettings else { return }
        hasLoadedSettings = true
        settings = DevelopSettings(
            look: Look(rawValue: savedLook) ?? .natural,
            grain: min(max(savedGrain, 0), 1),
            frame: PhotoFrame(rawValue: savedFrame) ?? .none
        )
    }

    private func prepare() async {
        guard let data = photo.data, developer == nil else { return }
        let rawData = photo.rawData
        let ratio = ratio
        let loaded = await Task.detached(priority: .userInitiated) { () -> Result<PhotoDeveloper, Error> in
            Result { try PhotoDeveloper(data: data, rawData: rawData, ratio: ratio) }
        }.value

        switch loaded {
        case .success(let ready):
            developer = ready
            requestRender()
            let rendered = await Task.detached(priority: .utility) { ready.renderThumbnails() }.value
            thumbnails = rendered
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    /// Renders the newest settings as soon as the last render finishes, so sliders always show progress.
    private func requestRender() {
        pendingRender = settings
        guard !isRendering, let developer else { return }
        isRendering = true
        Task {
            while let next = pendingRender {
                pendingRender = nil
                let rendered = await Task.detached(priority: .userInitiated) {
                    developer.renderPreview(next)
                }.value
                if let rendered {
                    preview = rendered
                }
            }
            isRendering = false
        }
    }

    private func save() {
        guard let developer else { return }
        isSaving = true
        message = nil
        let current = settings
        let thumbnail = preview?.preparingThumbnail(of: CGSize(width: 160, height: 200))
        Task {
            do {
                let rawSaved = try await developer.save(current)
                onSaved(thumbnail, rawSaved)
            } catch {
                message = error.localizedDescription
                isSaving = false
            }
        }
    }
}

/// A tiny drawing of what each frame does to a photo.
private struct FrameGlyph: View {
    let frame: PhotoFrame

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background)
                Rectangle()
                    .fill(Color(white: 0.45))
                    .frame(width: width * inset.width, height: height * inset.height)
                    .padding(.top, height * inset.top)
                    .clipShape(RoundedRectangle(cornerRadius: frame == .none ? 6 : 1, style: .continuous))
            }
            .overlay {
                if frame == .black {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                }
            }
        }
    }

    private var background: Color {
        switch frame {
        case .none: return Color(white: 0.45)
        case .black: return .black
        default: return Color(red: 0.96, green: 0.95, blue: 0.92)
        }
    }

    private var inset: (width: CGFloat, height: CGFloat, top: CGFloat) {
        switch frame {
        case .none: return (1, 1, 0)
        case .border: return (0.86, 0.89, 0.055)
        case .mat: return (0.8, 0.72, 0.08)
        case .black: return (0.84, 0.87, 0.065)
        }
    }
}

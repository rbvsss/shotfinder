import SwiftUI

/// The screen after the shot: choose a look, grain and frame, then save.
struct DevelopView: View {
    private enum Panel: String, CaseIterable {
        case look = "LOOK"
        case grain = "GRAIN"
        case frame = "FRAME"
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

    var body: some View {
        VStack(spacing: 0) {
            photoArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 8)

            Text(message ?? " ")
                .font(Theme.text)
                .foregroundStyle(Theme.paper)
                .multilineTextAlignment(.center)
                .frame(minHeight: 28)
                .padding(.horizontal, 16)

            panelTabs
                .padding(.top, 2)

            panelContent
                .frame(height: 112)

            actions
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
        .background(Theme.ink.ignoresSafeArea())
        .task { await prepare() }
        .task(id: settings) { await renderPreview() }
        .confirmationDialog("Discard this photo?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive, action: onDiscard)
        }
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
                        Rectangle().strokeBorder(Theme.paper.opacity(0.2), lineWidth: 1)
                    }
                }
        } else if message == nil {
            ProgressView()
                .tint(Theme.paper)
        }
    }

    private var panelTabs: some View {
        HStack(spacing: 0) {
            ForEach(Panel.allCases, id: \.self) { item in
                Button {
                    withAnimation(Theme.quick) { panel = item }
                } label: {
                    Text(item.rawValue)
                        .font(Theme.label())
                        .foregroundStyle(panel == item ? Theme.paper : Theme.muted)
                        .frame(minHeight: 44)
                        .padding(.horizontal, 14)
                }
            }
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
                                    Theme.raised
                                }
                            }
                            .frame(width: 64, height: 80)
                            .clipped()
                            .overlay {
                                if settings.look == look {
                                    Rectangle().strokeBorder(Theme.signal, lineWidth: 2)
                                }
                            }

                            Text(look.title)
                                .font(Theme.label(11))
                                .foregroundStyle(settings.look == look ? Theme.paper : Theme.muted)
                        }
                    }
                    .accessibilityLabel(look.title)
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
            .tint(Theme.signal)
            .accessibilityLabel("Grain")

            Text("\(Int((settings.grain * 100).rounded()))")
                .font(Theme.label())
                .foregroundStyle(Theme.paper)
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 24)
    }

    private var framePicker: some View {
        HStack(spacing: 10) {
            ForEach(PhotoFrame.allCases) { frame in
                Button {
                    settings.frame = frame
                    savedFrame = frame.rawValue
                } label: {
                    Text(frame.title)
                        .font(Theme.label(12))
                        .foregroundStyle(settings.frame == frame ? Theme.paper : Theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Theme.raised)
                        .overlay {
                            if settings.frame == frame {
                                Rectangle().strokeBorder(Theme.signal, lineWidth: 2)
                            }
                        }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                confirmingDiscard = true
            } label: {
                Text("DISCARD")
                    .font(Theme.label())
                    .foregroundStyle(Theme.paper)
                    .frame(width: 110, height: 52)
                    .background(Theme.raised)
            }
            .buttonStyle(PressStyle())

            Button(action: save) {
                Text(isSaving ? "SAVING" : "SAVE")
                    .font(Theme.label())
                    .foregroundStyle(Theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Theme.paper)
            }
            .buttonStyle(PressStyle())
            .disabled(isSaving || developer == nil)
            .opacity(developer == nil ? 0.35 : 1)
        }
        .disabled(isSaving)
    }

    /// A slim square knob, so the slider matches the app's other controls.
    private func styleSliderKnob() {
        let knob = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 22)).image { context in
            UIColor(Theme.paper).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 22))
        }
        UISlider.appearance().setThumbImage(knob, for: .normal)
        UISlider.appearance().setThumbImage(knob, for: .highlighted)
    }

    private func prepare() async {
        styleSliderKnob()
        settings = DevelopSettings(
            look: Look(rawValue: savedLook) ?? .natural,
            grain: min(max(savedGrain, 0), 1),
            frame: PhotoFrame(rawValue: savedFrame) ?? .none
        )

        let photo = photo
        let ratio = ratio
        let loaded = await Task.detached(priority: .userInitiated) { () -> Result<PhotoDeveloper, Error> in
            Result { try PhotoDeveloper(photo: photo, ratio: ratio) }
        }.value

        switch loaded {
        case .success(let ready):
            developer = ready
            await renderPreview()
            await renderThumbnails(using: ready)
        case .failure(let error):
            message = error.localizedDescription
        }
    }

    private func renderPreview() async {
        // A short wait lets slider drags skip the renders that would be thrown away.
        try? await Task.sleep(nanoseconds: 30_000_000)
        guard !Task.isCancelled, let developer else { return }
        let current = settings
        let rendered = await Task.detached(priority: .userInitiated) {
            developer.renderPreview(current)
        }.value
        guard !Task.isCancelled, current == settings else { return }
        preview = rendered
    }

    private func renderThumbnails(using developer: PhotoDeveloper) async {
        for look in Look.allCases {
            let thumbnail = await Task.detached(priority: .utility) {
                developer.renderThumbnail(look: look)
            }.value
            thumbnails[look] = thumbnail
        }
    }

    private func save() {
        guard let developer else { return }
        isSaving = true
        message = nil
        let current = settings
        Task {
            do {
                let rawSaved = try await developer.save(current)
                onSaved(preview, rawSaved)
            } catch {
                message = error.localizedDescription
                isSaving = false
            }
        }
    }
}

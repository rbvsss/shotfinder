import SwiftUI

/// The screen after the shot: choose a look, grain and frame, then save.
struct DevelopView: View {
    let photo: CapturedPhoto
    let ratio: CaptureRatio
    let onSaved: (_ thumbnail: UIImage?) -> Void
    let onDiscard: () -> Void

    @AppStorage("develop.look") private var savedLook = Look.natural.rawValue
    @AppStorage("develop.grain") private var savedGrain = GrainLevel.off.rawValue
    @AppStorage("develop.frame") private var savedFrame = PhotoFrame.none.rawValue

    @State private var developer: PhotoDeveloper?
    @State private var settings = DevelopSettings()
    @State private var preview: UIImage?
    @State private var original: UIImage?
    @State private var showingOriginal = false
    @State private var quickPreview: UIImage?
    @State private var thumbnails: [Look: UIImage] = [:]
    @State private var isSaving = false
    @State private var message: String?
    @State private var confirmingDiscard = false
    @State private var pendingRender: DevelopSettings?
    @State private var isRendering = false

    var body: some View {
        VStack(spacing: 14) {
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

            lookPicker

            HStack(spacing: 10) {
                optionButton(settings.grain.title) {
                    settings.grain = settings.grain.next
                }
                .accessibilityLabel("Grain, \(settings.grain.title)")

                optionButton(settings.frame.title) {
                    settings.frame = settings.frame.next
                }
                .accessibilityLabel("Frame, \(settings.frame.title)")
            }
            .padding(.horizontal, 16)

            actions
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .background(Color.black.ignoresSafeArea())
        .sensoryFeedback(.selection, trigger: settings) { _, _ in
            developer != nil
        }
        .onAppear(perform: loadSettings)
        .task { await prepareQuickPreview() }
        .task(id: photo.data != nil) { await prepare() }
        .onChange(of: settings) { _, _ in
            requestRender()
        }
    }

    @ViewBuilder
    private var photoArea: some View {
        if let shown = showingOriginal ? (original ?? preview) : preview {
            Image(uiImage: shown)
                .resizable()
                .scaledToFit()
                .overlay(alignment: .top) {
                    if showingOriginal {
                        Text("Original")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(color: Theme.keyline, radius: 1)
                            .padding(.top, 12)
                    }
                }
                // Hold the photo to see it without the look or grain.
                .onLongPressGesture(minimumDuration: .infinity, maximumDistance: 40) {
                } onPressingChanged: { pressing in
                    if pressing {
                        loadOriginal()
                    }
                    showingOriginal = pressing
                }
                .accessibilityAddTraits(.isImage)
                .accessibilityLabel(showingOriginal ? "Original photo" : "Photo with \(settings.look.title) look")
        } else if let quickPreview {
            Image(uiImage: quickPreview)
                .resizable()
                .scaledToFit()
        } else if message == nil {
            ProgressView()
        }
    }

    private var lookPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Look.allCases) { look in
                    Button {
                        settings.look = look
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
                            .frame(width: 60, height: 74)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                if settings.look == look {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(Color.white, lineWidth: 2)
                                }
                            }

                            Text(look.title)
                                .font(.caption)
                                .foregroundStyle(settings.look == look ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(look.title)
                    .accessibilityAddTraits(settings.look == look ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func optionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(Theme.control, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Button("Retake") {
                confirmingDiscard = true
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .confirmationDialog("Discard this photo?", isPresented: $confirmingDiscard) {
                Button("Discard Photo", role: .destructive, action: onDiscard)
            }

            Button(action: save) {
                Group {
                    if isSaving {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Text("Save")
                            .fontWeight(.semibold)
                    }
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .disabled(isSaving || developer == nil)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .disabled(isSaving)
    }

    private func loadSettings() {
        settings = DevelopSettings(
            look: Look(rawValue: savedLook) ?? .natural,
            grain: GrainLevel(rawValue: savedGrain) ?? .off,
            frame: PhotoFrame(rawValue: savedFrame) ?? .none
        )
    }

    /// Shows the viewfinder frame with your look and frame right away, so nothing jumps when the photo lands.
    private func prepareQuickPreview() async {
        guard let placeholder = photo.placeholder, preview == nil else { return }
        let current = settings
        let ratio = ratio
        let rendered = await Task.detached(priority: .userInitiated) {
            PhotoDeveloper.quickPreview(of: placeholder, settings: current, ratio: ratio)
        }.value
        if preview == nil {
            quickPreview = rendered
        }
    }

    private func prepare() async {
        guard let data = photo.data, developer == nil else { return }
        let ratio = ratio
        let loaded = await Task.detached(priority: .userInitiated) { () -> Result<PhotoDeveloper, Error> in
            Result { try PhotoDeveloper(data: data, ratio: ratio) }
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

    /// Renders the newest settings as soon as the last render finishes.
    private func requestRender() {
        pendingRender = settings
        original = nil
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

    private func loadOriginal() {
        guard original == nil, let developer else { return }
        var plain = settings
        plain.look = .natural
        plain.grain = .off
        Task {
            original = await Task.detached(priority: .userInitiated) {
                developer.renderPreview(plain)
            }.value
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
                try await developer.save(current)
                // Only a kept photo sets the starting point for the next one.
                savedLook = current.look.rawValue
                savedGrain = current.grain.rawValue
                savedFrame = current.frame.rawValue
                onSaved(thumbnail)
            } catch {
                message = error.localizedDescription
                isSaving = false
            }
        }
    }
}

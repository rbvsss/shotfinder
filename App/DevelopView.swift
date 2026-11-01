import SwiftUI

/// The screen after the shot: choose a look, grain and frame, then save.
struct DevelopView: View {
    let photo: CapturedPhoto
    let ratio: CaptureRatio
    /// The look Claude picked for the shot this photo was guided to.
    let suggestedLook: Look?
    let onSaved: (_ thumbnail: UIImage?) -> Void
    let onDiscard: () -> Void

    @AppStorage("develop.lastStyle") private var savedStyle = Data()

    @State private var developer: PhotoDeveloper?
    @State private var settings = DevelopSettings()
    @State private var preview: UIImage?
    @State private var original: UIImage?
    @State private var showingOriginal = false
    @State private var quickPreview: UIImage?
    @State private var thumbnails: [Look: UIImage] = [:]
    @State private var isSaving = false
    @State private var message: String?
    @State private var confirmingDelete = false
    @State private var pendingRender: DevelopSettings?
    @State private var isRendering = false

    var body: some View {
        VStack(spacing: 14) {
            photoArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Without a frame, the photo sits exactly where the viewfinder was.
                .padding(.horizontal, settings.frame == .none ? 0 : 16)

            if let message {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            lookPicker

            HStack(spacing: 10) {
                optionButton(settings.grain.title, isOn: settings.grain != .off) {
                    settings.grain = settings.grain.next
                }
                .accessibilityLabel("Grain, \(settings.grain.title)")

                optionButton(settings.frame.title, isOn: settings.frame != .none) {
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
        // The photo comes first, so the controls stop growing before they would crowd it out.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .sensoryFeedback(.selection, trigger: settings) { _, _ in
            developer != nil
        }
        .onAppear(perform: loadStyle)
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
        ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Look.allCases) { look in
                        lookButton(look)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: settings.look) { _, look in
                withAnimation(Theme.quick) { reader.scrollTo(look.id, anchor: .center) }
            }
        }
    }

    private func lookButton(_ look: Look) -> some View {
        let isSelected = settings.look == look
        return Button {
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
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: 2)
                    }
                }

                Text(look.title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(look.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func optionButton(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                confirmingDelete = true
            } label: {
                Text("Delete")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .frame(width: 104, height: 46)
                    .background(Theme.control, in: Capsule())
                    .contentShape(Capsule())
            }
            .confirmationDialog("Delete this photo?", isPresented: $confirmingDelete) {
                Button("Delete Photo", role: .destructive, action: onDiscard)
            }

            Button(action: save) {
                Group {
                    if isSaving {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Text("Save")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(Theme.accent, in: Capsule())
            }
            .disabled(developer == nil)
            .accessibilityLabel("Save")
        }
        .disabled(isSaving)
    }

    private func loadStyle() {
        settings = (try? JSONDecoder().decode(DevelopSettings.self, from: savedStyle)) ?? DevelopSettings()
        if let suggestedLook {
            settings.look = suggestedLook
        }
    }

    /// Shows the viewfinder frame with your style right away, so nothing jumps when the photo lands.
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
            thumbnails = await Task.detached(priority: .utility) { ready.renderThumbnails() }.value
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
        var plain = DevelopSettings()
        plain.frame = settings.frame
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
        let thumbnail = preview.flatMap { shown in
            shown.preparingThumbnail(of: CGSize(width: 160, height: 160 * shown.size.height / shown.size.width))
        }
        Task {
            do {
                try await developer.save(current)
                // Only a kept photo sets the starting point for the next one.
                savedStyle = (try? JSONEncoder().encode(current.style)) ?? savedStyle
                onSaved(thumbnail)
            } catch {
                message = error.localizedDescription
                isSaving = false
            }
        }
    }
}

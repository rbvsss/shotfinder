import SwiftUI

/// The screen after the shot: choose a look, adjust it, add grain or a frame, then save.
struct DevelopView: View {
    let photo: CapturedPhoto
    let ratio: CaptureRatio
    /// The look the scan picked for this shot. It opens with that look on.
    let suggestedLook: Look?
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
    @State private var tab = Panel.looks
    @State private var adjustment = Adjustment.exposure

    private enum Panel: String, CaseIterable {
        case looks, adjust, finish

        var title: String { rawValue.capitalized }
    }

    /// The same height for every tab, so the photo doesn't jump when switching.
    private static let panelHeight: CGFloat = 104

    var body: some View {
        VStack(spacing: 14) {
            photoArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Without a frame, the photo sits exactly where the viewfinder was.
                .padding(.horizontal, settings.frame == .none ? 0 : 16)

            if let message {
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            tabBar

            Group {
                switch tab {
                case .looks: lookPicker
                case .adjust: adjustPanel
                case .finish: finishPanel
                }
            }
            .frame(height: Self.panelHeight)

            actions
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .background(Color.black.ignoresSafeArea())
        // The photo comes first, so the controls stop growing before they would crowd it out.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
                                        .strokeBorder(Theme.accent, lineWidth: 2)
                                }
                            }

                            Text(look.title)
                                .font(.caption)
                                .foregroundStyle(settings.look == look ? Theme.accent : Color.secondary)
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

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(Panel.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(tab == item ? .primary : .secondary)
                        .padding(.horizontal, 18)
                        .frame(height: 34)
                        .background(tab == item ? Theme.control : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.control.opacity(0.5), in: Capsule())
    }

    /// One slider at a time: pick what to change, then drag.
    private var adjustPanel: some View {
        VStack(spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Adjustment.allCases) { item in
                        let isChanged = settings.adjust[keyPath: item.keyPath] != 0
                        Button {
                            adjustment = item
                        } label: {
                            Text(item.title)
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(adjustment == item ? Color.black : isChanged ? Theme.accent : Color.white.opacity(0.7))
                                .padding(.horizontal, 14)
                                .frame(height: 32)
                                .background(adjustment == item ? Theme.accent : Theme.control, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(adjustment == item ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 16)
            }

            HStack(spacing: 12) {
                Slider(value: $settings.adjust[dynamicMember: adjustment.keyPath], in: adjustment.range)
                    .accessibilityLabel(adjustment.title)

                // Tap the number to put it back to zero.
                Button {
                    settings.adjust[keyPath: adjustment.keyPath] = 0
                } label: {
                    Text("\(Int((settings.adjust[keyPath: adjustment.keyPath] * 100).rounded()))")
                        .font(.footnote.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reset \(adjustment.title)")
            }
            .padding(.horizontal, 16)
        }
    }

    private var finishPanel: some View {
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
    }

    private func optionButton(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(isOn ? Theme.accent : Color.white.opacity(0.7))
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Theme.control, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
            .tint(Theme.accent)
            .disabled(developer == nil)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .disabled(isSaving)
    }

    private func loadSettings() {
        settings = DevelopSettings(
            look: suggestedLook ?? Look(rawValue: savedLook) ?? .natural,
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
            thumbnails = await Task.detached(priority: .userInitiated) { ready.renderThumbnails() }.value
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
        plain.adjust = Adjustments()
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

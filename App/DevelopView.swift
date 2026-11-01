import SwiftUI

/// The screen after the shot: look, adjustments, effects and frame, then save.
struct DevelopView: View {
    let photo: CapturedPhoto
    let ratio: CaptureRatio
    let onSaved: (_ thumbnail: UIImage?) -> Void
    let onDiscard: () -> Void

    private enum Tab: String, CaseIterable, Identifiable {
        case looks, adjust, effects, frames
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    /// Room for the tallest tab, so changing tabs never moves the photo.
    private static let panelHeight: CGFloat = 172
    /// How long a change must rest before it becomes a step in the undo history.
    private static let historyDelay: UInt64 = 400_000_000

    @AppStorage("develop.style") private var savedStyle = Data()

    @State private var developer: PhotoDeveloper?
    @State private var settings = DevelopSettings()
    @State private var tab = Tab.looks
    @State private var dial = Dial.exposure
    @State private var effect = Dial.grain
    @State private var showingLookStrength = false
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
    @State private var history: [DevelopSettings] = []
    @State private var historyIndex = 0

    var body: some View {
        VStack(spacing: 12) {
            photoArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 16)

            if let message {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            tabs

            panel
                .frame(height: Self.panelHeight)

            actions
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
        }
        .background(Color.black.ignoresSafeArea())
        // The photo comes first, so the controls stop growing before they would crowd it out.
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .sensoryFeedback(.selection, trigger: settings.look)
        .sensoryFeedback(.selection, trigger: settings.frame)
        .sensoryFeedback(.selection, trigger: tab)
        .onAppear(perform: loadStyle)
        .task { await prepareQuickPreview() }
        .task(id: photo.data != nil) { await prepare() }
        .onChange(of: settings) { _, _ in
            requestRender()
        }
        .task(id: settings) {
            try? await Task.sleep(nanoseconds: Self.historyDelay)
            if !Task.isCancelled {
                recordHistory()
            }
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
                // Hold the photo to see it without the look or any changes.
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

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { option in
                Button {
                    tab = option
                } label: {
                    Text(option.title)
                        .font(.footnote.weight(tab == option ? .semibold : .regular))
                        .foregroundStyle(tab == option ? Color.white : Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 32)
                        .background(tab == option ? Theme.control : .clear, in: Capsule())
                        .overlay(alignment: .topTrailing) {
                            if isChanged(option) {
                                Circle()
                                    .fill(Theme.accent)
                                    .frame(width: 5, height: 5)
                                    .offset(x: -3, y: 3)
                            }
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(tab == option ? .isSelected : [])
            }
        }
    }

    private func isChanged(_ tab: Tab) -> Bool {
        switch tab {
        case .looks: return settings.look != .natural
        case .adjust: return Dial.adjustments.contains { settings[$0] != 0 }
        case .effects: return Dial.effects.contains { settings[$0] != 0 }
        case .frames: return settings.frame != .none || settings.showsDate
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch tab {
        case .looks: looksPanel
        case .adjust: dialPanel(Dial.adjustments, selection: $dial)
        case .effects: dialPanel(Dial.effects, selection: $effect)
        case .frames: framesPanel
        }
    }

    private var looksPanel: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            if showingLookStrength, settings.look != .natural {
                RulerSlider(title: settings.look.title, value: $settings.lookStrength, range: 0...100, resetValue: 100)
                    .padding(.horizontal, 16)
                    .transition(.opacity)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Look.allCases) { look in
                        lookButton(look)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func lookButton(_ look: Look) -> some View {
        let isSelected = settings.look == look
        return Button {
            // A second tap on the chosen look opens its strength.
            if isSelected {
                withAnimation(Theme.quick) { showingLookStrength.toggle() }
            } else {
                settings.look = look
                settings.lookStrength = 100
            }
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
                .frame(width: showingLookStrength ? 52 : 66, height: showingLookStrength ? 58 : 82)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Theme.accent, lineWidth: 2)
                    }
                    if isSelected, look != .natural {
                        Image(systemName: "slider.horizontal.3")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(color: Theme.keyline, radius: 2)
                    }
                }

                Text(look.title.uppercased())
                    .font(.caption2.weight(isSelected ? .semibold : .regular))
                    .tracking(0.4)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(look.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func dialPanel(_ dials: [Dial], selection: Binding<Dial>) -> some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            RulerSlider(title: selection.wrappedValue.title, value: $settings[selection.wrappedValue], range: selection.wrappedValue.range)
                .id(selection.wrappedValue)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(dials) { dial in
                        dialButton(dial, selection: selection)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func dialButton(_ dial: Dial, selection: Binding<Dial>) -> some View {
        let isSelected = selection.wrappedValue == dial
        return Button {
            selection.wrappedValue = dial
        } label: {
            VStack(spacing: 6) {
                Image(systemName: dial.symbol)
                    .font(.subheadline)
                    .foregroundStyle(settings[dial] != 0 ? Theme.accent : Color.white)
                    .frame(width: 40, height: 40)
                    .overlay {
                        Circle().strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1)
                    }
                Text(dial.title)
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
            }
            .frame(width: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(dial.title)
        .accessibilityValue(String(Int(settings[dial])))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var framesPanel: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)

            HStack(spacing: 0) {
                ForEach(PhotoFrame.allCases) { frame in
                    frameButton(frame)
                }
            }
            .padding(.horizontal, 8)

            Toggle("Date stamp", isOn: $settings.showsDate)
                .font(.footnote)
                .fixedSize()
        }
    }

    private func frameButton(_ frame: PhotoFrame) -> some View {
        let isSelected = settings.frame == frame
        return Button {
            settings.frame = frame
        } label: {
            VStack(spacing: 6) {
                FrameTile(frame: frame)
                    .frame(width: 46, height: 52)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(Theme.accent, lineWidth: 2)
                        }
                    }
                Text(frame.title)
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Frame \(frame.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Delete") {
                confirmingDelete = true
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .frame(height: 46)
            .background(Theme.control, in: Capsule())
            .confirmationDialog("Delete this photo?", isPresented: $confirmingDelete) {
                Button("Delete Photo", role: .destructive, action: onDiscard)
            }

            Spacer(minLength: 0)

            historyButton(symbol: "arrow.uturn.backward", label: "Undo", isEnabled: canUndo, action: undo)
            historyButton(symbol: "arrow.uturn.forward", label: "Redo", isEnabled: canRedo, action: redo)

            Spacer(minLength: 0)

            Button(action: save) {
                HStack(spacing: 6) {
                    if isSaving {
                        ProgressView()
                            .tint(.black)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.bold))
                        Text("Save")
                            .font(.subheadline.weight(.semibold))
                    }
                }
                .foregroundStyle(.black)
                .frame(width: 112, height: 46)
                .background(Theme.accent, in: Capsule())
            }
            .disabled(developer == nil)
            .accessibilityLabel("Save")
        }
        .disabled(isSaving)
    }

    private func historyButton(symbol: String, label: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline)
                .foregroundStyle(isEnabled ? Color.white : Color.secondary.opacity(0.5))
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }

    private var canUndo: Bool {
        historyIndex > 0 || (history.first.map { $0 != settings } ?? false)
    }

    private var canRedo: Bool {
        historyIndex < history.count - 1
    }

    private func recordHistory() {
        guard history.indices.contains(historyIndex), history[historyIndex] != settings else { return }
        history.removeSubrange((historyIndex + 1)...)
        history.append(settings)
        historyIndex = history.count - 1
    }

    private func undo() {
        recordHistory()
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        settings = history[historyIndex]
    }

    private func redo() {
        guard canRedo else { return }
        historyIndex += 1
        settings = history[historyIndex]
    }

    private func loadStyle() {
        settings = (try? JSONDecoder().decode(DevelopSettings.self, from: savedStyle)) ?? DevelopSettings()
        history = [settings]
        historyIndex = 0
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
        let thumbnail = preview?.preparingThumbnail(of: CGSize(width: 160, height: 200))
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

/// A miniature of a frame: its paper with a grey photo set at the frame's margins.
private struct FrameTile: View {
    let frame: PhotoFrame

    var body: some View {
        GeometryReader { geometry in
            let short = min(geometry.size.width, geometry.size.height)
            // Doubled, since at this size the real margins would barely show.
            let side = frame.margins.side * short * 2
            let top = frame.margins.top * short * 2
            let bottom = frame.margins.bottom * short * 2

            ZStack {
                Color(red: frame.paper.red, green: frame.paper.green, blue: frame.paper.blue)
                Color(white: 0.34)
                    .padding(.horizontal, side)
                    .padding(.top, top)
                    .padding(.bottom, bottom)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }
}

/// A row of ticks you drag across to set a value, with the value above it. Double tap to reset.
private struct RulerSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var resetValue = 0.0

    @State private var dragStart: Double?

    private static let tickCount = 41

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .foregroundStyle(.secondary)
                Text(String(Int(value)))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .font(.footnote)

            GeometryReader { geometry in
                ticks(width: geometry.size.width)
                    .contentShape(Rectangle())
                    .gesture(drag(width: geometry.size.width))
                    .onTapGesture(count: 2) {
                        value = resetValue
                    }
            }
            .frame(height: 28)
        }
        .sensoryFeedback(.selection, trigger: Int(value / 10))
        .accessibilityRepresentation {
            Slider(value: $value, in: range, step: 1) {
                Text(title)
            }
        }
    }

    private func ticks(width: CGFloat) -> some View {
        let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return Canvas { context, size in
            for index in 0..<Self.tickCount {
                let x = size.width * CGFloat(index) / CGFloat(Self.tickCount - 1)
                let isMajor = index % 5 == 0
                let height: CGFloat = isMajor ? 14 : 8
                let tick = CGRect(x: x - 0.5, y: (size.height - height) / 2, width: 1, height: height)
                context.fill(Path(tick), with: .color(Color.white.opacity(isMajor ? 0.55 : 0.3)))
            }
            let marker = CGRect(x: size.width * fraction - 1.5, y: 0, width: 3, height: size.height)
            context.fill(Path(roundedRect: marker, cornerRadius: 1.5), with: .color(Theme.accent))
        }
    }

    /// Moves by how far the finger travels, so touching the ruler never makes the value jump.
    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                let start = dragStart ?? value
                dragStart = start
                let span = range.upperBound - range.lowerBound
                let moved = start + Double(gesture.translation.width / max(width, 1)) * span
                value = min(max(moved.rounded(), range.lowerBound), range.upperBound)
            }
            .onEnded { _ in
                dragStart = nil
            }
    }
}

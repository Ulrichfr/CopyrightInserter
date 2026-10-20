import AppKit
import SwiftUI
import UniformTypeIdentifiers

private let inkTint = Color(red: 0.86, green: 0.72, blue: 0.46)

@main
struct CopyrightInserterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(inkTint)
        }
        .defaultSize(width: 1120, height: 760)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
final class Studio: ObservableObject {
    @Published var usesText = false
    @Published var markText = "© "
    @Published var ink: MarkInk = .white
    @Published var markURL: URL?
    @Published var sourceURL: URL?
    @Published var destinationURL: URL?
    @Published var placement: Placement = .preset(.bottomTrailing)
    @Published var opacity = 0.92
    @Published var scale = 0.28
    @Published var margin = 0.04
    @Published var jpegQuality = 0.9
    @Published var shadow = true
    @Published var keepLocation = false
    @Published var fit: FitAxis = .original
    @Published var fitPixels = 1200
    @Published var outputCaption = ""
    @Published var markedPreview: NSImage?
    @Published var plainPreview: NSImage?
    @Published var comparing = false
    @Published var photoIndex = 0
    @Published var status = "Une marque, un dossier, et les originaux restent en place."
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var progressVisible = false
    @Published var revealURL: URL?

    private var cachedMark: CGImage?
    private var cachedMarkKey: String?
    private var cachedPhoto: CGImage?
    private var cachedPhotoURL: URL?
    private let defaults = UserDefaults.standard

    init() {
        usesText = defaults.bool(forKey: "usesText")
        if let stored = defaults.string(forKey: "markText"), !stored.isEmpty { markText = stored }
        if let raw = defaults.string(forKey: "ink"), let value = MarkInk(rawValue: raw) { ink = value }
        if let raw = defaults.string(forKey: "anchor"), let anchor = Anchor(rawValue: raw) {
            placement = .preset(anchor)
        }
        opacity = stored(defaults, "opacity", opacity)
        scale = stored(defaults, "scale", scale)
        margin = stored(defaults, "margin", margin)
        jpegQuality = stored(defaults, "jpegQuality", jpegQuality)
        if defaults.object(forKey: "shadow") != nil { shadow = defaults.bool(forKey: "shadow") }
        keepLocation = defaults.bool(forKey: "keepLocation")
        if let raw = defaults.string(forKey: "fit"), let value = FitAxis(rawValue: raw) { fit = value }
        if defaults.object(forKey: "fitPixels") != nil {
            fitPixels = min(8_000, max(32, defaults.integer(forKey: "fitPixels")))
        }
    }

    var files: [URL] {
        guard let sourceURL else { return [] }
        return Compositor.sourceFiles(in: sourceURL)
    }

    var options: CompositeOptions {
        CompositeOptions(
            placement: placement,
            opacity: opacity,
            scale: scale,
            margin: margin,
            jpegQuality: jpegQuality,
            shadow: shadow,
            keepLocation: keepLocation,
            fit: fit,
            fitPixels: fitPixels
        )
    }

    var canApply: Bool {
        guard sourceURL != nil, !isRunning else { return false }
        if usesText { return !markText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return markURL != nil
    }

    func refreshPreview() {
        guard let sourceURL else {
            markedPreview = nil
            plainPreview = nil
            return
        }
        let files = Compositor.sourceFiles(in: sourceURL)
        guard !files.isEmpty else {
            markedPreview = nil
            plainPreview = nil
            cachedPhoto = nil
            cachedPhotoURL = nil
            status = "Ce dossier ne contient pas d'image reconnue."
            return
        }
        if photoIndex >= files.count { photoIndex = 0 }
        let current = files[photoIndex]
        do {
            let mark = try currentMark()
            if cachedPhotoURL != current {
                cachedPhoto = try Compositor.loadImage(at: current)
                cachedPhotoURL = current
            }
            guard let cachedPhoto, let pair = Compositor.previewPair(photo: cachedPhoto, mark: mark, options: options, maxSide: 1600) else {
                markedPreview = nil
                plainPreview = nil
                return
            }
            plainPreview = nsImage(pair.plain)
            markedPreview = nsImage(pair.marked)
            outputCaption = Self.caption(for: cachedPhoto, options: options)
            if !isRunning {
                status = "\(files.count) \(files.count > 1 ? "images" : "image") · \(current.lastPathComponent)"
            }
        } catch {
            markedPreview = nil
            plainPreview = nil
            status = error.localizedDescription
        }
    }

    func step(_ delta: Int) {
        let count = files.count
        guard count > 0 else { return }
        photoIndex = (photoIndex + delta + count) % count
        refreshPreview()
    }

    func apply() {
        guard let sourceURL, canApply else { return }
        let files = Compositor.sourceFiles(in: sourceURL).filter { destinationURL != nil || !$0.lastPathComponent.hasPrefix("c_") }
        guard !files.isEmpty else {
            status = "Rien à traiter dans ce dossier."
            return
        }
        let job = Job(
            mark: currentMarkValue(),
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            options: options,
            total: files.count
        )
        isRunning = true
        progressVisible = true
        progress = 0
        revealURL = nil
        status = "Composition…"
        Task.detached {
            let report: BatchReport
            do {
                report = try Compositor.runBatch(
                    mark: job.mark,
                    sourceFolder: job.sourceURL,
                    destination: job.destinationURL,
                    options: job.options
                ) { done, total in
                    Task { @MainActor in
                        self.progress = Double(done) / Double(max(total, 1))
                        self.status = "\(done) sur \(total)"
                    }
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    self.progress = 0
                    self.status = error.localizedDescription
                }
                return
            }
            await MainActor.run {
                self.isRunning = false
                self.progress = 1
                self.revealURL = report.outputFolder
                self.status = Self.summary(report)
            }
        }
    }

    func reveal() {
        guard let revealURL else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: revealURL.path)
    }

    func persist() {
        defaults.set(usesText, forKey: "usesText")
        defaults.set(markText, forKey: "markText")
        defaults.set(ink.rawValue, forKey: "ink")
        if case .preset(let anchor) = placement {
            defaults.set(anchor.rawValue, forKey: "anchor")
        }
        defaults.set(opacity, forKey: "opacity")
        defaults.set(scale, forKey: "scale")
        defaults.set(margin, forKey: "margin")
        defaults.set(jpegQuality, forKey: "jpegQuality")
        defaults.set(shadow, forKey: "shadow")
        defaults.set(keepLocation, forKey: "keepLocation")
        defaults.set(fit.rawValue, forKey: "fit")
        defaults.set(fitPixels, forKey: "fitPixels")
    }

    static func caption(for photo: CGImage, options: CompositeOptions) -> String {
        let size = Compositor.fittedSize(width: photo.width, height: photo.height, options: options)
        let label = "\(px(size.0)) × \(px(size.1))"
        if options.fit == .original { return "Taille d'origine · \(label)" }
        return "\(label) px"
    }

    static func px(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "fr_FR")
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func currentMark() throws -> CGImage {
        let key = markKey
        if cachedMarkKey == key, let cachedMark { return cachedMark }
        let image = try Compositor.loadMark(currentMarkValue())
        cachedMark = image
        cachedMarkKey = key
        return image
    }

    private var markKey: String {
        if usesText { return "text:\(ink.rawValue):\(markText)" }
        return "file:\(markURL?.path ?? "")"
    }

    private func currentMarkValue() -> Mark {
        if usesText { return .text(markText, ink) }
        return .file(markURL ?? URL(fileURLWithPath: "/"))
    }

    private func nsImage(_ image: CGImage) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func stored(_ defaults: UserDefaults, _ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) == nil ? fallback : defaults.double(forKey: key)
    }

    private static func summary(_ report: BatchReport) -> String {
        let written = report.written
        let skipped = report.skipped.count
        var text = written > 1 ? "\(written) images enregistrées." : "\(written) image enregistrée."
        if skipped == 1 {
            text += " 1 ignorée."
        } else if skipped > 1 {
            text += " \(skipped) ignorées."
        }
        return text
    }
}

private struct Job: Sendable {
    var mark: Mark
    var sourceURL: URL
    var destinationURL: URL?
    var options: CompositeOptions
    var total: Int
}

struct ContentView: View {
    @StateObject private var studio = Studio()

    var body: some View {
        HStack(spacing: 0) {
            controls
                .frame(width: 392)
            stage
        }
        .preferredColorScheme(.dark)
        .background(Color.black)
        .frame(minWidth: 1040, minHeight: 720)
        .onAppear { studio.refreshPreview() }
        .onChange(of: studio.markURL) { _, _ in studio.refreshPreview() }
        .onChange(of: studio.sourceURL) { _, _ in
            studio.photoIndex = 0
            studio.refreshPreview()
        }
        .onChange(of: studio.usesText) { _, _ in studio.refreshPreview() }
        .onChange(of: studio.markText) { _, _ in studio.refreshPreview() }
        .onChange(of: studio.ink) { _, _ in studio.refreshPreview() }
        .onChange(of: studio.placement) { _, _ in studio.refreshPreview() }
        .onChange(of: studio.opacity) { _, _ in studio.refreshPreview() }
        .onChange(of: studio.scale) { _, _ in studio.refreshPreview() }
        .onChange(of: studio.margin) { _, _ in studio.refreshPreview() }
        .onChange(of: studio.shadow) { _, _ in studio.refreshPreview() }
        .onChange(of: studio.fit) { _, _ in studio.refreshPreview() }
        .onChange(of: studio.fitPixels) { _, _ in studio.refreshPreview() }
        .onChange(of: previewToken) { _, _ in studio.persist() }
    }

    private var previewToken: String {
        "\(studio.usesText)\(studio.markText)\(studio.ink.rawValue)\(studio.opacity)\(studio.scale)\(studio.margin)\(studio.jpegQuality)\(studio.shadow)\(studio.keepLocation)\(studio.fit.rawValue)\(studio.fitPixels)"
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 14) {
                        Image(systemName: "seal.fill")
                            .font(.title3)
                            .foregroundStyle(inkTint)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(inkTint.opacity(0.16)))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Copyright Inserter")
                                .font(.system(size: 22, weight: .semibold, design: .serif))
                            Text("Signature visuelle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("seal", "Marque")
                        HStack(spacing: 8) {
                            modeButton("Image", "photo", selected: !studio.usesText) { studio.usesText = false }
                            modeButton("Texte", "textformat", selected: studio.usesText) { studio.usesText = true }
                        }

                        if studio.usesText {
                            textMark
                        } else {
                            DropWell(
                                title: studio.markURL?.lastPathComponent ?? "Graphisme",
                                detail: studio.markURL == nil ? "Glisse un fichier, ou clique" : "Remplacer",
                                systemImage: "seal",
                                filled: studio.markURL != nil
                            ) {
                                if let url = choose(image: true) { studio.markURL = url }
                            } onDropURL: { url in
                                guard !url.hasDirectoryPath else { return }
                                studio.markURL = url
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("folder", "Dossiers")
                        DropWell(
                            title: studio.sourceURL?.lastPathComponent ?? "Photos",
                            detail: studio.sourceURL == nil ? "Dossier à signer" : "\(studio.files.count) images",
                            systemImage: "photo.stack",
                            filled: studio.sourceURL != nil
                        ) {
                            if let url = choose(image: false) { studio.sourceURL = url }
                        } onDropURL: { url in
                            guard directory(url) else { return }
                            studio.sourceURL = url
                        }
                        DropWell(
                            title: studio.destinationURL?.lastPathComponent ?? "À côté des originaux",
                            detail: studio.destinationURL == nil ? "Les copies prennent le préfixe c_" : "Dossier de destination",
                            systemImage: "square.and.arrow.down",
                            filled: studio.destinationURL != nil
                        ) {
                            if let url = choose(image: false) { studio.destinationURL = url }
                        } onDropURL: { url in
                            guard directory(url) else { return }
                            studio.destinationURL = url
                        }
                        if studio.destinationURL != nil {
                            Button("Revenir aux copies c_") { studio.destinationURL = nil }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("aspectratio", "Format")
                        HStack(spacing: 8) {
                            formatButton("Original", "photo", .original)
                            formatButton("Largeur", "arrow.left.and.right", .width)
                            formatButton("Hauteur", "arrow.up.and.down", .height)
                        }
                        if studio.fit != .original {
                            HStack(spacing: 8) {
                                TextField("1200", value: $studio.fitPixels, format: IntegerFormatStyle<Int>.number.grouping(.never))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 84)
                                Text("px")
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: 4)
                                ForEach([800, 1200, 1600, 1920], id: \.self) { value in
                                    Button("\(value)") { studio.fitPixels = value }
                                        .buttonStyle(.plain)
                                        .font(.caption.weight(studio.fitPixels == value ? .semibold : .regular))
                                        .foregroundStyle(studio.fitPixels == value ? inkTint : .secondary)
                                }
                            }
                        }
                        Text(formatHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("square.grid.3x3", "Position")
                        PositionPad(placement: $studio.placement)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        sectionTitle("slider.horizontal.3", "Réglages")
                        slider("circle.lefthalf.filled", "Opacité", $studio.opacity, 0.15...1)
                        slider("arrow.up.left.and.arrow.down.right", "Taille", $studio.scale, 0.08...0.7)
                        slider("square.dashed", "Marge", $studio.margin, 0...0.16)
                        slider("sparkle", "Qualité JPEG", $studio.jpegQuality, 0.5...1)
                        iconToggle("shadow", "Ombre portée", $studio.shadow)
                        iconToggle(studio.keepLocation ? "location.fill" : "location.slash", "Conserver le GPS", $studio.keepLocation)
                        Text(studio.keepLocation ? "Les coordonnées restent dans les copies." : "Les coordonnées sont retirées des copies. Utile avant une publication.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(28)
            }

            Divider()
            VStack(alignment: .leading, spacing: 12) {
                Button(action: studio.apply) {
                    Label(studio.isRunning ? "Signature…" : "Poser la marque", systemImage: studio.isRunning ? "hourglass" : "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!studio.canApply)
                .keyboardShortcut(.return, modifiers: .command)

                if studio.progressVisible {
                    ProgressView(value: studio.progress)
                        .progressViewStyle(.linear)
                }

                HStack(alignment: .firstTextBaseline) {
                    Text(studio.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if studio.revealURL != nil, !studio.isRunning {
                        Button(action: studio.reveal) {
                            Label("Révéler", systemImage: "folder")
                        }
                        .buttonStyle(.link)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.1))
    }

    private var textMark: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("© Ton nom", text: $studio.markText)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular, design: .serif))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.2)))
            HStack(spacing: 8) {
                ForEach(MarkInk.allCases) { ink in
                    Button {
                        studio.ink = ink
                    } label: {
                        Text(ink.title)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(studio.ink == ink ? inkTint.opacity(0.18) : Color.secondary.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var formatHint: String {
        switch studio.fit {
        case .original:
            return "Chaque photo garde ses pixels. Le logo est une proportion de sa largeur."
        case .width:
            return "Tu fixes la largeur. La hauteur suit le ratio, puis le logo se pose sur cette taille."
        case .height:
            return "Tu fixes la hauteur. La largeur suit le ratio, puis le logo se pose sur cette taille."
        }
    }

    private var stage: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.07, green: 0.07, blue: 0.08), Color(red: 0.13, green: 0.12, blue: 0.11)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [inkTint.opacity(0.14), .clear],
                    center: .center,
                    startRadius: 10,
                    endRadius: 460
                )
                if let image = studio.comparing ? studio.plainPreview : studio.markedPreview {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: .black.opacity(0.16), radius: 28, y: 16)
                        .padding(.horizontal, 48)
                        .padding(.top, 36)
                        .padding(.bottom, 92)
                        .overlay(alignment: .top) {
                            if !studio.outputCaption.isEmpty {
                                Text(studio.outputCaption)
                                    .font(.caption.monospacedDigit().weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(.top, 48)
                            }
                        }
                } else {
                    VStack(spacing: 16) {
                        HStack(spacing: 18) {
                            emptyIcon("photo.stack")
                            emptyIcon("seal")
                            emptyIcon("textformat")
                        }
                        Text("L'aperçu se pose ici")
                            .font(.system(.title3, design: .serif))
                        Text("Glisse un dossier de photos, puis une marque ou une ligne de texte.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 320)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(in: geo.size))
            .overlay(alignment: .bottom) { stageBar }
        }
    }

    private var stageBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                stageButton("chevron.left") { studio.step(-1) }
                Text(counter)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 72)
                stageButton("chevron.right") { studio.step(1) }
            }
            Spacer()
            Label(studio.comparing ? "Original" : "Marqué", systemImage: studio.comparing ? "photo" : "seal")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Label("Comparer", systemImage: "eye")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in studio.comparing = true }
                        .onEnded { _ in studio.comparing = false }
                )
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(22)
    }

    private var counter: String {
        let count = studio.files.count
        guard count > 0 else { return "—" }
        return "\(studio.photoIndex + 1) / \(count)"
    }

    private func stageButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .disabled(studio.files.count < 2)
    }

    private func dragGesture(in viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard let image = studio.markedPreview, !studio.comparing else { return }
                let canvas = CGSize(width: max(1, viewSize.width - 96), height: max(1, viewSize.height - 128))
                let fitted = fittedRect(imageSize: image.size, in: canvas)
                guard fitted.width > 1 else { return }
                let x = (value.location.x - 48 - fitted.minX) / fitted.width
                let y = (value.location.y - 36 - fitted.minY) / fitted.height
                studio.placement = .manual(x: min(0.98, max(0, x)), y: min(0.98, max(0, y)))
            }
    }

    private func fittedRect(imageSize: CGSize, in viewSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: (viewSize.width - width) / 2, y: (viewSize.height - height) / 2, width: width, height: height)
    }

    private func sectionTitle(_ symbol: String, _ title: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
    }

    private func modeButton(_ title: String, _ symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.body)
                Text(title)
                    .font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(selected ? inkTint : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? inkTint.opacity(0.14) : Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? inkTint.opacity(0.7) : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func formatButton(_ title: String, _ symbol: String, _ axis: FitAxis) -> some View {
        let selected = studio.fit == axis
        return Button { studio.fit = axis } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(selected ? inkTint : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? inkTint.opacity(0.14) : Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }

    private func iconToggle(_ symbol: String, _ title: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Label(title, systemImage: symbol)
        }
        .toggleStyle(.switch)
    }

    private func emptyIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.title3)
            .foregroundStyle(inkTint)
            .frame(width: 52, height: 52)
            .background(Circle().fill(Color.white.opacity(0.05)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.08)))
    }

    private func slider(_ symbol: String, _ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded())) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            Slider(value: value, in: range)
        }
    }

    private func choose(image: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = image
        panel.canChooseDirectories = !image
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir"
        if image { panel.allowedContentTypes = [.image] }
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func directory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

private struct DropWell: View {
    var title: String
    var detail: String
    var systemImage: String
    var filled: Bool
    var choose: () -> Void
    var onDropURL: (URL) -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.body)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(filled ? inkTint.opacity(0.16) : Color.secondary.opacity(0.1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(targeted ? inkTint.opacity(0.1) : Color(nsColor: .textBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(targeted ? inkTint : Color.secondary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: filled ? [] : [4, 4]))
            )
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { onDropURL(url) }
            }
            return true
        }
    }
}

private struct PositionPad: View {
    @Binding var placement: Placement

    private let anchors: [Anchor] = [
        .topLeading, .top, .topTrailing,
        .leading, .center, .trailing,
        .bottomLeading, .bottom, .bottomTrailing
    ]

    var body: some View {
        HStack(spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 6), count: 3), spacing: 6) {
                ForEach(anchors) { anchor in
                    Button { placement = .preset(anchor) } label: {
                        Image(systemName: symbol(anchor))
                            .font(.caption.weight(.semibold))
                            .frame(width: 36, height: 32)
                            .foregroundStyle(isSelected(anchor) ? Color.black : .secondary)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected(anchor) ? inkTint : Color.white.opacity(0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(anchor.title)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.04)))
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var label: String {
        switch placement {
        case .preset(let anchor): return anchor.title
        case .manual: return "Placement libre"
        }
    }

    private func isSelected(_ anchor: Anchor) -> Bool {
        if case .preset(let current) = placement { return current == anchor }
        return false
    }

    private func symbol(_ anchor: Anchor) -> String {
        switch anchor {
        case .topLeading: return "arrow.up.left"
        case .top: return "arrow.up"
        case .topTrailing: return "arrow.up.right"
        case .leading: return "arrow.left"
        case .center: return "scope"
        case .trailing: return "arrow.right"
        case .bottomLeading: return "arrow.down.left"
        case .bottom: return "arrow.down"
        case .bottomTrailing: return "arrow.down.right"
        }
    }
}

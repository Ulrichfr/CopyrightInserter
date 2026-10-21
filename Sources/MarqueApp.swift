import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct CopyrightInserterApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 740)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
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
    @State private var showInspector = true
    @State private var dropTargeted = false

    var body: some View {
        NavigationStack {
            stage
                .navigationTitle(navigationTitle)
                .navigationSubtitle(navigationSubtitle)
                .toolbar { toolbar }
                .inspector(isPresented: $showInspector) {
                    inspector
                        .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
                }
        }
        .frame(minWidth: 980, minHeight: 640)
        .onAppear { studio.refreshPreview() }
        .onChange(of: studio.markURL) { _, _ in studio.refreshPreview() }
        .onChange(of: studio.sourceURL) { _, _ in
            studio.photoIndex = 0
            studio.refreshPreview()
        }
        .onChange(of: studio.usesText) { _, _ in studio.refreshPreview() }
        .onChange(of: studio.markText) { _, _ in studio.refreshPreview() }
        .onChange(of: studio.ink) { _, _ in studio.refreshPreview() }
        .onChange(of: studio.placement) { _, _ in
            studio.refreshPreview()
            studio.persist()
        }
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

    private var hasPreview: Bool {
        studio.markedPreview != nil || studio.plainPreview != nil
    }

    private var navigationTitle: String {
        let files = studio.files
        guard !files.isEmpty else { return "Copyright Inserter" }
        let index = min(studio.photoIndex, files.count - 1)
        return files[index].deletingPathExtension().lastPathComponent
    }

    private var navigationSubtitle: String {
        if studio.comparing { return "Original" }
        if !studio.outputCaption.isEmpty { return studio.outputCaption }
        return "Signature visuelle"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if studio.revealURL != nil, !studio.isRunning {
            ToolbarItem(placement: .secondaryAction) {
                Button(action: studio.reveal) {
                    Label("Révéler", systemImage: "folder")
                }
                .help("Afficher les copies dans le Finder")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button(action: studio.apply) {
                Label(studio.isRunning ? "Signature…" : "Poser la marque", systemImage: "checkmark.seal")
                    .symbolEffect(.pulse, isActive: studio.isRunning)
            }
            .buttonStyle(.glassProminent)
            .disabled(!studio.canApply)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Pose la marque sur chaque image du dossier")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspecteur", systemImage: "sidebar.trailing")
            }
            .keyboardShortcut("i", modifiers: .command)
            .help("Afficher l’inspecteur")
        }
    }

    @ViewBuilder
    private var stage: some View {
        if hasPreview {
            canvas.safeAreaBar(edge: .bottom) { transport }
        } else {
            canvas
        }
    }

    private var canvas: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
                .ignoresSafeArea()
            if let image = studio.comparing ? studio.plainPreview : studio.markedPreview {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.16), radius: 22, y: 10)
                    .overlay {
                        GeometryReader { geo in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(dragGesture(in: geo.size))
                        }
                    }
                    .padding(40)
            } else {
                placeholder
            }
            if dropTargeted {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2.5)
                    .padding(16)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { acceptDrop(url) }
            }
            return true
        }
    }

    private var placeholder: some View {
        Group {
            if studio.sourceURL == nil {
                ContentUnavailableView {
                    Label("Aucune photo", systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text("Glisse un dossier de photos ici, puis une marque ou une ligne de texte.")
                } actions: {
                    Button("Choisir un dossier") {
                        if let url = choose(image: false) { studio.sourceURL = url }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            } else if studio.files.isEmpty {
                ContentUnavailableView(
                    "Aucune image",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("Ce dossier ne contient pas d’image reconnue.")
                )
            } else {
                ContentUnavailableView(
                    "Aperçu indisponible",
                    systemImage: "seal",
                    description: Text(studio.status)
                )
            }
        }
    }

    private var transport: some View {
        HStack(spacing: 14) {
            Button { studio.step(-1) } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .disabled(studio.files.count < 2)
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .help("Photo précédente")

            Text(counter)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 72)

            Button { studio.step(1) } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            .disabled(studio.files.count < 2)
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .help("Photo suivante")

            Spacer(minLength: 12)

            if studio.isRunning {
                ProgressView(value: studio.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 140)
                Text(studio.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Label(studio.comparing ? "Original" : "Comparer", systemImage: studio.comparing ? "photo" : "eye")
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .foregroundStyle(studio.comparing ? .white : .primary)
                .background(studio.comparing ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary), in: Capsule())
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in studio.comparing = true }
                        .onEnded { _ in studio.comparing = false }
                )
                .help("Maintenir pour voir l’original")
                .opacity(studio.plainPreview == nil ? 0.4 : 1)
                .allowsHitTesting(studio.plainPreview != nil)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private var inspector: some View {
        Form {
            Section {
                Picker("Marque", selection: $studio.usesText) {
                    Text("Image").tag(false)
                    Text("Texte").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if studio.usesText {
                    TextField("Texte", text: $studio.markText, prompt: Text("© Ton nom"))
                    Picker("Encre", selection: $studio.ink) {
                        ForEach(MarkInk.allCases) { ink in
                            Text(ink.title).tag(ink)
                        }
                    }
                    .pickerStyle(.segmented)
                } else {
                    fileRow(
                        title: "Fichier",
                        symbol: "seal",
                        value: studio.markURL?.lastPathComponent ?? "Choisir…",
                        directories: false
                    ) {
                        if let url = choose(image: true) { studio.markURL = url }
                    } onDrop: { url in
                        guard !directory(url) else { return }
                        studio.usesText = false
                        studio.markURL = url
                    }
                }
            } header: {
                Text("Marque")
            } footer: {
                Text(studio.usesText
                    ? "Une ligne, composée sur la photo."
                    : "PNG avec transparence, de préférence. Tu peux aussi déposer le fichier.")
            }

            Section {
                fileRow(
                    title: "Photos",
                    symbol: "photo.stack",
                    value: studio.sourceURL?.lastPathComponent ?? "Choisir…",
                    directories: true
                ) {
                    if let url = choose(image: false) { studio.sourceURL = url }
                } onDrop: { url in
                    guard directory(url) else { return }
                    studio.sourceURL = url
                }
                fileRow(
                    title: "Destination",
                    symbol: "folder",
                    value: studio.destinationURL?.lastPathComponent ?? "À côté des originaux",
                    directories: true
                ) {
                    if let url = choose(image: false) { studio.destinationURL = url }
                } onDrop: { url in
                    guard directory(url) else { return }
                    studio.destinationURL = url
                }
                if studio.destinationURL != nil {
                    Button("Revenir aux copies c_") { studio.destinationURL = nil }
                }
            } header: {
                Text("Dossiers")
            } footer: {
                Text(studio.destinationURL == nil
                    ? "Sans dossier de destination, les copies prennent le préfixe c_."
                    : "Les fichiers gardent leur nom dans ce dossier. Les originaux ne sont pas modifiés.")
            }

            Section {
                Picker("Format", selection: $studio.fit) {
                    Text("Original").tag(FitAxis.original)
                    Text("Largeur").tag(FitAxis.width)
                    Text("Hauteur").tag(FitAxis.height)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if studio.fit != .original {
                    LabeledContent(studio.fit == .width ? "Largeur" : "Hauteur") {
                        HStack(spacing: 6) {
                            TextField(
                                "1200",
                                value: $studio.fitPixels,
                                format: IntegerFormatStyle<Int>.number.grouping(.never)
                            )
                            .multilineTextAlignment(.trailing)
                            .frame(width: 72)
                            Text("px")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Picker("Préréglage", selection: $studio.fitPixels) {
                        Text("800").tag(800)
                        Text("1200").tag(1200)
                        Text("1600").tag(1600)
                        Text("1920").tag(1920)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            } header: {
                Text("Format")
            } footer: {
                Text(formatHint)
            }

            Section {
                PositionPad(placement: $studio.placement)
            } header: {
                Text("Position")
            } footer: {
                Text("Neuf positions, ou un glisser sur l’aperçu.")
            }

            Section {
                percentSlider("Opacité", $studio.opacity, 0.15...1)
                percentSlider("Taille", $studio.scale, 0.08...0.7)
                percentSlider("Marge", $studio.margin, 0...0.16)
                percentSlider("Qualité JPEG", $studio.jpegQuality, 0.5...1)
                Toggle("Ombre portée", isOn: $studio.shadow)
                Toggle("Conserver le GPS", isOn: $studio.keepLocation)
            } header: {
                Text("Réglages")
            } footer: {
                Text(studio.keepLocation
                    ? "Les coordonnées restent dans les copies."
                    : "Les coordonnées sont retirées des copies. Utile avant une publication.")
            }

            Section {
                if studio.progressVisible {
                    ProgressView(value: studio.progress)
                }
                Text(studio.status)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    private var counter: String {
        let count = studio.files.count
        guard count > 0 else { return "—" }
        return "\(studio.photoIndex + 1) / \(count)"
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

    private func fileRow(
        title: String,
        symbol: String,
        value: String,
        directories: Bool,
        choose: @escaping () -> Void,
        onDrop: @escaping (URL) -> Void
    ) -> some View {
        Button(action: choose) {
            LabeledContent {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } label: {
                Label(title, systemImage: symbol)
            }
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async {
                    let isDirectory = directory(url)
                    guard isDirectory == directories else { return }
                    onDrop(url)
                }
            }
            return true
        }
    }

    private func percentSlider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title) {
                Text("\(Int((value.wrappedValue * 100).rounded())) %")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
        .padding(.vertical, 2)
    }

    private func dragGesture(in viewSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard let image = studio.markedPreview, !studio.comparing else { return }
                let fitted = fittedRect(imageSize: image.size, in: viewSize)
                guard fitted.width > 1, fitted.height > 1 else { return }
                let x = (value.location.x - fitted.minX) / fitted.width
                let y = (value.location.y - fitted.minY) / fitted.height
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

    private func acceptDrop(_ url: URL) {
        if directory(url) {
            studio.sourceURL = url
        } else {
            studio.usesText = false
            studio.markURL = url
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
        HStack(alignment: .center, spacing: 14) {
            Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                ForEach(0..<3, id: \.self) { row in
                    GridRow {
                        ForEach(0..<3, id: \.self) { column in
                            cell(anchors[row * 3 + column])
                        }
                    }
                }
            }
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private var label: String {
        switch placement {
        case .preset(let anchor): return anchor.title
        case .manual: return "Placement libre"
        }
    }

    @ViewBuilder
    private func cell(_ anchor: Anchor) -> some View {
        if isSelected(anchor) {
            button(anchor).buttonStyle(.borderedProminent)
        } else {
            button(anchor).buttonStyle(.bordered)
        }
    }

    private func button(_ anchor: Anchor) -> some View {
        Button {
            placement = .preset(anchor)
        } label: {
            Image(systemName: symbol(anchor))
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 14)
        }
        .controlSize(.small)
        .buttonBorderShape(.roundedRectangle)
        .help(anchor.title)
        .accessibilityLabel(anchor.title)
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

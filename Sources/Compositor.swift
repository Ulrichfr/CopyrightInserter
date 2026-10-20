import CoreGraphics
import CoreText
import Foundation
import ImageIO

enum Anchor: String, CaseIterable, Identifiable, Sendable {
    case topLeading
    case top
    case topTrailing
    case leading
    case center
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topLeading: return "Haut gauche"
        case .top: return "Haut"
        case .topTrailing: return "Haut droite"
        case .leading: return "Gauche"
        case .center: return "Centre"
        case .trailing: return "Droite"
        case .bottomLeading: return "Bas gauche"
        case .bottom: return "Bas"
        case .bottomTrailing: return "Bas droite"
        }
    }
}

enum Placement: Equatable, Sendable {
    case preset(Anchor)
    case manual(x: Double, y: Double)
}

enum MarkInk: String, CaseIterable, Identifiable, Sendable {
    case white
    case cream
    case black

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "Blanc"
        case .cream: return "Ivoire"
        case .black: return "Noir"
        }
    }

    var color: CGColor {
        switch self {
        case .white:
            return CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        case .cream:
            return CGColor(red: 0.98, green: 0.95, blue: 0.88, alpha: 1)
        case .black:
            return CGColor(red: 0.1, green: 0.09, blue: 0.08, alpha: 1)
        }
    }
}

enum FitAxis: String, CaseIterable, Identifiable, Sendable {
    case original
    case width
    case height

    var id: String { rawValue }
}

enum Mark: Sendable {
    case file(URL)
    case text(String, MarkInk)
}

struct CompositeOptions: Equatable, Sendable {
    var placement: Placement
    var opacity: Double
    var scale: Double
    var margin: Double
    var jpegQuality: Double
    var shadow: Bool
    var keepLocation: Bool
    var fit: FitAxis
    var fitPixels: Int

    init(
        placement: Placement,
        opacity: Double,
        scale: Double,
        margin: Double,
        jpegQuality: Double,
        shadow: Bool = true,
        keepLocation: Bool = false,
        fit: FitAxis = .original,
        fitPixels: Int = 1200
    ) {
        self.placement = placement
        self.opacity = opacity
        self.scale = scale
        self.margin = margin
        self.jpegQuality = jpegQuality
        self.shadow = shadow
        self.keepLocation = keepLocation
        self.fit = fit
        self.fitPixels = fitPixels
    }

    static let standard = CompositeOptions(
        placement: .preset(.bottomTrailing),
        opacity: 0.92,
        scale: 0.28,
        margin: 0.04,
        jpegQuality: 0.9,
        shadow: true,
        keepLocation: false
    )
}

struct BatchReport: Sendable {
    var written: Int = 0
    var skipped: [String] = []
    var outputFolder: URL?
}

enum ComposeError: Error, LocalizedError {
    case unreadable(String)
    case unsupported(String)
    case unwritable(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let name):
            return "Impossible de lire \(name)."
        case .unsupported(let name):
            return "\(name) : format ignoré."
        case .unwritable(let name):
            return "Impossible d'enregistrer \(name)."
        }
    }
}

enum Compositor {
    static let sourceExtensions: Set<String> = [
        "jpg", "jpeg", "png", "tif", "tiff", "gif", "bmp", "heic", "heif", "webp"
    ]

    static func loadImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ComposeError.unreadable(url.lastPathComponent)
        }
        return image
    }

    static func renderText(_ text: String, ink: MarkInk) -> CGImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let font = CTFontCreateWithName("Georgia" as CFString, 140, nil)
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: ink.color
        ] as CFDictionary
        let attributed = CFAttributedStringCreate(nil, trimmed as CFString, attributes)
        guard let attributed else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let measured = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let pad: CGFloat = 36
        let width = max(1, Int(ceil(measured + pad * 2)))
        let height = max(1, Int(ceil(ascent + descent + leading + pad * 2)))
        guard let context = bitmap(width: width, height: height, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            return nil
        }
        context.setAllowsFontSmoothing(true)
        context.setShouldAntialias(true)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: pad, y: pad + descent)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    static func loadMark(_ mark: Mark) throws -> CGImage {
        switch mark {
        case .file(let url):
            return try loadImage(at: url)
        case .text(let text, let ink):
            guard let image = renderText(text, ink: ink) else {
                throw ComposeError.unreadable("le texte de la marque")
            }
            return image
        }
    }

    static func fittedSize(width: Int, height: Int, options: CompositeOptions) -> (Int, Int) {
        let pixels = min(8_000, max(32, options.fitPixels))
        switch options.fit {
        case .original:
            return (max(1, width), max(1, height))
        case .width:
            let fittedWidth = pixels
            let fittedHeight = max(1, Int((Double(height) * Double(fittedWidth) / Double(max(width, 1))).rounded()))
            return (fittedWidth, fittedHeight)
        case .height:
            let fittedHeight = pixels
            let fittedWidth = max(1, Int((Double(width) * Double(fittedHeight) / Double(max(height, 1))).rounded()))
            return (fittedWidth, fittedHeight)
        }
    }

    static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        if image.width == width, image.height == height { return image }
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = bitmap(width: width, height: height, colorSpace: colorSpace)
                ?? bitmap(width: width, height: height, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func composite(photo: CGImage, mark: CGImage, options: CompositeOptions) -> CGImage? {
        let (width, height) = fittedSize(width: photo.width, height: photo.height, options: options)
        guard let canvas = resize(photo, width: width, height: height) else { return nil }
        return stamp(photo: canvas, mark: mark, options: options)
    }

    private static func stamp(photo: CGImage, mark: CGImage, options: CompositeOptions) -> CGImage? {
        let width = photo.width
        let height = photo.height
        guard width > 0, height > 0, mark.width > 0, mark.height > 0 else { return nil }
        let colorSpace = photo.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = bitmap(width: width, height: height, colorSpace: colorSpace)
                ?? bitmap(width: width, height: height, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            return nil
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        context.draw(photo, in: bounds)
        context.saveGState()
        if options.shadow {
            let blur = CGFloat(max(width, height)) * 0.012
            context.setShadow(
                offset: CGSize(width: 0, height: -CGFloat(height) * 0.004),
                blur: blur,
                color: CGColor(gray: 0, alpha: 0.55)
            )
        }
        context.setAlpha(CGFloat(min(1, max(0, options.opacity))))
        context.draw(mark, in: markRect(photoWidth: width, photoHeight: height, mark: mark, options: options))
        context.restoreGState()
        return context.makeImage()
    }

    static func markRect(photoWidth: Int, photoHeight: Int, mark: CGImage, options: CompositeOptions) -> CGRect {
        let scale = min(0.9, max(0.02, options.scale))
        let markWidth = max(1, Int((Double(photoWidth) * scale).rounded()))
        let aspect = Double(mark.height) / Double(max(mark.width, 1))
        var markHeight = max(1, Int((Double(markWidth) * aspect).rounded()))
        var fittedWidth = markWidth
        if markHeight > photoHeight {
            markHeight = photoHeight
            fittedWidth = max(1, Int((Double(markHeight) / aspect).rounded()))
        }
        if fittedWidth > photoWidth {
            fittedWidth = photoWidth
            markHeight = max(1, Int((Double(fittedWidth) * aspect).rounded()))
        }

        let inset = Int((Double(min(photoWidth, photoHeight)) * min(0.4, max(0, options.margin))).rounded())
        let minX = min(inset, max(0, photoWidth - fittedWidth))
        let minY = min(inset, max(0, photoHeight - markHeight))
        let maxX = max(minX, photoWidth - fittedWidth - inset)
        let maxY = max(minY, photoHeight - markHeight - inset)

        let topX: Int
        let topY: Int
        switch options.placement {
        case .preset(let anchor):
            switch anchor {
            case .topLeading: (topX, topY) = (minX, minY)
            case .top: (topX, topY) = ((minX + maxX) / 2, minY)
            case .topTrailing: (topX, topY) = (maxX, minY)
            case .leading: (topX, topY) = (minX, (minY + maxY) / 2)
            case .center: (topX, topY) = ((minX + maxX) / 2, (minY + maxY) / 2)
            case .trailing: (topX, topY) = (maxX, (minY + maxY) / 2)
            case .bottomLeading: (topX, topY) = (minX, maxY)
            case .bottom: (topX, topY) = ((minX + maxX) / 2, maxY)
            case .bottomTrailing: (topX, topY) = (maxX, maxY)
            }
        case .manual(let x, let y):
            let rawX = Int((x * Double(photoWidth)).rounded())
            let rawY = Int((y * Double(photoHeight)).rounded())
            topX = min(max(0, rawX), max(0, photoWidth - fittedWidth))
            topY = min(max(0, rawY), max(0, photoHeight - markHeight))
        }

        let cgY = photoHeight - topY - markHeight
        return CGRect(x: topX, y: cgY, width: fittedWidth, height: markHeight)
    }

    static func previewPair(photo: CGImage, mark: CGImage, options: CompositeOptions, maxSide: Int) -> (plain: CGImage, marked: CGImage)? {
        let (width, height) = fittedSize(width: photo.width, height: photo.height, options: options)
        guard let plain = resize(photo, width: width, height: height),
              let marked = stamp(photo: plain, mark: mark, options: options) else { return nil }
        return (downsample(plain, maxSide: maxSide), downsample(marked, maxSide: maxSide))
    }

    static func sourceFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return items.filter { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { return false }
            return sourceExtensions.contains(url.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func outputURL(for sourceFile: URL, sourceFolder: URL, destination: URL?) -> URL {
        if let destination {
            return destination.appendingPathComponent(sourceFile.lastPathComponent)
        }
        return sourceFolder.appendingPathComponent("c_\(sourceFile.lastPathComponent)")
    }

    static func runBatch(
        mark: Mark,
        sourceFolder: URL,
        destination: URL?,
        options: CompositeOptions,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> BatchReport {
        let renderedMark = try loadMark(mark)
        let files = sourceFiles(in: sourceFolder).filter { file in
            destination != nil || !file.lastPathComponent.hasPrefix("c_")
        }
        var report = BatchReport()
        report.outputFolder = destination ?? sourceFolder
        let total = files.count
        if total == 0 { return report }
        if let destination {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        }
        for (index, file) in files.enumerated() {
            let output = outputURL(for: file, sourceFolder: sourceFolder, destination: destination)
            if output.standardizedFileURL == file.standardizedFileURL {
                report.skipped.append("\(file.lastPathComponent) : même chemin que l'original.")
            } else {
                do {
                    let photo = try loadImage(at: file)
                    guard let rendered = composite(photo: photo, mark: renderedMark, options: options) else {
                        throw ComposeError.unreadable(file.lastPathComponent)
                    }
                    try write(rendered, source: file, to: output, jpegQuality: options.jpegQuality, keepLocation: options.keepLocation)
                    report.written += 1
                } catch {
                    report.skipped.append(error.localizedDescription)
                }
            }
            onProgress?(index + 1, total)
        }
        return report
    }

    static func write(_ image: CGImage, source: URL, to url: URL, jpegQuality: Double, keepLocation: Bool) throws {
        let type = destinationType(for: url.pathExtension)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw ComposeError.unwritable(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, properties(from: source, jpegQuality: jpegQuality, keepLocation: keepLocation))
        if CGImageDestinationFinalize(destination) { return }

        guard let retry = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw ComposeError.unwritable(url.lastPathComponent)
        }
        CGImageDestinationAddImage(retry, image, [
            kCGImageDestinationLossyCompressionQuality: min(1, max(0.1, jpegQuality))
        ] as CFDictionary)
        guard CGImageDestinationFinalize(retry) else {
            throw ComposeError.unwritable(url.lastPathComponent)
        }
    }

    static func properties(from source: URL, jpegQuality: Double, keepLocation: Bool) -> CFDictionary {
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: min(1, max(0.1, jpegQuality))
        ]
        let kept: [CFString] = [
            kCGImagePropertyExifDictionary,
            kCGImagePropertyIPTCDictionary,
            kCGImagePropertyTIFFDictionary
        ]
        if let sourceImage = CGImageSourceCreateWithURL(source as CFURL, nil),
           let metadata = CGImageSourceCopyPropertiesAtIndex(sourceImage, 0, nil) as? [CFString: Any] {
            for key in kept {
                if let value = metadata[key] { properties[key] = value }
            }
            if keepLocation, let gps = metadata[kCGImagePropertyGPSDictionary] {
                properties[kCGImagePropertyGPSDictionary] = gps
            }
        }
        return properties as CFDictionary
    }

    static func downsample(_ image: CGImage, maxSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide, maxSide > 0 else { return image }
        let ratio = Double(maxSide) / Double(longest)
        let width = max(1, Int((Double(image.width) * ratio).rounded()))
        let height = max(1, Int((Double(image.height) * ratio).rounded()))
        guard let context = bitmap(width: width, height: height, colorSpace: CGColorSpaceCreateDeviceRGB()) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private static func destinationType(for pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "jpg", "jpeg": return "public.jpeg"
        case "png": return "public.png"
        case "tif", "tiff": return "public.tiff"
        case "gif": return "com.compuserve.gif"
        case "bmp": return "com.microsoft.bmp"
        case "heic", "heif": return "public.heic"
        case "webp": return "org.webmproject.webp"
        default: return "public.jpeg"
        }
    }

    private static func bitmap(width: Int, height: Int, colorSpace: CGColorSpace) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}

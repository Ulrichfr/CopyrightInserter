import CoreGraphics
import Foundation
import ImageIO

@main
struct CompositorTest {
    static func main() {
        let photo = solid(width: 100, height: 80, red: 1, green: 0, blue: 0)
        let mark = solid(width: 10, height: 10, red: 0, green: 0, blue: 1)
        let options = CompositeOptions(
            placement: .preset(.topTrailing),
            opacity: 1,
            scale: 0.1,
            margin: 0,
            jpegQuality: 0.9,
            shadow: false,
            keepLocation: false
        )
        guard let rendered = Compositor.composite(photo: photo, mark: mark, options: options) else {
            fail("composite returned nil")
        }
        let corner = pixel(rendered, x: 95, y: 5)
        let untouched = pixel(rendered, x: 2, y: 2)
        expect(corner.blue > 200 && corner.red < 40, "mark should cover the top-right corner, got \(corner)")
        expect(untouched.red > 200 && untouched.blue < 40, "top-left should stay red, got \(untouched)")

        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("marque-test-\(UUID().uuidString)")
        let source = folder.appendingPathComponent("source")
        let destination = folder.appendingPathComponent("out")
        try! FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try! writePNG(photo, to: source.appendingPathComponent("photo.png"))
        let markURL = folder.appendingPathComponent("mark.png")
        try! writePNG(mark, to: markURL)
        let report = try! Compositor.runBatch(
            mark: .file(markURL),
            sourceFolder: source,
            destination: destination,
            options: options
        )
        expect(report.written == 1, "expected one written file, got \(report.written) skipped \(report.skipped)")
        let output = destination.appendingPathComponent("photo.png")
        expect(FileManager.default.fileExists(atPath: output.path), "output missing")
        let saved = try! Compositor.loadImage(at: output)
        let savedCorner = pixel(saved, x: 95, y: 5)
        expect(savedCorner.blue > 200, "saved image lost the mark, got \(savedCorner)")

        var sized = options
        sized.fit = .width
        sized.fitPixels = 50
        sized.scale = 0.2
        guard let fitted = Compositor.composite(photo: photo, mark: mark, options: sized) else {
            fail("resized composite returned nil")
        }
        expect(fitted.width == 50 && fitted.height == 40, "expected 50×40, got \(fitted.width)×\(fitted.height)")
        let fittedCorner = pixel(fitted, x: 45, y: 5)
        let fittedUntouched = pixel(fitted, x: 2, y: 2)
        expect(fittedCorner.blue > 200 && fittedCorner.red < 40, "logo should sit on the resized photo, got \(fittedCorner)")
        expect(fittedUntouched.red > 200, "resized corner should stay red, got \(fittedUntouched)")
        sized.fit = .height
        sized.fitPixels = 40
        let byHeight = Compositor.fittedSize(width: 100, height: 80, options: sized)
        expect(byHeight == (50, 40), "height fit should keep the ratio, got \(byHeight)")

        let textMark = Compositor.renderText("© Ada", ink: .black)
        expect(textMark != nil && (textMark?.width ?? 0) > 40 && hasInk(textMark!), "text mark was not drawn")

        let located = source.appendingPathComponent("located.jpg")
        try! writeJPEG(photo, to: located, gps: true)
        let stripped = folder.appendingPathComponent("stripped")
        let kept = folder.appendingPathComponent("kept")
        var privateOptions = options
        privateOptions.keepLocation = false
        _ = try! Compositor.runBatch(mark: .file(markURL), sourceFolder: source, destination: stripped, options: privateOptions)
        expect(!hasGPS(stripped.appendingPathComponent("located.jpg")), "GPS should be removed")
        var publicOptions = options
        publicOptions.keepLocation = true
        _ = try! Compositor.runBatch(mark: .file(markURL), sourceFolder: source, destination: kept, options: publicOptions)
        expect(hasGPS(kept.appendingPathComponent("located.jpg")), "GPS should be kept when asked")
        print("ok")
    }

    static func fail(_ message: String) -> Never {
        fputs(message + "\n", stderr)
        Foundation.exit(1)
    }

    static func expect(_ condition: Bool, _ message: String) {
        if !condition { fail(message) }
    }

    static func solid(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> (red: Int, green: Int, blue: Int) {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            fail("no pixel data")
        }
        let bpp = image.bitsPerPixel / 8
        let offset = y * image.bytesPerRow + x * bpp
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    static func writeJPEG(_ image: CGImage, to url: URL, gps: Bool) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            fail("jpeg destination")
        }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        if gps {
            properties[kCGImagePropertyGPSDictionary] = [
                kCGImagePropertyGPSLatitude: 48.8,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 2.3,
                kCGImagePropertyGPSLongitudeRef: "E"
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        if !CGImageDestinationFinalize(destination) { fail("jpeg finalize") }
    }

    static func hasInk(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return false }
        let count = CFDataGetLength(data)
        var index = 3
        while index < count {
            if bytes[index] > 20 { return true }
            index += 4
        }
        return false
    }

    static func hasGPS(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return false
        }
        return properties[kCGImagePropertyGPSDictionary] != nil
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            fail("destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) { fail("finalize") }
    }
}

import Vision
import ImageIO
import CoreGraphics
import AppKit

/// Offline text recognition via Apple's Vision framework — no network, no API.
/// Used by the region and window capture actions. Recognizes Russian and
/// English (the two languages Griasa targets).
enum OCR {
    static func recognize(imageData: Data) -> String {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        return recognize(cgImage: cgImage)
    }

    static func recognize(cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ru-RU", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("Griasa: OCR failed — %@", error.localizedDescription)
            return ""
        }

        let observations = request.results ?? []
        // Vision's bounding boxes are normalized with a bottom-left origin, so a
        // larger y is higher on screen — sort descending to read top-to-bottom.
        let lines = observations
            .sorted { $0.boundingBox.origin.y > $1.boundingBox.origin.y }
            .compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension NSImage {
    /// PNG-encoded bytes, so an image can cross an actor boundary as `Data`
    /// (which is Sendable) before OCR runs off the main thread.
    var pngRepresentation: Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

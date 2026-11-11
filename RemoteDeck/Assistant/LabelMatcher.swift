import ClaudeKit
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// A run of text found on a screenshot: its rectangle is in the screenshot's pixels (the image the
/// model saw, `EncodedImage.width × height`), origin top-left.
struct LocatedText: Equatable, Sendable {
    var text: String
    var rect: CGRect
}

/// Finds the visible text of a screenshot (OCR). `VisionTextLocator` in the app, a fake in tests and
/// in `-LibraryDemo assistant-apple`.
protocol TextLocator: Sendable {
    func locate(in image: EncodedImage) async -> [LocatedText]
}

/// A label the Apple model named, resolved on the screenshot it saw (pure).
enum LabelMatch: Equatable {
    /// The centre of the matched text, in screenshot pixels.
    case found(ScreenPoint, LocatedText)
    case notFound
    /// Several equal candidates (the count): never guessed.
    case ambiguous(Int)
}

enum LabelMatcher {
    /// Case- and diacritic-insensitive, punctuation and symbols trimmed at both ends, inner white
    /// space collapsed.
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let trimmed = folded.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters).union(.symbols))
        return trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// An exact match first (one, or `.ambiguous` when there are several), then a unique text
    /// containing the label; several → `.ambiguous`, none → `.notFound`.
    static func match(_ label: String, in texts: [LocatedText]) -> LabelMatch {
        let wanted = normalize(label)
        guard !wanted.isEmpty else { return .notFound }
        let candidates = texts.map { (normalize($0.text), $0) }
        let exact = candidates.filter { $0.0 == wanted }.map(\.1)
        if exact.count > 1 { return .ambiguous(exact.count) }
        if let only = exact.first { return .found(centre(of: only.rect), only) }
        let containing = candidates.filter { $0.0.contains(wanted) }.map(\.1)
        if containing.count > 1 { return .ambiguous(containing.count) }
        if let only = containing.first { return .found(centre(of: only.rect), only) }
        return .notFound
    }

    static func centre(of rect: CGRect) -> ScreenPoint {
        ScreenPoint(x: max(0, Int(rect.midX.rounded(.down))), y: max(0, Int(rect.midY.rounded(.down))))
    }

    /// Vision's normalised bounding box (0…1, origin bottom-left) in image pixels, origin top-left.
    static func imageRect(normalized box: CGRect, width: Int, height: Int) -> CGRect {
        let w = Double(width), h = Double(height)
        return CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
    }
}

/// OCR with Vision (`VNRecognizeTextRequest`, accurate, French and English) on the decoded bytes of
/// the very screenshot the model saw. Runs off the main actor.
struct VisionTextLocator: TextLocator {
    func locate(in image: EncodedImage) async -> [LocatedText] {
        let data = image.data
        let width = image.width, height = image.height
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["fr-FR", "en-US"]
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: cgImage).perform([request])
            } catch {
                return []
            }
            return (request.results ?? []).compactMap { observation -> LocatedText? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                return LocatedText(text: text, rect: LabelMatcher.imageRect(normalized: observation.boundingBox,
                                                                            width: width, height: height))
            }
        }.value
    }
}

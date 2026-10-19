import CoreGraphics
import Foundation
import PDFKit
import Vision

/// A PDF attached to a message, reduced to its text on device.
struct DocumentAttachment: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var text: String
    var pageCount: Int
    /// Pages that had no text layer and were read with Vision OCR.
    var ocrPageCount = 0
}

enum PDFExtractor {
    enum ExtractionError: LocalizedError {
        case unreadable, empty

        var errorDescription: String? {
            switch self {
            case .unreadable: "The PDF could not be opened."
            case .empty: "No text was found in the PDF."
            }
        }
    }

    /// Pages with less embedded text than this are treated as scans and OCR'd.
    private static let minimumTextLength = 20

    /// Extracts text with PDFKit, falling back to Vision OCR for scanned pages.
    static func extract(from url: URL) async throws -> DocumentAttachment {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        return try await Task.detached(priority: .userInitiated) {
            guard let document = PDFDocument(url: url) else { throw ExtractionError.unreadable }
            var pages: [String] = []
            var ocrCount = 0
            for index in 0..<document.pageCount {
                try Task.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if text.count < minimumTextLength, let image = render(page) {
                    let recognized = try recognizeText(in: image)
                    if recognized.count > text.count {
                        text = recognized
                        ocrCount += 1
                    }
                }
                if !text.isEmpty { pages.append("[Page \(index + 1)]\n\(text)") }
            }
            guard !pages.isEmpty else { throw ExtractionError.empty }
            return DocumentAttachment(
                name: url.lastPathComponent,
                text: pages.joined(separator: "\n\n"),
                pageCount: document.pageCount,
                ocrPageCount: ocrCount
            )
        }.value
    }

    /// Renders a page to a bitmap at roughly 200 dpi, which Vision reads well.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(200.0 / 72.0, 4096 / max(bounds.width, bounds.height, 1))
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    private static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}

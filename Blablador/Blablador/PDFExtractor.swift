import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Who reads scanned pages and photos.
enum OCREngine: String, CaseIterable, Identifiable {
    case onDevice, blablador

    var id: String { rawValue }

    var title: String {
        switch self {
        case .onDevice: "On device (Apple Vision)"
        case .blablador: "Blablador (LightOnOCR)"
        }
    }

    static var current: OCREngine {
        UserDefaults.standard.string(forKey: "ocrEngine").flatMap(OCREngine.init) ?? .onDevice
    }
}

/// A PDF attached to a message, reduced to its text on device.
struct DocumentAttachment: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var text: String
    var pageCount: Int
    /// Pages that had no text layer and were read with Vision OCR.
    var ocrPageCount = 0
    /// For data files (CSV, Excel, JSON…): the original file in DataFiles, given to Python as /data/<name>.
    /// `text` then holds a description and the first lines.
    var dataFile: String?
}

enum PDFExtractor {
    enum ExtractionError: LocalizedError {
        case unreadable, empty

        var errorDescription: String? {
            switch self {
            case .unreadable: "The PDF could not be opened."
            case .empty: "No text was found."
            }
        }
    }

    /// Pages with less embedded text than this are treated as scans and OCR'd.
    private static let minimumTextLength = 20

    /// Extracts text with PDFKit, falling back to OCR for scanned pages.
    /// With an API and the Blablador engine selected, pages are read with LightOnOCR, else with Vision.
    static func extract(from url: URL, api: BlabladorAPI? = nil) async throws -> DocumentAttachment {
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
                    let recognized = try await recognize(image, api: api)
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

    /// Reads text in an image with the selected OCR engine, falling back to Vision if Blablador fails.
    static func recognize(_ image: CGImage, api: BlabladorAPI?) async throws -> String {
        if let api, OCREngine.current == .blablador, let jpeg = jpeg(image) {
            if let text = try? await api.ocr(jpeg: jpeg), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return markdownTables(text).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return try recognizeText(in: image)
    }

    /// OCRs a photo into a document attachment.
    static func extract(photo data: Data, name: String, api: BlabladorAPI?) async throws -> DocumentAttachment {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary)
        else { throw ExtractionError.unreadable }
        let text = try await recognize(image, api: api)
        guard !text.isEmpty else { throw ExtractionError.empty }
        return DocumentAttachment(name: name, text: text, pageCount: 1, ocrPageCount: 1)
    }

    /// LightOnOCR works best with the longest side around 1540 px.
    private static func jpeg(_ image: CGImage) -> Data? {
        let longest = max(image.width, image.height)
        var scaled = image
        if longest > 1540 {
            let factor = 1540.0 / Double(longest)
            let width = Int(Double(image.width) * factor), height = Int(Double(image.height) * factor)
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let resized = context.makeImage() else { return nil }
            scaled = resized
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Converts the HTML tables LightOnOCR emits into Markdown tables.
    static func markdownTables(_ text: String) -> String {
        let table = try! NSRegularExpression(pattern: #"<table[^>]*>([\s\S]*?)</table>"#, options: .caseInsensitive)
        let row = try! NSRegularExpression(pattern: #"<tr[^>]*>([\s\S]*?)</tr>"#, options: .caseInsensitive)
        let cell = try! NSRegularExpression(pattern: #"<t([hd])[^>]*>([\s\S]*?)</t[hd]>"#, options: .caseInsensitive)
        func clean(_ html: String) -> String {
            html.replacingOccurrences(of: #"<br\s*/?>"#, with: "<br>", options: [.regularExpression, .caseInsensitive])
                .replacingOccurrences(of: #"<(?!br>)[^>]+>"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
                .components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }
        var result = text
        let ns = text as NSString
        for match in table.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let body = ns.substring(with: match.range(at: 1)) as NSString
            let rows = row.matches(in: body as String, range: NSRange(location: 0, length: body.length)).map { rowMatch -> [String] in
                let inner = body.substring(with: rowMatch.range(at: 1)) as NSString
                return cell.matches(in: inner as String, range: NSRange(location: 0, length: inner.length)).map { clean(inner.substring(with: $0.range(at: 2))) }
            }.filter { !$0.isEmpty }
            guard let header = rows.first else { continue }
            let columns = rows.map(\.count).max() ?? header.count
            func line(_ cells: [String]) -> String { "| " + (cells + Array(repeating: "", count: columns - cells.count)).joined(separator: " | ") + " |" }
            let markdown = ([line(header), "|" + String(repeating: " --- |", count: columns)] + rows.dropFirst().map(line)).joined(separator: "\n")
            result = (result as NSString).replacingCharacters(in: match.range, with: "\n" + markdown + "\n")
        }
        return result
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

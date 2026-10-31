import Foundation
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Answers as documents: formatted text on the clipboard (pastes with headings, lists and tables into Google Docs,
/// Word or mail) and Word files. Works from the answer's Markdown, without Google or any server.
enum DocumentExport {
    // MARK: Markdown blocks

    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, ordered: Int?)
        case quote(String)
        case code(String)
        case table([[String]])
        case rule
    }

    static func blocks(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var table: [[String]] = []
        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.table(table)) }
            table = []
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushParagraph(); flushTable()
                if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))); code = nil } else { code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.hasPrefix("|") {
                flushParagraph()
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil }) { table.append(cells) }
                continue
            }
            flushTable()
            if line.isEmpty {
                flushParagraph()
            } else if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushParagraph()
                blocks.append(.heading(line[range].filter { $0 == "#" }.count, String(line[range.upperBound...])))
            } else if line.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil {
                flushParagraph()
                blocks.append(.rule)
            } else if let range = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                flushParagraph()
                blocks.append(.bullet(String(line[range.upperBound...]), ordered: nil))
            } else if let range = line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flushParagraph()
                blocks.append(.bullet(String(line[range.upperBound...]), ordered: Int(line.prefix { $0.isNumber })))
            } else if line.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flushParagraph(); flushTable()
        return blocks
    }

    /// Inline spans: bold, italic, code and links; source marks like [3] are dropped.
    struct Span: Equatable {
        var text: String
        var bold = false
        var italic = false
        var code = false
        var link: String?
    }

    static func spans(_ text: String) -> [Span] {
        let cleaned = text.replacingOccurrences(of: #"\s?(\[\d{1,3}\])+"#, with: "", options: .regularExpression)
        var spans: [Span] = []
        var rest = Substring(cleaned)
        let pattern = #"\*\*(.+?)\*\*|__(.+?)__|\*(.+?)\*|_(.+?)_|`(.+?)`|\[([^\]]+)\]\(([^)\s]+)\)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        while !rest.isEmpty {
            let string = String(rest)
            guard let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
                  let range = Range(match.range, in: string) else {
                spans.append(Span(text: string))
                break
            }
            if range.lowerBound > string.startIndex { spans.append(Span(text: String(string[..<range.lowerBound]))) }
            func group(_ index: Int) -> String? { Range(match.range(at: index), in: string).map { String(string[$0]) } }
            if let bold = group(1) ?? group(2) {
                spans.append(Span(text: bold, bold: true))
            } else if let italic = group(3) ?? group(4) {
                spans.append(Span(text: italic, italic: true))
            } else if let code = group(5) {
                spans.append(Span(text: code, code: true))
            } else if let label = group(6), let url = group(7) {
                spans.append(Span(text: label, link: url))
            }
            rest = Substring(string[range.upperBound...])
        }
        return spans
    }

    // MARK: HTML (clipboard)

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func inlineHTML(_ text: String) -> String {
        spans(text).map { span in
            var html = escape(span.text)
            if span.code { html = "<code>\(html)</code>" }
            if span.italic { html = "<em>\(html)</em>" }
            if span.bold { html = "<strong>\(html)</strong>" }
            if let link = span.link { html = "<a href=\"\(escape(link))\">\(html)</a>" }
            return html
        }.joined()
    }

    static func html(markdown: String) -> String {
        var html = ""
        var list: String?
        for block in blocks(markdown) {
            let tag: String? = if case let .bullet(_, ordered) = block { ordered == nil ? "ul" : "ol" } else { nil }
            if list != tag {
                if let list { html += "</\(list)>" }
                if let tag { html += "<\(tag)>" }
                list = tag
            }
            switch block {
            case let .heading(level, text): html += "<h\(level)>\(inlineHTML(text))</h\(level)>"
            case let .paragraph(text): html += "<p>\(inlineHTML(text))</p>"
            case let .bullet(text, _): html += "<li>\(inlineHTML(text))</li>"
            case let .quote(text): html += "<blockquote>\(inlineHTML(text))</blockquote>"
            case let .code(text): html += "<pre><code>\(escape(text))</code></pre>"
            case .rule: html += "<hr>"
            case let .table(rows):
                html += "<table border=\"1\" style=\"border-collapse:collapse\">"
                for (index, row) in rows.enumerated() {
                    let cell = index == 0 ? "th" : "td"
                    html += "<tr>" + row.map { "<\(cell) style=\"padding:4px 8px\">\(inlineHTML($0))</\(cell)>" }.joined() + "</tr>"
                }
                html += "</table>"
            }
        }
        if let list { html += "</\(list)>" }
        return "<meta charset=\"utf-8\">" + html
    }

    /// Plain text for apps that don't take formatting.
    static func plain(markdown: String) -> String {
        blocks(markdown).map { block in
            func text(_ value: String) -> String { spans(value).map(\.text).joined() }
            switch block {
            case let .heading(_, value): return text(value).uppercased() == text(value) ? text(value) : text(value)
            case let .paragraph(value): return text(value)
            case let .bullet(value, ordered): return (ordered.map { "\($0). " } ?? "• ") + text(value)
            case let .quote(value): return "“" + text(value) + "”"
            case let .code(value): return value
            case let .table(rows): return rows.map { $0.map(text).joined(separator: "\t") }.joined(separator: "\n")
            case .rule: return "———"
            }
        }.joined(separator: "\n\n")
    }

    /// Puts the answer on the clipboard as formatted text plus plain text.
    @MainActor
    static func copyFormatted(_ markdown: String) {
        let html = html(markdown: markdown)
        let plain = plain(markdown: markdown)
#if os(iOS)
        UIPasteboard.general.setItems([[UTType.html.identifier: html, UTType.utf8PlainText.identifier: plain]])
#else
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(html, forType: .html)
        board.setString(plain, forType: .string)
#endif
    }

    // MARK: Word (.docx)

    private static func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func runs(_ text: String, size: Int? = nil, bold: Bool = false, mono: Bool = false) -> String {
        spans(text).map { span in
            var properties = ""
            if bold || span.bold { properties += "<w:b/>" }
            if span.italic { properties += "<w:i/>" }
            if mono || span.code { properties += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\"/>" }
            if span.link != nil { properties += "<w:color w:val=\"1A56DB\"/><w:u w:val=\"single\"/>" }
            if let size { properties += "<w:sz w:val=\"\(size)\"/>" }
            return "<w:r><w:rPr>\(properties)</w:rPr><w:t xml:space=\"preserve\">\(xml(span.text))</w:t></w:r>"
        }.joined()
    }

    private static func paragraph(_ content: String, spacingAfter: Int = 160, indent: Int? = nil, style: String = "") -> String {
        "<w:p><w:pPr>\(style)<w:spacing w:after=\"\(spacingAfter)\"/>\(indent.map { "<w:ind w:left=\"\($0)\" w:hanging=\"260\"/>" } ?? "")</w:pPr>\(content)</w:p>"
    }

    static func documentXML(markdown: String) -> String {
        var body = ""
        for block in blocks(markdown) {
            switch block {
            case let .heading(level, text):
                let size = [1: 36, 2: 30, 3: 26][level] ?? 24
                body += paragraph(runs(text, size: size, bold: true), spacingAfter: 120, style: "<w:pStyle w:val=\"Heading\(min(level, 6))\"/><w:keepNext/>")
            case let .paragraph(text):
                body += paragraph(runs(text))
            case let .bullet(text, ordered):
                body += paragraph("<w:r><w:t xml:space=\"preserve\">\(ordered.map { "\($0)." } ?? "•")\t</w:t></w:r>" + runs(text), spacingAfter: 60, indent: 520)
            case let .quote(text):
                body += "<w:p><w:pPr><w:ind w:left=\"520\"/><w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"8B5CF6\"/></w:pBdr></w:pPr>\(runs(text))</w:p>"
            case let .code(text):
                for line in text.components(separatedBy: "\n") { body += paragraph(runs(line, mono: true), spacingAfter: 0) }
            case .rule:
                body += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BBBBBB\"/></w:pBdr></w:pPr></w:p>"
            case let .table(rows):
                body += "<w:tbl><w:tblPr><w:tblBorders>" + ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:color=\"BBBBBB\"/>" }.joined() + "</w:tblBorders></w:tblPr>"
                for (index, row) in rows.enumerated() {
                    body += "<w:tr>" + row.map { "<w:tc><w:p>\(runs($0, bold: index == 0))</w:p></w:tc>" }.joined() + "</w:tr>"
                }
                body += "</w:tbl>" + paragraph("")
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr><w:pgMar w:top="1200" w:right="1200" w:bottom="1200" w:left="1200"/></w:sectPr></w:body></w:document>
        """
    }

    /// A Word document from Markdown: headings, paragraphs, bold/italic, lists, quotes, code and tables.
    static func docx(markdown: String) -> Data {
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """
        return Zip.store([
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rels.utf8)),
            ("word/document.xml", Data(documentXML(markdown: markdown).utf8))
        ])
    }

    /// A file name from the answer's first heading or words.
    static func fileName(for markdown: String) -> String {
        let first = blocks(markdown).lazy.compactMap { block -> String? in
            switch block {
            case let .heading(_, text), let .paragraph(text): spans(text).map(\.text).joined()
            default: nil
            }
        }.first ?? "Blablador"
        let name = first.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined().prefix(60).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Blablador" : name
    }
}

/// A minimal ZIP writer (stored, no compression), enough for Office files.
enum Zip {
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }

    static func store(_ files: [(name: String, data: Data)]) -> Data {
        var output = Data()
        var central = Data()
        func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
        func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        for file in files {
            let name = Data(file.name.utf8)
            let crc = crc32(file.data)
            let offset = UInt32(output.count)
            let common = le16(20) + le16(0) + le16(0) + le16(0) + le16(0x21) + le32(crc)
                + le32(UInt32(file.data.count)) + le32(UInt32(file.data.count)) + le16(name.count) + le16(0)
            output += le32(0x0403_4B50) + common + name + file.data
            central += le32(0x0201_4B50) + le16(20) + common + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset) + name
        }
        let centralOffset = UInt32(output.count)
        output += central
        output += le32(0x0605_4B50) + le16(0) + le16(0) + le16(files.count) + le16(files.count)
            + le32(UInt32(central.count)) + le32(centralOffset) + le16(0)
        return output
    }
}

/// A Word file for the save panel / Files.
struct WordFile: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "docx") ?? .data] }
    let data: Data

    init(markdown: String) { data = DocumentExport.docx(markdown: markdown) }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

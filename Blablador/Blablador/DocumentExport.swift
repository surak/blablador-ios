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

// MARK: - Excel and PowerPoint

extension DocumentExport {
    /// The answer's tables (Markdown tables, or a CSV code block), each as rows of cells.
    static func tables(_ markdown: String) -> [[[String]]] {
        var tables: [[[String]]] = blocks(markdown).compactMap { block in
            if case let .table(rows) = block { return rows.map { $0.map { spans($0).map(\.text).joined() } } }
            return nil
        }
        if tables.isEmpty {
            for block in blocks(markdown) {
                if case let .code(text) = block, text.contains(","), text.split(separator: "\n").count > 1 {
                    tables.append(text.split(separator: "\n").map { line in csvCells(String(line)) })
                }
            }
        }
        return tables
    }

    static func csvCells(_ line: String) -> [String] {
        var cells: [String] = [], current = "", quoted = false
        var characters = Array(line)[...]
        while let character = characters.popFirst() {
            if character == "\"" {
                if quoted, characters.first == "\"" { current.append("\""); characters.removeFirst() } else { quoted.toggle() }
            } else if character == ",", !quoted {
                cells.append(current); current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func column(_ index: Int) -> String {
        var index = index, name = ""
        repeat {
            name = String(UnicodeScalar(65 + index % 26)!) + name
            index = index / 26 - 1
        } while index >= 0
        return name
    }

    /// A number in a cell ("1,234.5", "12 %", "−3"), or nil for text.
    static func number(_ text: String) -> Double? {
        var value = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "−", with: "-")
        let percent = value.hasSuffix("%")
        if percent { value = String(value.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard value.range(of: #"^-?(\d{1,3}(,\d{3})+|\d+)(\.\d+)?$"#, options: .regularExpression) != nil,
              let number = Double(value.replacingOccurrences(of: ",", with: "")) else { return nil }
        return percent ? number / 100 : number
    }

    /// An Excel workbook with one sheet per table; the first row is bold and numbers are numbers.
    static func xlsx(markdown: String) -> Data? {
        let tables = tables(markdown)
        guard !tables.isEmpty else { return nil }
        var files: [(String, Data)] = []
        var sheets = "", sheetRels = "", overrides = ""
        for (index, rows) in tables.enumerated() {
            let number = index + 1
            var data = ""
            for (r, row) in rows.enumerated() {
                data += "<row r=\"\(r + 1)\">"
                for (c, cell) in row.enumerated() {
                    let reference = column(c) + String(r + 1)
                    let style = r == 0 ? " s=\"1\"" : ""
                    if r > 0, let value = Self.number(cell) {
                        data += "<c r=\"\(reference)\"\(cell.hasSuffix("%") ? " s=\"2\"" : style)><v>\(value)</v></c>"
                    } else {
                        data += "<c r=\"\(reference)\" t=\"inlineStr\"\(style)><is><t xml:space=\"preserve\">\(xml(cell))</t></is></c>"
                    }
                }
                data += "</row>"
            }
            let widths = (0..<(rows.map(\.count).max() ?? 1)).map { c in
                let longest = rows.map { c < $0.count ? $0[c].count : 0 }.max() ?? 8
                return "<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(min(max(longest + 2, 8), 60))\" customWidth=\"1\"/>"
            }.joined()
            let sheet = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews><cols>\(widths)</cols><sheetData>\(data)</sheetData></worksheet>
            """
            files.append(("xl/worksheets/sheet\(number).xml", Data(sheet.utf8)))
            sheets += "<sheet name=\"\(tables.count == 1 ? "Table" : "Table \(number)")\" sheetId=\"\(number)\" r:id=\"rId\(number)\"/>"
            sheetRels += "<Relationship Id=\"rId\(number)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(number).xml\"/>"
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(number).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
        }
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFEDE9FE"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/><xf numFmtId="10" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """
        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>\(sheets)</sheets></workbook>
        """
        let stylesID = tables.count + 1
        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(sheetRels)<Relationship Id="rId\(stylesID)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(overrides)</Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """
        return Zip.store([("[Content_Types].xml", Data(contentTypes.utf8)), ("_rels/.rels", Data(rels.utf8)),
                          ("xl/workbook.xml", Data(workbook.utf8)), ("xl/_rels/workbook.xml.rels", Data(workbookRels.utf8)),
                          ("xl/styles.xml", Data(styles.utf8))] + files)
    }

    /// Slides from the answer: each heading starts a slide; its paragraphs and list items become bullets.
    static func slides(_ markdown: String) -> [(title: String, bullets: [String])] {
        var slides: [(title: String, bullets: [String])] = []
        func plain(_ text: String) -> String { spans(text).map(\.text).joined() }
        for block in blocks(markdown) {
            switch block {
            case let .heading(_, text):
                slides.append((plain(text), []))
            case let .paragraph(text), let .bullet(text, _), let .quote(text):
                if slides.isEmpty { slides.append((fileName(for: markdown), [])) }
                slides[slides.count - 1].bullets.append(plain(text))
            case let .table(rows):
                if slides.isEmpty { slides.append((fileName(for: markdown), [])) }
                slides[slides.count - 1].bullets += rows.map { $0.map(plain).joined(separator: " · ") }
            default:
                break
            }
        }
        // Long sections continue on a second slide rather than overflowing.
        return slides.flatMap { slide -> [(title: String, bullets: [String])] in
            guard slide.bullets.count > 7 else { return [slide] }
            return stride(from: 0, to: slide.bullets.count, by: 7).enumerated().map { index, start in
                (index == 0 ? slide.title : slide.title + " (continued)", Array(slide.bullets[start..<min(start + 7, slide.bullets.count)]))
            }
        }
    }

    private static let drawing = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""

    private static func textBox(id: Int, name: String, x: Int, y: Int, width: Int, height: Int, paragraphs: String) -> String {
        """
        <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="\(name)"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="\(x)" y="\(y)"/><a:ext cx="\(width)" cy="\(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/></p:spPr><p:txBody><a:bodyPr wrap="square"><a:normAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>
        """
    }

    /// A PowerPoint presentation (16:9), one slide per heading.
    static func pptx(markdown: String) -> Data {
        var slides = slides(markdown)
        if slides.isEmpty { slides = [(fileName(for: markdown), [])] }
        let emptyTree = "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree>"
        var files: [(String, Data)] = []
        var slideIDs = "", presentationRels = "", overrides = ""
        for (index, slide) in slides.enumerated() {
            let number = index + 1
            let title = "<a:p><a:r><a:rPr lang=\"en-US\" sz=\"3600\" b=\"1\"><a:solidFill><a:srgbClr val=\"4C1D95\"/></a:solidFill></a:rPr><a:t>\(xml(slide.title))</a:t></a:r></a:p>"
            let bullets = slide.bullets.isEmpty ? "<a:p><a:endParaRPr lang=\"en-US\"/></a:p>" : slide.bullets.map {
                "<a:p><a:pPr marL=\"342900\" indent=\"-342900\"><a:spcBef><a:spcPts val=\"900\"/></a:spcBef><a:buFont typeface=\"Arial\"/><a:buChar char=\"•\"/></a:pPr><a:r><a:rPr lang=\"en-US\" sz=\"2000\"/><a:t>\(xml($0))</a:t></a:r></a:p>"
            }.joined()
            let shapes = textBox(id: 2, name: "Title", x: 609600, y: 457200, width: 10972800, height: 1143000, paragraphs: title)
                + textBox(id: 3, name: "Content", x: 609600, y: 1714500, width: 10972800, height: 4572000, paragraphs: bullets)
            let slideXML = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <p:sld \(drawing)><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>\(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
            """
            let slideRels = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>
            """
            files += [("ppt/slides/slide\(number).xml", Data(slideXML.utf8)), ("ppt/slides/_rels/slide\(number).xml.rels", Data(slideRels.utf8))]
            slideIDs += "<p:sldId id=\"\(255 + number)\" r:id=\"rId\(number + 1)\"/>"
            presentationRels += "<Relationship Id=\"rId\(number + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide\" Target=\"slides/slide\(number).xml\"/>"
            overrides += "<Override PartName=\"/ppt/slides/slide\(number).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
        }
        let themeID = slides.count + 2
        let presentation = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:presentation \(drawing)><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst><p:sldIdLst>\(slideIDs)</p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>
        """
        let presentationRelsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>\(presentationRels)<Relationship Id="rId\(themeID)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/></Relationships>
        """
        let master = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldMaster \(drawing)><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill><a:effectLst/></p:bgPr></p:bg>\(emptyTree)</p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
        """
        let masterRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/></Relationships>
        """
        let layout = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <p:sldLayout \(drawing) type="blank" preserve="1"><p:cSld name="Blank">\(emptyTree)</p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
        """
        let layoutRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>
        """
        let colors = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "1F2937"), ("lt2", "F3F4F6"), ("accent1", "6366F1"), ("accent2", "8B5CF6"),
                      ("accent3", "EC4899"), ("accent4", "10B981"), ("accent5", "F59E0B"), ("accent6", "3B82F6"), ("hlink", "2563EB"), ("folHlink", "7C3AED")]
            .map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"9525\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>"
        let theme = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Blablador"><a:themeElements><a:clrScheme name="Blablador">\(colors)</a:clrScheme><a:fontScheme name="Blablador"><a:majorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Helvetica Neue"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme><a:fmtScheme name="Blablador"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst><a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst><a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst><a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>
        """
        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/><Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/><Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/><Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>\(overrides)</Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="ppt/presentation.xml"/></Relationships>
        """
        return Zip.store([("[Content_Types].xml", Data(contentTypes.utf8)), ("_rels/.rels", Data(rels.utf8)),
                          ("ppt/presentation.xml", Data(presentation.utf8)), ("ppt/_rels/presentation.xml.rels", Data(presentationRelsXML.utf8)),
                          ("ppt/slideMasters/slideMaster1.xml", Data(master.utf8)), ("ppt/slideMasters/_rels/slideMaster1.xml.rels", Data(masterRels.utf8)),
                          ("ppt/slideLayouts/slideLayout1.xml", Data(layout.utf8)), ("ppt/slideLayouts/_rels/slideLayout1.xml.rels", Data(layoutRels.utf8)),
                          ("ppt/theme/theme1.xml", Data(theme.utf8))] + files)
    }
}

/// An Office file (Word, Excel or PowerPoint) for the save panel / Files.
struct OfficeFile: FileDocument {
    enum Kind: String { case docx, xlsx, pptx }
    static var readableContentTypes: [UTType] { [.data] }
    let kind: Kind
    let data: Data

    var contentType: UTType { UTType(filenameExtension: kind.rawValue) ?? .data }

    init?(kind: Kind, markdown: String) {
        switch kind {
        case .docx: data = DocumentExport.docx(markdown: markdown)
        case .xlsx: guard let xlsx = DocumentExport.xlsx(markdown: markdown) else { return nil }; data = xlsx
        case .pptx: data = DocumentExport.pptx(markdown: markdown)
        }
        self.kind = kind
    }

    init(configuration: ReadConfiguration) throws {
        kind = .docx
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

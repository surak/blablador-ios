import XCTest
@testable import BlabladorCore

final class DocumentTests: XCTestCase {
    func testGoogleLinks() {
        let doc = GoogleDocs.link(URL(string: "https://docs.google.com/document/d/1XzCHG9ONiNIYqx750-CxmGkOpuQI5thEvkuIwEdzoHY/edit?usp=sharing")!)
        XCTAssertEqual(doc?.kind, .document)
        XCTAssertEqual(GoogleDocs.exports(doc!).map(\.format), ["md", "txt"])
        let sheet = GoogleDocs.link(URL(string: "https://docs.google.com/spreadsheets/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789/edit#gid=42")!)
        XCTAssertEqual(sheet?.gid, "42")
        XCTAssertTrue(GoogleDocs.exports(sheet!)[0].url.absoluteString.hasSuffix("export?format=csv&gid=42"))
        XCTAssertEqual(GoogleDocs.link(URL(string: "https://docs.google.com/presentation/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789/edit")!)?.kind, .presentation)
        XCTAssertNil(GoogleDocs.link(URL(string: "https://example.org/document/d/1AbCdEfGhIjKlMnOpQrStUvWxYz0123456789")!))
    }

    private let sample = """
    # Report
    Intro with **bold**, *italic* and a [link](https://fz-juelich.de). [3][4]

    - first
    - second

    | Name | Value |
    |---|---|
    | A | 1 |

    > A quote
    """

    func testHTMLKeepsStructure() {
        let html = DocumentExport.html(markdown: sample)
        XCTAssertTrue(html.contains("<h1>Report</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<a href=\"https://fz-juelich.de\">link</a>"))
        XCTAssertFalse(html.contains("[3]"))
        XCTAssertTrue(html.contains("<ul><li>first</li><li>second</li></ul>"))
        XCTAssertTrue(html.contains("<th style=\"padding:4px 8px\">Name</th>"))
        XCTAssertTrue(html.contains("<blockquote>A quote</blockquote>"))
        XCTAssertTrue(DocumentExport.plain(markdown: sample).contains("• first"))
        XCTAssertEqual(DocumentExport.fileName(for: sample), "Report")
    }

    func testWordFileOpens() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".docx")
        try DocumentExport.docx(markdown: sample).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        // macOS reads Word files itself; if the ZIP or XML were broken this would fail.
        let text = try NSAttributedString(url: file, options: [:], documentAttributes: nil).string
        XCTAssertTrue(text.contains("Report"))
        XCTAssertTrue(text.contains("bold"))
        XCTAssertTrue(text.contains("second"))
        XCTAssertTrue(text.contains("Value"))
    }

    func testCRC() {
        XCTAssertEqual(Zip.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }
}

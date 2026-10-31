import SwiftUI
import XCTest
@testable import BlabladorCore

/// Renders views to PNG for a look (RENDER_DIR=… swift test --filter RenderPreview).
@MainActor
final class RenderPreview: XCTestCase {
    func testRender() throws {
        guard let dir = ProcessInfo.processInfo.environment["RENDER_DIR"] else { throw XCTSkip("Set RENDER_DIR") }
        func save<V: View>(_ view: V, _ name: String, size: CGSize) {
            let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).background(Color(white: 0.12)).environment(\.colorScheme, .dark))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name + ".png"))
            }
        }
        let release = WhatsNew.releases[0]
        save(VStack(alignment: .leading, spacing: 22) {
            Text("What's new in Blablador \(release.version)").font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.gradient)
            ForEach(release.items) { item in
                HStack(alignment: .top, spacing: 14) {
                    ToolIcon(name: item.icon, size: 26).font(.title2).foregroundStyle(Theme.gradient).frame(width: 34)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline)
                        Text(item.text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        if item.tryIt != nil { Label("Try it", systemImage: "arrow.right.circle.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.gradient) }
                    }
                }
            }
            Spacer()
            Text("Continue").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 48).foregroundStyle(.white).background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14))
        }.padding(24), "whatsnew", size: CGSize(width: 420, height: 760))
        let store = ChatStore()
        let panel = ToolsPanelContent(imageMode: .constant(false), videoMode: .constant(true), speechMode: .constant(false)) { _ in }
            .environmentObject(store)
        save(panel, "panel", size: CGSize(width: 440, height: 1200))
        var plan = [PlanItem(text: "Search recent HPC news", status: .done), PlanItem(text: "Read the three best articles", status: .active), PlanItem(text: "Write the summary")]
        plan[0].status = .done
        save(VStack(alignment: .leading, spacing: 12) {
            PlanCard(items: plan)
            MentionChips(mentions: Array(MentionCatalog.tools.prefix(3))) { _ in }
            MentionSuggestions(query: "") { _ in }
        }.padding(), "parts", size: CGSize(width: 440, height: 600))
    }
}

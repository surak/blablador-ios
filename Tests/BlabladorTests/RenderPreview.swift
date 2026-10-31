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
        let sample = """
        # What's new at Forschungszentrum Jülich
        *fz-juelich.de, as of 31 October 2026*

        ## This week's news

        ### Fast but accurate: a new speed record for quantum gates
        Researchers from Jülich, Aachen and Cologne performed a single-qubit operation in just **6.8 nanoseconds** with **more than 99.98 % accuracy**. Published in *Nature Communications*. [27][29][30]

        ### Jülich at European Hydrogen Week
        Jülich presented itself at the hydrogen trade fair in Brussels (26–28 October). [1]

        > Hettwer received the 2026 KlarText Prize for her article on brain development.

        ---

        - First point
        - Second point [2]
        """
        save(MarkdownText(text: sample).padding(), "markdown", size: CGSize(width: 620, height: 700))
        let doc = """
        This one is **the statutes (*estatuto*) of a Brazilian motorcycle club — “Steel Goose Moto Group”** — written in Portuguese. Here's the gist:

        **What it legally is (Cap. I)**
        - A non-profit civil association, "social and recreational", founded **7 September 1992** in Conselheiro Lafaiete, Minas Gerais; unlimited duration, unlimited members, **not registered with any official body**.
        - It's deliberately **undemocratic by design**: no obligation to hold assemblies or elections.
          - The **Founding President is "sovereign"** in choosing directors.
        - Objectives: bring bikers together, organise rides and events, promote safe riding.

        **Structure**
        1. Local units called **“Facções”** (factions), each with its own board.
        2. Central administration (Cap. III): President, Vice-President, National Director.
        """
        save(MarkdownText(text: doc).padding(), "markdown2", size: CGSize(width: 1100, height: 620))
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

import Foundation
import SwiftUI
import CryptoKit
#if os(macOS)
import AppKit
#endif

/// Checks GitHub for a newer release. The Mac app downloads it and replaces itself;
/// iPhone and iPad only point to the release, since they can't install it themselves.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    static let releasesURL = URL(string: "https://github.com/surak/blablador-ios/releases/latest")!
    private static let latestAPI = URL(string: "https://api.github.com/repos/surak/blablador-ios/releases/latest")!
    private static let checkInterval: TimeInterval = 6 * 60 * 60

    struct Release: Equatable {
        let version: String
        let page: URL
        let macZip: URL?
        let checksums: URL?
    }

    enum State: Equatable {
        case idle, downloading, installing
        case failed(String)
    }

    @Published private(set) var available: Release?
    @Published private(set) var state: State = .idle
    @AppStorage("dismissedUpdateVersion") private var dismissedVersion = ""

    private var lastCheck: Date?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var showsBanner: Bool {
        guard let available else { return false }
        return available.version != dismissedVersion || state != .idle
    }

    func dismiss() {
        if let available { dismissedVersion = available.version }
        state = .idle
    }

    /// Checks at most every few hours unless forced.
    func check(force: Bool = false) async {
        if !force, let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        var request = URLRequest(url: Self.latestAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return }
        lastCheck = Date()
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(version, than: Self.currentVersion) else {
            available = nil
            return
        }
        let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { asset -> (String, URL)? in
            guard let name = asset["name"] as? String,
                  let url = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return (name, url)
        }
        available = Release(
            version: version,
            page: page,
            macZip: assets.first { $0.0.hasSuffix("-macOS.zip") }?.1,
            checksums: assets.first { $0.0 == "SHA256SUMS.txt" }?.1
        )
        if force { dismissedVersion = "" }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

#if os(macOS)
    /// Whether the app can replace itself where it is installed.
    var canInstall: Bool {
        guard available?.macZip != nil, available?.checksums != nil else { return false }
        let bundle = Bundle.main.bundleURL
        return FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
            && FileManager.default.isWritableFile(atPath: bundle.path)
    }

    /// Downloads the zip, checks it against SHA256SUMS.txt, swaps the app bundle after quitting and relaunches.
    func install() async {
        guard let release = available, let zipURL = release.macZip, let sumsURL = release.checksums else { return }
        state = .downloading
        do {
            let (sums, _) = try await URLSession.shared.data(from: sumsURL)
            let (zip, response) = try await URLSession.shared.download(from: zipURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download failed.") }
            let expected = String(decoding: sums, as: UTF8.self).split(separator: "\n").first {
                $0.hasSuffix(zipURL.lastPathComponent)
            }?.split(separator: " ").first.map(String.init)
            let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard let expected, expected == actual else { throw UpdateError("The download doesn't match its checksum.") }

            state = .installing
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("BlabladorUpdate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            let newApp = work.appendingPathComponent("Blablador.app")
            guard let info = Bundle(url: newApp),
                  info.bundleIdentifier == Bundle.main.bundleIdentifier,
                  let newVersion = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  Self.isNewer(newVersion, than: Self.currentVersion) else {
                throw UpdateError("The download isn't a newer Blablador.")
            }
            try run("/usr/bin/codesign", ["--verify", "--deep", newApp.path])
            try relaunch(replacingWith: newApp, work: work)
        } catch {
            state = .failed((error as? UpdateError)?.message ?? error.localizedDescription)
        }
    }

    private func relaunch(replacingWith newApp: URL, work: URL) throws {
        let target = Bundle.main.bundleURL.path
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "$1" && mv "$2" "$1" && xattr -dr com.apple.quarantine "$1"
        open "$1"
        rm -rf "$3"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script, "updater", target, newApp.path, work.path]
        try process.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("Couldn't unpack the update.") }
    }
#endif

    private struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}

/// Banner above the chat when a newer version is out.
struct UpdateBanner: View {
    @ObservedObject private var updater = AppUpdater.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        // Not .task: SwiftUI cancels that whenever the chat view is rebuilt.
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .onAppear { Task { await updater.check() } }
    }

    @ViewBuilder
    private var content: some View {
        if updater.showsBanner, let release = updater.available {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Blablador \(release.version) is available")
                        .font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                action(release)
                if updater.state == .idle || isFailed {
                    Button { updater.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Hide until the next version")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
            .padding(.top, 8)
        }
    }

    private var isFailed: Bool {
        if case .failed = updater.state { return true }
        return false
    }

    private var detail: String {
        switch updater.state {
        case .downloading: return "Downloading…"
        case .installing: return "Installing, Blablador will restart…"
        case .failed(let message): return message
        case .idle:
#if os(macOS)
            return updater.canInstall ? "You have \(AppUpdater.currentVersion). Update now and Blablador restarts." : "You have \(AppUpdater.currentVersion)."
#else
            return "You have \(AppUpdater.currentVersion)."
#endif
        }
    }

    @ViewBuilder
    private func action(_ release: AppUpdater.Release) -> some View {
#if os(macOS)
        if updater.canInstall {
            switch updater.state {
            case .downloading, .installing: ProgressView().controlSize(.small)
            default: Button("Update") { Task { await updater.install() } }.buttonStyle(.borderedProminent)
            }
        } else {
            Button("Download") { openURL(release.page) }.buttonStyle(.borderedProminent)
        }
#else
        Button("What's new") { openURL(release.page) }.buttonStyle(.borderedProminent)
#endif
    }
}

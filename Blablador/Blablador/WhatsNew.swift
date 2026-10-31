import SwiftUI

/// What changed in a version, shown once after an update.
struct WhatsNewItem: Identifiable, Hashable {
    enum TryIt: Hashable { case prompt(String, mention: String?), panel, permissions, tasks }
    var id: String { title }
    let icon: String
    let title: String
    let text: String
    var tryIt: TryIt?
}

enum WhatsNew {
    static let releases: [(version: String, items: [WhatsNewItem])] = [
        ("3.3", [
            WhatsNewItem(icon: "checklist", title: "Plans and follows through",
                         text: "For bigger tasks Blablador writes a plan, ticks off each step and keeps going until it's done. Afterwards it offers to save what it did as a skill.",
                         tryIt: .prompt("Plan a weekend trip to Jülich with a budget and a packing list", mention: "plan")),
            WhatsNewItem(icon: ToolIcon.schedule, title: "Works while you're away",
                         text: "Replies keep going when you switch chats, with a notification when they're ready. Schedule prompts to run by themselves.",
                         tryIt: .prompt("Every weekday at 8, summarise the top AI news for me", mention: "schedule")),
            WhatsNewItem(icon: "calendar", title: "Your calendar and contacts",
                         text: "Ask what's on tomorrow, add an event or look up a number. Nothing is added without your OK.",
                         tryIt: .prompt("What's on my calendar this week?", mention: "device")),
            WhatsNewItem(icon: "hand.raised", title: "You decide what it may do",
                         text: "Allow, Ask or Never for each kind of tool. Every reply shows its tools, time and tokens.",
                         tryIt: .permissions),
            WhatsNewItem(icon: "at", title: "Everything one tap away",
                         text: "The + button shows attachments, tools and knowledge at a glance. Type @ to use a tool or skill for one message.",
                         tryIt: .panel)
        ])
    ]
}

struct WhatsNewView: View {
    let version: String
    let items: [WhatsNewItem]
    let onTry: (WhatsNewItem.TryIt) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 6) {
                        Image("Avatar").resizable().interpolation(.high).frame(width: 52, height: 52)
                        Text("What's new in Blablador \(version)")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(Theme.gradient)
                    }
                    .padding(.top, 8)
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: 14) {
                            ToolIcon(name: item.icon, size: 26)
                                .font(.title2)
                                .foregroundStyle(Theme.gradient)
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).scaledFont(.headline)
                                Text(item.text).scaledFont(.subheadline).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let tryIt = item.tryIt {
                                    Button { onTry(tryIt) } label: {
                                        Label("Try it", systemImage: "arrow.right.circle.fill")
                                            .scaledFont(.subheadline, weight: .semibold)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(Theme.gradient)
                                    .padding(.top, 2)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            Button(action: onClose) {
                Text("Continue")
                    .scaledFont(.body, weight: .semibold)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(.white)
                    .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .background(Theme.background)
    }
}

extension WhatsNew {
    static let seenKey = "whatsNewSeen"
    static let openPanel = Notification.Name("BlabladorOpenToolsPanel")

    /// The newest release notes not seen yet; nil on a fresh install (marked as seen) or when there's nothing new.
    @MainActor
    static func unseen(hasChats: Bool) -> (version: String, items: [WhatsNewItem])? {
        guard let newest = releases.first else { return nil }
        let defaults = UserDefaults.standard
        guard let seen = defaults.string(forKey: seenKey) else {
            if !hasChats { defaults.set(newest.version, forKey: seenKey); return nil }
            return newest
        }
        return seen.compare(newest.version, options: .numeric) == .orderedAscending ? newest : nil
    }

    static func markSeen() {
        if let newest = releases.first { UserDefaults.standard.set(newest.version, forKey: seenKey) }
    }
}

/// Opens Permissions or Scheduled tasks from What's new.
struct WhatsNewDestination: Identifiable {
    let id: String
}

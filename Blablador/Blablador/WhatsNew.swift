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
        ("3.15.0", [
            WhatsNewItem(icon: "terminal", title: "A swarm on the command line",
                         text: "In bla, /swarm TASK puts a team on it: named workers split the work and a verifier checks "
                         + "it, all talking on one shared board, each on the model its job needs. Run bla swarm in another "
                         + "terminal to watch them side by side. /model now lists every model with its context size to "
                         + "pick with the keyboard or mouse, and Clef opens the decision assistant."),
        ]),
        ("3.14.0", [
            WhatsNewItem(icon: "calendar", title: "All your calendars, changed too",
                         text: "Blablador uses the calendars of every account on your device — Google, Microsoft, iCloud, "
                         + "CalDAV — with no sign-in of its own. It can now change, move and delete events (one occurrence "
                         + "or the repeats after it), pick the calendar, set alerts and repeats, and find free time. "
                         + "Changes ask first unless you allow them in Permissions."),
        ]),
        ("3.13.3", [
            WhatsNewItem(icon: "return", title: "Enter sends again",
                         text: "The return key sends your message, as it does on the Mac app and in bla; Shift+Enter "
                         + "starts a new line instead of sending. On a phone's on-screen keyboard Return still makes "
                         + "the line, since it sends the app no key events — there the send button is the way."),
        ]),
        ("3.13.2", [
            WhatsNewItem(icon: "person", title: "Your name stays in the greeting",
                         text: "A greeting name that could not be looked up — started offline, or Codebase away — is kept "
                         + "rather than wiped, and looked up again when the app comes back to the front."),
        ]),
        ("3.13.1", [
            WhatsNewItem(icon: "eye.slash", title: "A disappearing chat where a chat is started",
                         text: "It is under New chat in the chat list, as it is on Android and the Mac app, rather than in the "
                         + "top bar, where its button left less room for the model name."),
        ]),
        ("3.13", [
            WhatsNewItem(icon: "bubble.left.and.text.bubble.right", title: "Ask something aside",
                         text: "While a long answer is being written, type /btw and a question that has nothing to do with it. "
                         + "It's answered in a card above the composer, the answer carries on undisturbed, and what was asked "
                         + "aside is kept as a chat of its own."),
            WhatsNewItem(icon: "eye.slash", title: "Chats that leave no trace",
                         text: "Under New chat in the chat list, a disappearing chat starts: nothing is saved, nothing in it is "
                         + "remembered, and it can't be found again in the history. Start another chat or close the app and "
                         + "it is gone."),
            WhatsNewItem(icon: "flag", title: "Goals that don't run out of steps",
                         text: "A reply working on a /goal now gets many more steps before it has to answer with what it has — "
                         + "1000 by default, chosen in Settings.",
                         tryIt: .prompt("/goal ", mention: nil))
        ]),
        ("3.12", [
            WhatsNewItem(icon: "waveform", title: "Talk to bla in the Terminal",
                         text: "Type /voice in bla and talk to it: it listens with Whisper, and reads the answer back with Drama 3 "
                         + "while it is still writing. Say \"stop\", or press Esc, to cut it off."),
            WhatsNewItem(icon: "paperplane", title: "bla on Telegram",
                         text: "bla serve --telegram answers in a Telegram chat: send it a message or a voice note from your phone "
                         + "and it works in the folder you started it in. Only the chats you allow, and it asks in the chat before "
                         + "anything that can't be undone.")
        ]),
        ("3.10", [
            WhatsNewItem(icon: "atom", title: "Proteins",
                         text: "Fold a sequence with ESMFold2, sample conformations with BioEmu2, design proteins with RFdiffusion3, "
                         + "or design binders with BindCraft and Proteina-Complexa. The job runs on the Jülich GPUs for minutes to "
                         + "hours — close the app and come back. In the + panel: Proteins.",
                         tryIt: .panel),
            WhatsNewItem(icon: "checkmark.seal", title: "Checks what came back",
                         text: "A folding job can finish, call itself a success and hand back a structure that no chemistry allows. "
                         + "Every result is measured against the real bonds between residues, and told plainly when it doesn't hold up.")
        ]),
        ("3.8", [
            WhatsNewItem(icon: "cube.transparent", title: "A place in 3D",
                         text: "Take photos all around a room and get a top-down map after every batch, then a 3D model you can turn. In the + panel: 3D room."),
            WhatsNewItem(icon: "terminal", title: "bla, an agent in the Terminal",
                         text: "bla is now a coding agent: it reads and edits files and runs commands, asking first, with skills, memory and /undo. Install it in Settings → Command line.")
        ]),
        ("3.6", [
            WhatsNewItem(icon: "brain", title: "Choose how hard it thinks",
                         text: "Pick Off, Low, Medium, High or Max for models that think, in the model menu or Settings. Medium is the new default, for quicker answers."),
            WhatsNewItem(icon: "text.line.first.and.arrowtriangle.forward", title: "Write while it answers",
                         text: "Send another message while a reply is still coming: it waits above the composer. Steer sends it right away, or remove it."),
            WhatsNewItem(icon: "bolt", title: "Faster long answers",
                         text: "Long replies stream smoothly and use less battery. Thinking shows just its latest line; tap it to read all of it."),
            WhatsNewItem(icon: "arrow.up.and.down", title: "Scroll while it writes",
                         text: "Scroll up to read earlier messages while a reply is written; scroll back down or tap the arrow to follow it again."),
            WhatsNewItem(icon: "terminal", title: "bla on the command line",
                         text: "On the Mac, install the bla command in Settings and ask from the Terminal: bla \"question\", or pipe text into it.")
        ]),
        ("3.5", [
            WhatsNewItem(icon: "waveform", title: "Talk with Blablador",
                         text: "Tap the waveform button and just talk, in your language. Blablador answers out loud in a Drama 3 voice, your cloned voice or the device's voice, and listens again."),
            WhatsNewItem(icon: "flag", title: "Goals",
                         text: "Type /goal and what you want, and Blablador keeps working until it's done or needs you. It checks its results before showing them.",
                         tryIt: .prompt("/goal ", mention: nil)),
            WhatsNewItem(icon: "number", title: "# for knowledge",
                         text: "Type # to answer from a knowledge base; @ is for tools, skills and connected services."),
            WhatsNewItem(icon: "plus.magnifyingglass", title: "Zoom into plots",
                         text: "Pinch or double-tap pictures and Python plots in answers to zoom in."),
            WhatsNewItem(icon: "chevron.left.forwardslash.chevron.right", title: "Coding on the Mac",
                         text: "In a folder, every file the agent changes is shown as a diff you can undo, and the agent starts with an overview of the project.")
        ]),
        ("3.4", [
            WhatsNewItem(icon: "doc.text", title: "Reads Google Docs",
                         text: "Paste a link to a Google Doc, Sheet or Slides shared by link and ask about it. No Google account needed.",
                         tryIt: .prompt("Summarise this Google Doc: ", mention: nil)),
            WhatsNewItem(icon: "square.and.arrow.up.on.square", title: "Word, Excel and PowerPoint",
                         text: "The doc button under an answer copies it into Google Docs or Word with its formatting, or saves and opens it as a document, a spreadsheet or slides."),
            WhatsNewItem(icon: "sparkles", title: "An example for everything",
                         text: "A new chat shows what Blablador can do, from Python plots to cloned voices. Tap More ideas for others."),
            WhatsNewItem(icon: "text.alignleft", title: "Cleaner answers",
                         text: "Lists, headings and paragraphs are laid out for easier reading.")
        ]),
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
    /// Runs an action of the + panel (Files, Scan text…) from elsewhere, e.g. an example on the empty chat.
    static let runPanelAction = Notification.Name("BlabladorRunPanelAction")

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

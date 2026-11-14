import Combine
import Compression
import Foundation

/// The five molecular models on Blablador (ESMFold2, BioEmu2, RFdiffusion3, BindCraft, Proteina-Complexa).
///
/// They are not chat models: a request queues work that runs for minutes to hours. Every action is a
/// `POST /responses` whose `input` is a JSON *string* holding the action, and the answer carries a
/// `molecular_job` object. The envelope completing means the API call finished, never the computation.
/// Results come back as a chunked base64 ZIP and are deleted upstream 48 hours after a job finishes.
///
/// Same protocol as the BioPortal web frontend (github.com/surak/bioportal).
enum Molecular {
    /// One chunk of a result archive, the largest the shim sends.
    static let chunkSize = 1_048_576
    /// Per API action; a job's own run is far longer.
    static let actionTimeout: TimeInterval = 60
    /// Never poll faster than this, whatever the service asks for.
    static let minimumPoll: TimeInterval = 10
    /// Results this big aren't downloaded to the device.
    static let maximumArtifact = 512 * 1024 * 1024

    enum Failure: LocalizedError {
        /// The computation is fine, our request wasn't.
        case transient(String)
        case gone
        case queueFull
        case notReady
        case rejected(String)
        case keyRejected
        case other(String)

        var errorDescription: String? {
            switch self {
            case let .transient(text): return text
            case .gone: return "The job or its result is no longer available. Results are deleted 48 hours after a job finishes."
            case .queueFull: return "The molecular queue is full. Try again shortly."
            case .notReady: return "No worker is ready for this model right now."
            case let .rejected(text): return "Rejected: \(text)"
            case .keyRejected: return "Blablador rejected your API key."
            case let .other(text): return text
            }
        }

        /// Transient failures never mean the job itself failed.
        var isTransient: Bool {
            switch self {
            case .transient, .queueFull, .notReady: return true
            default: return false
            }
        }
    }
}

// MARK: - The models

extension Molecular {
    enum Kind: String, CaseIterable, Identifiable, Codable {
        case esmfold2, bioemu2, rfdiffusion3, bindcraft, proteinaComplexa

        var id: String { rawValue }

        var alias: String {
            switch self {
            case .esmfold2: return "alias-esmfold2"
            case .bioemu2: return "alias-bioemu2"
            case .rfdiffusion3: return "alias-rfdiffusion3"
            case .bindcraft: return "alias-bindcraft"
            case .proteinaComplexa: return "alias-proteina-complexa"
            }
        }

        var name: String {
            switch self {
            case .esmfold2: return "ESMFold2"
            case .bioemu2: return "BioEmu2"
            case .rfdiffusion3: return "RFdiffusion3"
            case .bindcraft: return "BindCraft"
            case .proteinaComplexa: return "Proteina-Complexa"
            }
        }

        var blurb: String {
            switch self {
            case .esmfold2: return "Predicts a structure from one protein sequence."
            case .bioemu2: return "Samples an ensemble of conformations rather than one structure."
            case .rfdiffusion3: return "Designs new proteins, by length or from an RFD3 input object."
            case .bindcraft: return "Designs binders against a target structure and filters them."
            case .proteinaComplexa: return "NVIDIA Proteina-Complexa binder generation against a target."
            }
        }

        var symbol: String {
            switch self {
            case .esmfold2: return "atom"
            case .bioemu2: return "waveform.path.ecg"
            case .rfdiffusion3: return "sparkles"
            case .bindcraft: return "link"
            case .proteinaComplexa: return "puzzlepiece.extension"
            }
        }

        /// Caveats from the deployment, shown before the job is sent.
        var caveats: [String] {
            switch self {
            case .esmfold2:
                return ["Produces exactly one prediction."]
            case .bioemu2:
                return ["The sequence shortcut creates protein chain A.",
                        "Runs on one GPU; the multi-GPU path was not validated."]
            case .rfdiffusion3:
                return ["Unconditional design of 40–50 residues is the validated path. Other input is passed through to RFD3 unvalidated."]
            case .bindcraft:
                return ["The quality filters can accept fewer designs than you asked for: a finished run is not a guarantee of quality.",
                        "Output is not deterministic."]
            case .proteinaComplexa:
                return ["Single-pass binder generation with reward scoring disabled, not the full reward-guided pipeline."]
            }
        }

        /// The aliases that must never appear in the chat model picker.
        static var aliases: Set<String> { Set(allCases.map(\.alias)) }
    }
}

// MARK: - Validating what the user typed

extension Molecular {
    static let maximumSequence = 2000
    /// The 20 amino acids plus X for unknown.
    static let aminoAcids = Set("ACDEFGHIKLMNPQRSTVWYX")

    /// Accepts FASTA or a bare sequence and returns a bare, validated one.
    static func sequence(from raw: String) throws -> String {
        let joined = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix(">") }
            .joined()
        let sequence = joined.replacingOccurrences(of: " ", with: "").uppercased()
        guard !sequence.isEmpty else { throw Failure.other("No sequence found.") }
        let bad = Set(sequence).subtracting(aminoAcids).sorted()
        guard bad.isEmpty else {
            throw Failure.other("Not a protein sequence — unexpected characters: \(bad.map(String.init).joined(separator: ", "))")
        }
        guard sequence.count <= maximumSequence else {
            throw Failure.other("The sequence is \(sequence.count) residues; the app's limit is \(maximumSequence).")
        }
        return sequence
    }

    static func isStructure(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { $0.hasPrefix("ATOM  ") || $0.hasPrefix("HETATM") }
    }

    /// A chain and a range of residues, as the adapter wants it: A1-76, B20-140.
    static func isResidueSelection(_ text: String) -> Bool {
        text.range(of: "^[A-Za-z0-9]+[0-9]+-[0-9]+$", options: .regularExpression) != nil
    }

    static func isChains(_ text: String) -> Bool {
        text.range(of: "^[A-Za-z0-9]+(,[A-Za-z0-9]+)*$", options: .regularExpression) != nil
    }

    static func isLength(_ text: String) -> Bool {
        text.range(of: "^[0-9]+(-[0-9]+)?$", options: .regularExpression) != nil
    }

    static func isFilename(_ text: String) -> Bool {
        text.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
    }
}

// MARK: - Talking to the shim

extension Molecular {
    /// Posts one action and returns the `molecular_job` object.
    static func post(_ action: [String: Any], model: String, apiKey: String) async throws -> [String: Any] {
        guard !apiKey.isEmpty else { throw Failure.other("No API key set. Add your Blablador API key in Settings.") }
        guard let input = try? JSONSerialization.data(withJSONObject: action),
              let text = String(data: input, encoding: .utf8) else {
            throw Failure.other("Could not encode the request.")
        }
        var request = URLRequest(url: BlabladorAPI.baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.timeoutInterval = actionTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        // `input` is a JSON string, not an object, and these models never stream.
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": false, "input": text])

        let data: Data, response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // A network failure is never evidence that the computation failed.
            throw Failure.transient("Could not reach Blablador: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw failure(status: http.statusCode, body: String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        // The router can answer with an HTML gateway error and a 200, so parse defensively.
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.transient("The router did not answer with JSON.")
        }
        if let job = envelope["molecular_job"] as? [String: Any] { return job }
        if let job = jobFromOutput(envelope) { return job }
        throw Failure.other("The answer held no molecular_job object.")
    }

    /// The same object is also serialized into output[0].content[0].text.
    private static func jobFromOutput(_ envelope: [String: Any]) -> [String: Any]? {
        guard let output = envelope["output"] as? [[String: Any]],
              let content = output.first?["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func failure(status: Int, body: String) -> Failure {
        let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 404: return .gone
        case 429: return .queueFull
        case 503: return .notReady
        case 401, 403: return .keyRejected
        case 400: return .rejected(detail)
        default: return status >= 500 ? .transient("HTTP \(status). \(detail)") : .other("HTTP \(status). \(detail)")
        }
    }

    /// Submitting is safe to repeat: the shim derives a stable job id from the request id and the model, so the
    /// same request id with the same parameters returns the original job instead of starting a second computation.
    static func submit(model: String, requestID: String, parameters: [String: Any], apiKey: String) async throws -> [String: Any] {
        try await post(["action": "submit", "request_id": requestID, "parameters": parameters], model: model, apiKey: apiKey)
    }

    static func status(model: String, jobID: String, apiKey: String) async throws -> [String: Any] {
        try await post(["action": "status", "job_id": jobID], model: model, apiKey: apiKey)
    }

    static func cancel(model: String, jobID: String, apiKey: String) async throws -> [String: Any] {
        try await post(["action": "cancel", "job_id": jobID], model: model, apiKey: apiKey)
    }

    static func queue(model: String, apiKey: String) async throws -> [String: Any] {
        try await post(["action": "queue"], model: model, apiKey: apiKey)
    }

    /// Downloads the result ZIP chunk by chunk. The offset moves by the number of *decoded* bytes, never by the
    /// length of the base64 text, and the file is only kept once every byte has arrived.
    static func artifact(model: String, jobID: String, apiKey: String,
                         progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> Data {
        var data = Data()
        var total: Int?
        var attempts = 0
        while total == nil || data.count < total! {
            let chunk: [String: Any]
            do {
                chunk = try await post(["action": "artifact", "job_id": jobID, "offset": data.count, "length": chunkSize],
                                       model: model, apiKey: apiKey)
            } catch let error as Failure where error.isTransient && attempts < 5 {
                attempts += 1
                // Back off with jitter and ask for the same offset again.
                let seconds = min(30, pow(2, Double(attempts))) * (0.5 + Double.random(in: 0...0.5))
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                continue
            }
            attempts = 0
            if total == nil {
                total = (chunk["total_bytes"] as? NSNumber)?.intValue ?? 0
                guard let total, total > 0 else { throw Failure.other("The result is empty.") }
                guard total <= maximumArtifact else {
                    throw Failure.other("The result is \(total / 1_048_576) MB, over the app's \(maximumArtifact / 1_048_576) MB limit.")
                }
            }
            guard let base64 = chunk["data_base64"] as? String,
                  let piece = Data(base64Encoded: base64), !piece.isEmpty else {
                throw Failure.other("A result chunk at \(data.count) bytes could not be read.")
            }
            data += piece
            progress(data.count, total ?? 0)
            try Task.checkCancellation()
        }
        return data
    }
}

// MARK: - A job on this device

/// One submitted job. Kept on the device because the service has no job list of its own: this record is the
/// only link between the user and a job id.
struct MolecularJob: Identifiable, Codable, Hashable {
    enum State: String, Codable {
        /// Sent, but we don't know the job id yet.
        case submitting
        case queued, running, cancelling, completed, failed, cancelled
        /// Submitting failed outright; nothing is running.
        case notSubmitted

        var name: String {
            switch self {
            case .submitting: return "Submitting"
            case .queued: return "Queued"
            case .running: return "Running"
            case .cancelling: return "Cancelling"
            case .completed: return "Finished"
            case .failed: return "Failed"
            case .cancelled: return "Cancelled"
            case .notSubmitted: return "Not submitted"
            }
        }

        var isFinished: Bool { [.completed, .failed, .cancelled, .notSubmitted].contains(self) }
    }

    enum Result: String, Codable {
        case none, waiting, downloading, stored, expired, failed, tooLarge
    }

    var id = UUID()
    var kind: Molecular.Kind
    var label: String
    /// Kept so an ambiguous submission can be repeated unchanged.
    var requestID: String
    var parameters: Data
    var remoteID: String?
    var state: State = .submitting
    var stage = ""
    var message = ""
    var queuePosition: Int?
    var waitingReason = ""
    var error = ""
    var created = Date()
    var started: Date?
    var finished: Date?
    /// When the result disappears upstream. Ours stays.
    var expires: Date?
    var result: Result = .none
    var resultBytes: Int?
    /// The chat this job is written into, so it can be found again in the history.
    var chat: UUID?
    var chatMessage: UUID?
    var gpuSeconds: Double?
    /// The backbone check on the downloaded structure.
    var check: StructureCheck?
    /// Seconds the service asked us to wait before the next poll.
    var pollAfter: Double = Molecular.minimumPoll

    var parameterObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: parameters)) as? [String: Any] ?? [:]
    }

    var title: String { label.isEmpty ? kind.name : label }

    var fileName: String { "\(id.uuidString).zip" }

    var isTerminal: Bool { state.isFinished }

    /// What to say about progress. There is no percentage and no ETA: the service publishes neither.
    var progressText: String {
        if !message.isEmpty { return message }
        if !stage.isEmpty { return stage }
        switch state {
        case .queued:
            if let queuePosition { return "Queued, \(queuePosition) ahead. That is the order, not a promise of a start time." }
            return waitingReason.isEmpty ? "Queued." : waitingReason
        case .running: return "Running. The service gives no estimate of how long it will take."
        case .cancelling: return "Cancelling. The job may still finish: stopping is not immediate."
        default: return state.name
        }
    }

    /// Reads the fields the shim sends onto this record.
    mutating func apply(_ job: [String: Any]) {
        if let remote = job["id"] as? String, !remote.isEmpty { remoteID = remote }
        if let value = job["stage"] as? String { stage = value }
        if let value = job["message"] as? String { message = value }
        if let value = job["error"], !(value is NSNull) { error = String(describing: value).prefix(4000).description }
        if let usage = job["usage"] as? [String: Any], let seconds = (usage["gpu_seconds"] as? NSNumber)?.doubleValue {
            gpuSeconds = seconds
        }
        if let seconds = (job["poll_after_seconds"] as? NSNumber)?.doubleValue {
            pollAfter = Swift.max(Molecular.minimumPoll, seconds)
        }
        if let raw = job["status"] as? String, let value = State(rawValue: raw) { state = value }
        if state == .queued {
            queuePosition = (job["queue_position"] as? NSNumber)?.intValue ?? (job["model_queue_position"] as? NSNumber)?.intValue
            waitingReason = job["waiting_reason"] as? String ?? ""
        } else {
            queuePosition = nil
            waitingReason = ""
        }
        if let stamp = (job["started_at"] as? NSNumber)?.doubleValue, started == nil {
            started = Date(timeIntervalSince1970: stamp)
        }
        if let stamp = (job["completed_at"] as? NSNumber)?.doubleValue, finished == nil {
            finished = Date(timeIntervalSince1970: stamp)
        }
        if isTerminal, finished == nil { finished = Date() }
        if isTerminal, expires == nil {
            let seconds = (job["retention_seconds"] as? NSNumber)?.doubleValue ?? 48 * 3600
            expires = (finished ?? Date()).addingTimeInterval(seconds)
        }
        if state == .completed, result == .none { result = .waiting }
    }
}

// MARK: - The jobs on this device

/// Keeps the jobs (encrypted `molecular.json` and result archives in `Molecular/`), polls the ones still running
/// while the app is open, and downloads each result as soon as its job finishes — the service deletes results
/// after 48 hours, so waiting for the user to ask would lose them.
@MainActor
final class MolecularStore: ObservableObject {
    static let shared = MolecularStore()

    @Published private(set) var jobs: [MolecularJob] = []
    /// Bytes downloaded so far, per job.
    @Published private(set) var downloaded: [UUID: (Int, Int)] = [:]

    private var timer: Timer?
    private var polling: Set<UUID> = []
    private var nextPoll: [UUID: Date] = [:]
    /// Jobs are written into the history as they go, like everything else the app does.
    weak var chats: ChatStore?

    private static var folder: URL {
        let url = AppFolder.url.appendingPathComponent("Molecular", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var fileURL: URL { folder.appendingPathComponent("molecular.json") }

    private init() {
        if let data = EncryptedStorage.read(Self.fileURL), let jobs = try? JSONDecoder().decode([MolecularJob].self, from: data) {
            self.jobs = jobs
        }
    }

    var hasUnfinished: Bool { jobs.contains { !$0.isTerminal } }

    func resultURL(_ job: MolecularJob) -> URL? {
        let url = Self.folder.appendingPathComponent(job.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        EncryptedStorage.write(data, to: Self.fileURL)
    }

    /// Starts the ticker that keeps unfinished jobs moving. Safe to call again.
    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Molecular.minimumPoll, repeats: true) { _ in
            Task { @MainActor in MolecularStore.shared.tick() }
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func submit(kind: Molecular.Kind, label: String, parameters: [String: Any], apiKey: String) {
        let encoded = (try? JSONSerialization.data(withJSONObject: parameters)) ?? Data("{}".utf8)
        var job = MolecularJob(kind: kind, label: label, requestID: UUID().uuidString, parameters: encoded)
        if let chats {
            let (chat, message) = chats.startMolecularChat(title: job.title, request: Self.request(kind: kind, parameters: parameters))
            job.chat = chat
            job.chatMessage = message
        }
        jobs.insert(job, at: 0)
        persist()
        start()
        advance(job.id, apiKey: apiKey)
    }

    /// What was asked for, as the question standing in the history.
    private static func request(kind: Molecular.Kind, parameters: [String: Any]) -> String {
        var lines = ["\(kind.name): \(kind.blurb)"]
        for key in parameters.keys.sorted() {
            guard let value = parameters[key] else { continue }
            var text = String(describing: value).replacingOccurrences(of: "\n", with: " ")
            // A whole PDB or an RFD3 object would swamp the chat.
            if text.count > 200 { text = text.prefix(200) + "… (\(text.count) characters)" }
            lines.append("\(key): \(text)")
        }
        return lines.joined(separator: "\n")
    }

    /// Keeps the job's history entry in step with the job.
    private func tellTheChat(_ job: MolecularJob) {
        guard let chats, let message = job.chatMessage else { return }
        var text = "**\(job.kind.name)** — \(job.state.name.lowercased())"
        if !job.isTerminal { text += ". \(job.progressText)" }
        if let id = job.remoteID { text += "\n\nJob `\(id)`." }
        if !job.error.isEmpty { text += "\n\n\(job.error)" }
        switch job.result {
        case .stored:
            text += "\n\nThe result archive is on this device"
            if let bytes = job.resultBytes { text += " (\(bytes / 1024) KB)" }
            text += ". Open it under Proteins."
        case .expired:
            text += "\n\nThe service deleted the result before it could be downloaded."
        case .tooLarge:
            text += "\n\nThe result was too large to keep on this device."
        default:
            break
        }
        if let check = job.check { text += "\n\n\(check.text)" }
        chats.updateMolecularChat(message, text: text, finished: job.isTerminal)
    }

    func delete(_ ids: Set<UUID>) {
        for id in ids {
            if let job = jobs.first(where: { $0.id == id }) {
                EncryptedStorage.delete(Self.folder.appendingPathComponent(job.fileName))
            }
        }
        jobs.removeAll { ids.contains($0.id) }
        persist()
    }

    func cancel(_ id: UUID, apiKey: String) {
        guard let job = jobs.first(where: { $0.id == id }), let remote = job.remoteID else { return }
        Task {
            // A cancelled job can still finish; the state the service sends is what we show.
            if let answer = try? await Molecular.cancel(model: job.kind.alias, jobID: remote, apiKey: apiKey) {
                update(id) { $0.apply(answer) }
            }
        }
    }

    /// Downloads a result again, for a job whose download failed while the upstream copy still exists.
    func retryDownload(_ id: UUID, apiKey: String) {
        update(id) { $0.result = .waiting }
        advance(id, apiKey: apiKey)
    }

    private func tick() {
        let apiKey = KeychainHelper.read("apiKey") ?? ""
        guard !apiKey.isEmpty else { return }
        guard hasUnfinished || jobs.contains(where: { $0.result == .waiting }) else { return stop() }
        for job in jobs where !polling.contains(job.id) {
            if let next = nextPoll[job.id], next > Date() { continue }
            advance(job.id, apiKey: apiKey)
        }
    }

    private func update(_ id: UUID, _ change: (inout MolecularJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        persist()
        tellTheChat(jobs[index])
    }

    /// Moves one job on: submit it, ask for its status, or fetch its result.
    private func advance(_ id: UUID, apiKey: String) {
        guard let job = jobs.first(where: { $0.id == id }), !polling.contains(id) else { return }
        if job.isTerminal, job.result != .waiting { return }
        polling.insert(id)
        Task {
            defer {
                polling.remove(id)
                nextPoll[id] = Date().addingTimeInterval(jobs.first { $0.id == id }?.pollAfter ?? Molecular.minimumPoll)
            }
            do {
                if let remote = job.remoteID, !job.isTerminal {
                    let answer = try await Molecular.status(model: job.kind.alias, jobID: remote, apiKey: apiKey)
                    update(id) { $0.apply(answer) }
                } else if job.remoteID == nil, job.state == .submitting || job.state == .notSubmitted {
                    // Repeating an ambiguous submission with the same request id and parameters is safe.
                    let answer = try await Molecular.submit(model: job.kind.alias, requestID: job.requestID,
                                                            parameters: job.parameterObject, apiKey: apiKey)
                    update(id) { $0.state = .queued; $0.error = ""; $0.apply(answer) }
                }
                if jobs.first(where: { $0.id == id })?.result == .waiting { try await download(id, apiKey: apiKey) }
            } catch let error as Molecular.Failure {
                if case .gone = error, job.remoteID != nil {
                    update(id) { if $0.result != .stored { $0.result = .expired }; if !$0.isTerminal { $0.error = error.localizedDescription } }
                } else if error.isTransient {
                    // The job is unaffected; say so rather than failing it.
                    update(id) { $0.message = "Can't reach the service — your job is unaffected." }
                } else {
                    update(id) {
                        $0.error = error.localizedDescription
                        if $0.remoteID == nil { $0.state = .notSubmitted }
                        if $0.result == .waiting || $0.result == .downloading { $0.result = .failed }
                    }
                }
            } catch {
                update(id) { $0.error = error.localizedDescription }
            }
        }
    }

    private func download(_ id: UUID, apiKey: String) async throws {
        guard let job = jobs.first(where: { $0.id == id }), let remote = job.remoteID else { return }
        update(id) { $0.result = .downloading }
        downloaded[id] = (0, 0)
        defer { downloaded[id] = nil }
        do {
            let data = try await Molecular.artifact(model: job.kind.alias, jobID: remote, apiKey: apiKey) { done, total in
                Task { @MainActor in MolecularStore.shared.downloaded[id] = (done, total) }
            }
            EncryptedStorage.write(data, to: Self.folder.appendingPathComponent(job.fileName))
            // A finished job is not a sound result: measure the backbone before showing it.
            let check = StructureCheck.run(onArchive: data)
            update(id) { $0.result = .stored; $0.resultBytes = data.count; $0.check = check }
        } catch let error as Molecular.Failure {
            if case .gone = error {
                update(id) { $0.result = .expired }
            } else if error.isTransient {
                update(id) { $0.result = .waiting }
            } else if case let .other(text) = error, text.contains("over the app's") {
                update(id) { $0.result = .tooLarge; $0.error = text }
            } else {
                update(id) { $0.result = .failed; $0.error = error.localizedDescription }
            }
        }
    }
}

// MARK: - Reading the result archive

/// Just enough ZIP reading to get the structures out of a result: stored and deflated entries.
enum ZipReader {
    struct Entry {
        let name: String
        let compressed: Data
        let method: UInt16
        let size: Int
    }

    static func entries(_ data: Data) -> [Entry] {
        // Walk the local file headers; results are small enough that the central directory isn't needed.
        var entries: [Entry] = []
        var index = data.startIndex
        func le16(_ at: Int) -> Int { Int(data[at]) | Int(data[at + 1]) << 8 }
        func le32(_ at: Int) -> Int { le16(at) | le16(at + 2) << 16 }
        while index + 30 <= data.endIndex, le32(index) == 0x0403_4B50 {
            let method = UInt16(le16(index + 8))
            var compressedSize = le32(index + 18)
            var size = le32(index + 22)
            let nameLength = le16(index + 26), extraLength = le16(index + 28)
            let start = index + 30 + nameLength + extraLength
            guard start <= data.endIndex else { break }
            let name = String(data: data[(index + 30)..<(index + 30 + nameLength)], encoding: .utf8) ?? ""
            if le16(index + 6) & 0x08 != 0, compressedSize == 0 {
                // Sizes live in a trailing data descriptor; find the next header instead.
                guard let next = nextHeader(data, from: start) else { break }
                compressedSize = next - start
                size = compressedSize
            }
            let end = min(start + compressedSize, data.endIndex)
            entries.append(Entry(name: name, compressed: data[start..<end], method: method, size: size))
            index = end
            // Skip a data descriptor if one follows.
            if index + 4 <= data.endIndex, le32(index) == 0x0807_4B50 { index += 16 }
        }
        return entries
    }

    private static func nextHeader(_ data: Data, from: Int) -> Int? {
        var index = from
        while index + 4 <= data.endIndex {
            if data[index] == 0x50, data[index + 1] == 0x4B, data[index + 2] == 0x07, data[index + 3] == 0x08 { return index }
            index += 1
        }
        return nil
    }

    static func read(_ entry: Entry) -> Data? {
        let data: Data?
        switch entry.method {
        case 0: data = entry.compressed
        case 8: data = inflate(entry.compressed, expected: entry.size)
        default: return nil
        }
        guard var data else { return nil }
        if entry.name.hasSuffix(".gz") { data = gunzip(data) ?? data }
        return data
    }

    /// Raw deflate, as ZIP stores it.
    static func inflate(_ data: Data, expected: Int) -> Data? {
        decode(data, algorithm: COMPRESSION_ZLIB, expected: expected)
    }

    /// RFdiffusion3 returns its structures gzipped.
    static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else { return nil }
        var start = data.startIndex + 10
        let flags = data[data.startIndex + 3]
        if flags & 0x04 != 0, start + 2 <= data.endIndex {
            start += 2 + Int(data[start]) | Int(data[start + 1]) << 8
        }
        for bit in [0x08, 0x10] where flags & UInt8(bit) != 0 {
            while start < data.endIndex, data[start] != 0 { start += 1 }
            start += 1
        }
        if flags & 0x02 != 0 { start += 2 }
        guard start < data.endIndex else { return nil }
        // The last four bytes of a gzip file are the uncompressed size.
        let tail = data.suffix(4)
        let size = tail.reversed().reduce(0) { $0 << 8 | Int($1) }
        return decode(data[start..<(data.endIndex - 8)], algorithm: COMPRESSION_ZLIB, expected: max(size, data.count * 4))
    }

    private static func decode(_ data: Data, algorithm: compression_algorithm, expected: Int) -> Data? {
        guard !data.isEmpty else { return nil }
        var capacity = max(expected, data.count * 4) + 1024
        for _ in 0..<4 {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { buffer.deallocate() }
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(buffer, capacity, base, data.count, nil, algorithm)
            }
            if written > 0, written < capacity { return Data(bytes: buffer, count: written) }
            if written == 0 { return nil }
            capacity *= 4
        }
        return nil
    }
}

// MARK: - Is this a protein at all?

/// A cheap sanity check on a returned structure.
///
/// A job can finish, report success and hand back a well-formed PDB that is nevertheless impossible: too few
/// sampling steps produces exactly that. Covalent geometry fixes the distance between consecutive alpha carbons
/// near 3.8 Å (2.9 for cis-proline), so a chain whose neighbours sit 10 Å apart is not a folded protein.
/// Passing says the backbone is connected, not that the prediction is right.
struct StructureCheck: Codable, Hashable {
    static let minimum = 2.7
    static let maximum = 4.2
    /// Below this share of plausible bonds, something is wrong.
    static let plausibleShare = 0.9

    enum Verdict: String, Codable { case ok, implausible, unknown }

    var verdict: Verdict = .unknown
    var plausible = 0
    var bonds = 0
    var averageDistance: Double = 0
    var file = ""

    var share: Double { bonds > 0 ? Double(plausible) / Double(bonds) : 0 }

    var text: String {
        switch verdict {
        case .ok:
            return String(format: "The backbone is connected: %d of %d neighbouring alpha carbons are %.2f Å apart on average, "
                          + "as chemistry requires. This says the chain is sound, not that the prediction is right.",
                          plausible, bonds, averageDistance)
        case .implausible:
            return String(format: "This is not a physically plausible structure: only %d of %d neighbouring alpha carbons are "
                          + "bonded, averaging %.1f Å against the 3.8 Å chemistry allows. Too few sampling steps does this; "
                          + "the service reports such a job as a success.", plausible, bonds, averageDistance)
        case .unknown:
            return "No structure in the result could be measured."
        }
    }

    /// Measures the largest structure in a result archive.
    static func run(onArchive data: Data) -> StructureCheck {
        let wanted = [".pdb", ".cif", ".pdb.gz", ".cif.gz"]
        let candidates = ZipReader.entries(data)
            .filter { entry in wanted.contains { entry.name.lowercased().hasSuffix($0) } }
            .sorted { $0.size > $1.size }
        for entry in candidates {
            guard let bytes = ZipReader.read(entry), let text = String(data: bytes, encoding: .utf8) else { continue }
            var check = run(onStructure: text)
            check.file = entry.name
            if check.verdict != .unknown { return check }
        }
        return StructureCheck()
    }

    static func run(onStructure text: String) -> StructureCheck {
        let chains = Structure.alphaCarbons(text)
        var plausible = 0, bonds = 0, sum = 0.0
        for points in chains.values where points.count > 1 {
            for index in 1..<points.count {
                let step = points[index] - points[index - 1]
                let distance = (step.x * step.x + step.y * step.y + step.z * step.z).squareRoot()
                bonds += 1
                sum += Double(distance)
                if Double(distance) >= minimum && Double(distance) <= maximum { plausible += 1 }
            }
        }
        guard bonds > 0 else { return StructureCheck() }
        let share = Double(plausible) / Double(bonds)
        return StructureCheck(verdict: share >= plausibleShare ? .ok : .implausible,
                              plausible: plausible, bonds: bonds, averageDistance: sum / Double(bonds))
    }
}

// MARK: - Structures

/// Reads alpha-carbon traces out of PDB and mmCIF text. These models emit a minimal mmCIF that stricter parsers
/// reject, and predicted structures carry no HELIX or SHEET records, so the app draws the backbone itself.
enum Structure {
    struct Chain: Identifiable {
        let id: String
        let points: [SIMD3<Float>]
    }

    static func alphaCarbons(_ text: String) -> [String: [SIMD3<Float>]] {
        text.contains("_atom_site.") ? cif(text) : pdb(text)
    }

    static func chains(_ text: String) -> [Chain] {
        alphaCarbons(text).map { Chain(id: $0.key, points: $0.value) }.sorted { $0.id < $1.id }
    }

    private static func pdb(_ text: String) -> [String: [SIMD3<Float>]] {
        var chains: [String: [SIMD3<Float>]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("ATOM  ") || line.hasPrefix("HETATM") else { continue }
            let characters = Array(line)
            guard characters.count >= 54 else { continue }
            func field(_ from: Int, _ to: Int) -> String { String(characters[from..<min(to, characters.count)]).trimmingCharacters(in: .whitespaces) }
            guard field(12, 16) == "CA" else { continue }
            guard let x = Float(field(30, 38)), let y = Float(field(38, 46)), let z = Float(field(46, 54)) else { continue }
            let chain = field(21, 22).isEmpty ? "A" : field(21, 22)
            chains[chain, default: []].append(SIMD3(x, y, z))
        }
        return chains
    }

    private static func cif(_ text: String) -> [String: [SIMD3<Float>]] {
        var chains: [String: [SIMD3<Float>]] = [:]
        var columns: [String: Int] = [:]
        var inLoop = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("_atom_site.") {
                columns[String(line.dropFirst("_atom_site.".count)).components(separatedBy: .whitespaces)[0]] = columns.count
                inLoop = true
                continue
            }
            guard inLoop else { continue }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("loop_") || line.hasPrefix("_") {
                if !columns.isEmpty { break }
                continue
            }
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            func value(_ names: [String]) -> String? {
                for name in names {
                    guard let index = columns[name], index < fields.count else { continue }
                    return fields[index]
                }
                return nil
            }
            guard let atom = value(["label_atom_id", "auth_atom_id"]), atom.replacingOccurrences(of: "\"", with: "") == "CA",
                  let x = value(["Cartn_x"]).flatMap(Float.init), let y = value(["Cartn_y"]).flatMap(Float.init),
                  let z = value(["Cartn_z"]).flatMap(Float.init) else { continue }
            let chain = value(["auth_asym_id", "label_asym_id"]) ?? "A"
            chains[chain, default: []].append(SIMD3(x, y, z))
        }
        return chains
    }

    /// The structures in a result archive, largest first.
    static func files(in data: Data) -> [(name: String, text: String)] {
        let wanted = [".pdb", ".cif", ".pdb.gz", ".cif.gz"]
        return ZipReader.entries(data)
            .filter { entry in wanted.contains { entry.name.lowercased().hasSuffix($0) } }
            .sorted { $0.size > $1.size }
            .compactMap { entry in
                guard let bytes = ZipReader.read(entry), let text = String(data: bytes, encoding: .utf8) else { return nil }
                return (entry.name, text)
            }
    }
}

import SceneKit
import SwiftUI
import UniformTypeIdentifiers

/// The molecular models: pick one, fill in its form, and watch the job. Jobs run on the GPUs for minutes to
/// hours, so this screen can be closed and come back to — the work carries on without it.
struct ProteinsView: View {
    @EnvironmentObject private var store: ChatStore
    @StateObject private var jobs = MolecularStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Molecular.Kind?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Molecular.Kind.allCases) { kind in
                        Button { chosen = kind } label: {
                            HStack(spacing: 12) {
                                Image(systemName: kind.symbol)
                                    .frame(width: 26)
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.name).scaledFont(.body, weight: .medium)
                                    Text(kind.blurb).scaledFont(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text("These run on the Jülich GPUs and take minutes to hours. You can close this and come back; "
                         + "results are kept on this device.")
                }

                if !jobs.jobs.isEmpty {
                    Section("Jobs") {
                        ForEach(jobs.jobs) { job in
                            NavigationLink { JobView(job: job) } label: { JobRow(job: job) }
                        }
                        .onDelete { indexes in
                            jobs.delete(Set(indexes.map { jobs.jobs[$0].id }))
                        }
                    }
                }
            }
            .navigationTitle("Proteins")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $chosen) { kind in
                SubmitView(kind: kind).environmentObject(store)
            }
        }
        .onAppear { jobs.start() }
    }
}

private struct JobRow: View {
    let job: MolecularJob
    @StateObject private var jobs = MolecularStore.shared

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.kind.symbol).frame(width: 24).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title).scaledFont(.body, weight: .medium)
                Text(job.isTerminal ? job.state.name : job.progressText)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if !job.isTerminal || job.result == .downloading {
                ProgressView().controlSize(.small)
            } else if job.check?.verdict == .implausible {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else if job.result == .stored {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else if job.state == .failed || job.state == .notSubmitted {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Submitting

/// One form per model, with the fields, ranges and refusals the deployment calls for.
private struct SubmitView: View {
    let kind: Molecular.Kind
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var sequence = ""
    @State private var steps = 50
    @State private var loops = 3
    @State private var samples = 1
    @State private var seed = "42"
    @State private var targetPDB = ""
    @State private var targetInput = ""
    @State private var chains = "A"
    @State private var hotspots = ""
    @State private var lengthMin = 60
    @State private var lengthMax = 100
    @State private var trajectories = 100
    @State private var walltime = 24
    @State private var complexaSteps = 400
    @State private var unconditional = true
    @State private var length = "40-50"
    @State private var rfd3 = ""
    @State private var attachmentName = "target.pdb"
    @State private var showImporter = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name this run (optional)", text: $label)
                } footer: {
                    Text(kind.blurb)
                }

                switch kind {
                case .esmfold2: esmfold
                case .bioemu2: bioemu
                case .rfdiffusion3: rfdiffusion
                case .bindcraft: bindcraft
                case .proteinaComplexa: complexa
                }

                if !kind.caveats.isEmpty {
                    Section("Before you send") {
                        ForEach(kind.caveats, id: \.self) { caveat in
                            Label(caveat, systemImage: "info.circle").scaledFont(.caption)
                        }
                    }
                }

                if let problem {
                    Section { Text(problem).foregroundStyle(.red).scaledFont(.callout) }
                }
            }
            .navigationTitle(kind.name)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Send") { send() } }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.data, .text]) { result in
                guard case let .success(url) = result else { return }
                let opened = url.startAccessingSecurityScopedResource()
                defer { if opened { url.stopAccessingSecurityScopedResource() } }
                guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                    problem = "That file isn't text."
                    return
                }
                targetPDB = text
            }
        }
    }

    // MARK: forms

    @ViewBuilder private var esmfold: some View {
        Section("Sequence") {
            sequenceField
        }
        Section {
            Stepper("Loops: \(loops)", value: $loops, in: 1...8)
            Stepper("Steps: \(steps)", value: $steps, in: 1...1000, step: 5)
        } footer: {
            Text("More loops are slower and generally better. Too few steps returns a structure that is not "
                 + "physically foldable, and the service still calls that a success — below 25 steps you need at "
                 + "least 2 loops.")
        }
    }

    @ViewBuilder private var bioemu: some View {
        Section("Sequence") { sequenceField }
        Section {
            Stepper("Conformations: \(samples)", value: $samples, in: 1...128)
            TextField("Seed (optional)", text: $seed)
#if os(iOS)
                .keyboardType(.numberPad)
#endif
        }
        Section {
            Label("Single sequence, no MSA search", systemImage: "checkmark")
        } header: {
            Text("MSA mode")
        } footer: {
            Text("This deployment never contacts ColabFold. That is a scientific choice, not a shortcut: accuracy "
                 + "differs from an MSA-based run.")
        }
    }

    @ViewBuilder private var rfdiffusion: some View {
        Section {
            Picker("Input", selection: $unconditional) {
                Text("Unconditional").tag(true)
                Text("RFD3 object").tag(false)
            }
            .pickerStyle(.segmented)
            if unconditional {
                TextField("Length, e.g. 45 or 40-50", text: $length)
            } else {
                TextEditor(text: $rfd3).frame(minHeight: 140).scaledFont(.caption, design: .monospaced)
            }
            Stepper("Designs: \(samples)", value: $samples, in: 1...128)
        } footer: {
            Text(unconditional ? "Designing 40–50 residues unconditionally is the path that was validated."
                 : "A JSON object in the official RFdiffusion3 schema, not an English prompt. It can refer to an "
                 + "attached file by name.")
        }
        if !unconditional {
            Section("Attachment (optional)") {
                Button("Choose a PDB…") { showImporter = true }
                if !targetPDB.isEmpty {
                    TextField("Filename the object refers to", text: $attachmentName)
                    Text("\(targetPDB.count) characters").scaledFont(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var bindcraft: some View {
        Section("Target") {
            structureField
            TextField("Chains, e.g. A or A,B", text: $chains)
            TextField("Hotspots (optional)", text: $hotspots)
        }
        Section {
            Stepper("Shortest binder: \(lengthMin)", value: $lengthMin, in: 10...500, step: 5)
            Stepper("Longest binder: \(lengthMax)", value: $lengthMax, in: 10...500, step: 5)
            Stepper("Designs wanted: \(samples)", value: $samples, in: 1...128)
            Stepper("Trajectories at most: \(trajectories)", value: $trajectories, in: 1...10000, step: 50)
            Stepper("Stop after: \(walltime) h", value: $walltime, in: 1...24)
        } footer: {
            Text("BindCraft's own filters decide what counts as a design, so you can get fewer than you asked for.")
        }
    }

    @ViewBuilder private var complexa: some View {
        Section("Target") {
            structureField
            TextField("Selection, e.g. B20-140", text: $targetInput)
            TextField("Hotspots (optional), e.g. A30,A33", text: $hotspots)
        }
        Section {
            Stepper("Shortest binder: \(lengthMin)", value: $lengthMin, in: 10...500, step: 5)
            Stepper("Longest binder: \(lengthMax)", value: $lengthMax, in: 10...500, step: 5)
            Stepper("Designs: \(samples)", value: $samples, in: 1...128)
            Stepper("Steps: \(complexaSteps)", value: $complexaSteps, in: 1...1000, step: 25)
            TextField("Seed (optional)", text: $seed)
#if os(iOS)
                .keyboardType(.numberPad)
#endif
        } footer: {
            Text("The selection is required: the chain and residues to design against. There is no sensible default "
                 + "for your target.")
        }
    }

    @ViewBuilder private var sequenceField: some View {
        TextEditor(text: $sequence)
            .frame(minHeight: 120)
            .scaledFont(.caption, design: .monospaced)
        Text("FASTA or a bare one-letter sequence.").scaledFont(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder private var structureField: some View {
        Button("Choose a PDB file…") { showImporter = true }
        if targetPDB.isEmpty {
            TextEditor(text: $targetPDB).frame(minHeight: 100).scaledFont(.caption, design: .monospaced)
        } else {
            HStack {
                Text("\(targetPDB.split(whereSeparator: \.isNewline).count) lines loaded")
                    .scaledFont(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { targetPDB = "" }.scaledFont(.caption)
            }
        }
    }

    // MARK: sending

    private func send() {
        do {
            let parameters = try build()
            let key = KeychainHelper.read("apiKey") ?? ""
            guard !key.isEmpty else { throw Molecular.Failure.other("Add your Blablador API key in Settings first.") }
            MolecularStore.shared.submit(kind: kind, label: label, parameters: parameters, apiKey: key)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }

    private func build() throws -> [String: Any] {
        switch kind {
        case .esmfold2:
            // Measured on the service: 1 loop at 10 steps returns a backbone whose alpha carbons sit 10 Å apart,
            // against the 3.8 Å chemistry allows, and the job still reports success. Don't spend the GPU time.
            if steps < 25 && loops < 2 {
                throw Molecular.Failure.other("This many steps with one loop is known to return a structure that "
                                              + "isn't physically foldable. Use at least 25 steps, or 2 loops.")
            }
            return ["sequence": try Molecular.sequence(from: sequence), "num_loops": loops, "steps": steps]

        case .bioemu2:
            var parameters: [String: Any] = ["sequence": try Molecular.sequence(from: sequence),
                                             "samples": samples, "msa_mode": "single_sequence"]
            if let seed = Int(seed.trimmingCharacters(in: .whitespaces)) { parameters["seed"] = seed }
            return parameters

        case .rfdiffusion3:
            var parameters: [String: Any] = [:]
            if unconditional {
                guard Molecular.isLength(length) else { throw Molecular.Failure.other("Length should be like 45 or 40-50.") }
                parameters["input"] = ["api": ["length": length]]
            } else {
                guard let data = rfd3.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw Molecular.Failure.other("The RFD3 input has to be a JSON object, not an English prompt.")
                }
                parameters["input"] = object
            }
            parameters["samples"] = samples
            if !targetPDB.isEmpty {
                guard Molecular.isFilename(attachmentName) else { throw Molecular.Failure.other("That filename has characters the service won't take.") }
                parameters["files"] = [attachmentName: targetPDB]
            }
            return parameters

        case .bindcraft:
            try checkTarget()
            guard Molecular.isChains(chains) else { throw Molecular.Failure.other("Chains should be like A or A,B.") }
            guard lengthMin <= lengthMax else { throw Molecular.Failure.other("The longest binder must be at least the shortest.") }
            var parameters: [String: Any] = ["target_pdb": targetPDB, "chains": chains,
                                             "binder_length": [lengthMin, lengthMax], "samples": samples,
                                             "max_trajectories": trajectories, "walltime_seconds": walltime * 3600]
            // BindCraft takes its native hotspot string here; Complexa takes a list.
            if !hotspots.trimmingCharacters(in: .whitespaces).isEmpty { parameters["hotspots"] = hotspots }
            return parameters

        case .proteinaComplexa:
            try checkTarget()
            let selection = targetInput.trimmingCharacters(in: .whitespaces)
            // The adapter falls back to A1-76, which is the ubiquitin canary and meaningless for anything else.
            guard Molecular.isResidueSelection(selection) else {
                throw Molecular.Failure.other("A target selection is required, like B20-140.")
            }
            guard lengthMin <= lengthMax else { throw Molecular.Failure.other("The longest binder must be at least the shortest.") }
            var parameters: [String: Any] = ["target_pdb": targetPDB, "target_input": selection,
                                             "binder_length": [lengthMin, lengthMax], "samples": samples,
                                             "steps": complexaSteps]
            if let seed = Int(seed.trimmingCharacters(in: .whitespaces)) { parameters["seed"] = seed }
            let list = hotspots.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !list.isEmpty { parameters["hotspots"] = list }
            return parameters
        }
    }

    private func checkTarget() throws {
        guard Molecular.isStructure(targetPDB) else {
            throw Molecular.Failure.other("That doesn't look like a PDB structure: no ATOM lines in it.")
        }
    }
}

// MARK: - One job

private struct JobView: View {
    let job: MolecularJob
    @StateObject private var jobs = MolecularStore.shared
    @State private var sharing: URL?

    /// The live copy, since the store keeps polling while this is open.
    private var current: MolecularJob { jobs.jobs.first { $0.id == job.id } ?? job }

    var body: some View {
        List {
            Section {
                LabeledContent("Model", value: current.kind.name)
                LabeledContent("State", value: current.state.name)
                if !current.isTerminal {
                    Text(current.progressText).scaledFont(.callout).foregroundStyle(.secondary)
                }
                if let id = current.remoteID {
                    LabeledContent("Job id") { Text(id).scaledFont(.caption, design: .monospaced).textSelection(.enabled) }
                }
                LabeledContent("Started", value: current.created.formatted(date: .abbreviated, time: .shortened))
                if let finished = current.finished {
                    LabeledContent("Finished", value: finished.formatted(date: .abbreviated, time: .shortened))
                }
                if let seconds = current.gpuSeconds {
                    LabeledContent("GPU time", value: "\(Int(seconds)) s")
                }
            }

            if !current.error.isEmpty {
                Section("Problem") { Text(current.error).scaledFont(.callout) }
            }

            if let check = current.check {
                Section {
                    Label {
                        Text(check.text).scaledFont(.callout)
                    } icon: {
                        Image(systemName: check.verdict == .ok ? "checkmark.seal" : "exclamationmark.triangle.fill")
                            .foregroundStyle(check.verdict == .ok ? .green : .orange)
                    }
                } header: {
                    Text("Backbone check")
                }
            }

            resultSection

            Section {
                if !current.isTerminal, current.remoteID != nil {
                    Button("Cancel this job", role: .destructive) {
                        jobs.cancel(current.id, apiKey: KeychainHelper.read("apiKey") ?? "")
                    }
                }
                if current.result == .failed {
                    Button("Download the result again") {
                        jobs.retryDownload(current.id, apiKey: KeychainHelper.read("apiKey") ?? "")
                    }
                }
            } footer: {
                if let expires = current.expires, current.result != .stored {
                    Text("The service deletes this result \(expires.formatted(date: .abbreviated, time: .shortened)). "
                         + "The app keeps its own copy once it has downloaded it.")
                }
            }
        }
        .navigationTitle(current.title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .toolbar {
            if let url = jobs.resultURL(current) {
                ShareLink(item: EncryptedStorage.decryptedCopy(of: url))
            }
        }
    }

    @ViewBuilder private var resultSection: some View {
        switch current.result {
        case .downloading:
            Section("Result") {
                if let (done, total) = jobs.downloaded[current.id], total > 0 {
                    ProgressView(value: Double(done), total: Double(total)) {
                        Text("Downloading \(done / 1024) of \(total / 1024) KB")
                    }
                } else {
                    ProgressView()
                }
            }
        case .stored:
            if let url = jobs.resultURL(current), let data = EncryptedStorage.read(url) {
                StructureSection(data: data, bytes: current.resultBytes ?? data.count)
            }
        case .expired:
            Section("Result") {
                Text("The service deleted this result before it could be downloaded. Results live for 48 hours "
                     + "after a job finishes.")
                    .scaledFont(.callout)
            }
        case .tooLarge:
            Section("Result") { Text("The result is too large to keep on this device.").scaledFont(.callout) }
        case .failed:
            Section("Result") { Text("Downloading the result failed.").scaledFont(.callout) }
        case .waiting, .none:
            EmptyView()
        }
    }
}

/// What came back: the structures in the archive and everything else by name.
private struct StructureSection: View {
    let data: Data
    let bytes: Int
    @State private var chosen = 0

    private var structures: [(name: String, text: String)] { Structure.files(in: data) }

    var body: some View {
        Section("Result") {
            if structures.isEmpty {
                Text("No structure file in the archive.").scaledFont(.callout).foregroundStyle(.secondary)
            } else {
                if structures.count > 1 {
                    Picker("Structure", selection: $chosen) {
                        ForEach(structures.indices, id: \.self) { index in
                            Text(structures[index].name).tag(index)
                        }
                    }
                }
                let structure = structures[min(chosen, structures.count - 1)]
                let chains = Structure.chains(structure.text)
                BackboneView(chains: chains)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .listRowInsets(EdgeInsets())
                ForEach(chains) { chain in
                    LabeledContent("Chain \(chain.id)", value: "\(chain.points.count) residues")
                        .scaledFont(.caption)
                }
            }
            LabeledContent("Archive", value: "\(bytes / 1024) KB")
                .scaledFont(.caption)
        }
        Section("Files") {
            ForEach(ZipReader.entries(data).map(\.name), id: \.self) { name in
                Text(name).scaledFont(.caption, design: .monospaced)
            }
        }
    }
}

// MARK: - Drawing the backbone

/// The alpha-carbon trace, one colour per chain. Predicted structures carry no HELIX or SHEET records, so there
/// is nothing for a ribbon to follow: the backbone itself is what there is to see.
struct BackboneView {
    let chains: [Structure.Chain]

    private static let palette: [(Float, Float, Float)] = [
        (0.95, 0.69, 0.20), (0.35, 0.78, 0.98), (0.56, 0.87, 0.47),
        (0.98, 0.50, 0.45), (0.78, 0.60, 0.95), (0.45, 0.92, 0.84)
    ]

    func makeScene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = RoomMapper.NativeColor(red: 0.094, green: 0.094, blue: 0.106, alpha: 1)
        let all = chains.flatMap(\.points)
        guard !all.isEmpty else { return scene }
        let centre = all.reduce(SIMD3<Float>(repeating: 0), +) / Float(all.count)
        let radius = max(all.map { distance($0, centre) }.max() ?? 10, 1)

        for (index, chain) in chains.enumerated() where chain.points.count > 1 {
            let (red, green, blue) = Self.palette[index % Self.palette.count]
            let colour = RoomMapper.NativeColor(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: 1)
            var vertices: [SCNVector3] = []
            for point in chain.points {
                let moved = point - centre
                vertices.append(SCNVector3(moved.x, moved.y, moved.z))
            }
            // A line per bond; cheap, and it shows breaks in the chain rather than hiding them.
            let indices = (0..<Int32(vertices.count - 1)).flatMap { [$0, $0 + 1] }
            let element = SCNGeometryElement(indices: indices, primitiveType: .line)
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices)], elements: [element])
            geometry.firstMaterial?.lightingModel = .constant
            geometry.firstMaterial?.diffuse.contents = colour
            geometry.firstMaterial?.emission.contents = colour
            scene.rootNode.addChildNode(SCNNode(geometry: geometry))
        }

        let camera = SCNCamera()
        camera.zNear = Double(radius) / 100
        camera.zFar = Double(radius) * 20
        let node = SCNNode()
        node.camera = camera
        node.position = SCNVector3(0, 0, radius * 2.6)
        scene.rootNode.addChildNode(node)
        return scene
    }

    func configure(_ view: SCNView) {
        view.scene = makeScene()
        view.pointOfView = view.scene?.rootNode.childNodes.first { $0.camera != nil }
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = SCNVector3(0, 0, 0)
    }
}

/// Straight-line distance, used to frame the camera around the whole structure.
private func distance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let step = a - b
    return (step.x * step.x + step.y * step.y + step.z * step.z).squareRoot()
}

#if os(iOS)
extension BackboneView: UIViewRepresentable {
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        configure(view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}
}
#else
extension BackboneView: NSViewRepresentable {
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        configure(view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}
}
#endif

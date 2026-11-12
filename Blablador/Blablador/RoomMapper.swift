import PhotosUI
import SceneKit
import SwiftUI
import UniformTypeIdentifiers

/// The visual geometry model (`alias-visual-geometry`, VGGT-1B): photos of a place go in batches with `step`,
/// each answer has a top-down map; `finish` builds a coloured point cloud that `download` sends back in pieces.
enum RoomMapper {
    static let batchSize = 4
    static let maxSide = 1024

    /// Sessions are shared by everyone on the server, so the default name has a random end.
    static func newSessionName(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let letters = "abcdefghijklmnopqrstuvwxyz0123456789"
        return "room-" + formatter.string(from: date) + "-" + String((0..<4).map { _ in letters.randomElement()! })
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

#if os(iOS)
    typealias NativeColor = UIColor
    static func image(_ data: Data) -> Image? { UIImage(data: data).map(Image.init(uiImage:)) }
#else
    typealias NativeColor = NSColor
    static func image(_ data: Data) -> Image? { NSImage(data: data).map(Image.init(nsImage:)) }
#endif

    static func isValidSession(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }

    static func stepCommand(session: String, cameraHeight: Double?) -> String {
        guard let cameraHeight, cameraHeight > 0 else { return "step session=\(session)" }
        return "step session=\(session) camera_height_cm=\(cameraHeight)"
    }

    /// The `queue` part of every answer.
    struct Queue: Equatable {
        var aheadOnArrival = 0
        var waited: Double = 0
        var gpuBusy = false
        var waiting = 0
        var otherSessions = 0

        init(_ object: [String: Any]?) {
            guard let object else { return }
            aheadOnArrival = (object["ahead_on_arrival"] as? NSNumber)?.intValue ?? 0
            waited = (object["waited_s"] as? NSNumber)?.doubleValue ?? 0
            gpuBusy = (object["gpu_busy"] as? Bool) ?? false
            waiting = (object["waiting"] as? NSNumber)?.intValue ?? 0
            otherSessions = (object["other_sessions_active"] as? NSNumber)?.intValue ?? 0
        }

        var isBusy: Bool { gpuBusy || waiting > 0 }

        var text: String {
            if isBusy {
                return "The GPU is busy: \(waiting + (gpuBusy ? 1 : 0)) request(s) running or waiting. Your photos will wait their turn."
            }
            if otherSessions > 0 {
                return "\(otherSessions) other \(otherSessions == 1 ? "person is" : "people are") mapping right now. Sending may take a little longer."
            }
            return "Nobody else is mapping right now."
        }

        var waitedNote: String {
            waited >= 1 ? " Waited \(Int(waited.rounded())) s for \(aheadOnArrival) request(s) from others." : ""
        }
    }

    /// A point cloud from a binary little-endian PLY, y pointing down as the model writes it.
    struct PointCloud {
        var positions: [SIMD3<Float>]
        var colors: [SIMD3<Float>]

        enum ParseError: Error { case notPLY, unsupported(String) }

        init(ply data: Data) throws {
            guard let headerEnd = data.range(of: Data("end_header\n".utf8)),
                  let header = String(data: data[..<headerEnd.lowerBound], encoding: .ascii),
                  header.hasPrefix("ply") else { throw ParseError.notPLY }
            guard header.contains("format binary_little_endian") else { throw ParseError.unsupported("only binary little-endian PLY") }
            let sizes = ["char": 1, "uchar": 1, "int8": 1, "uint8": 1, "short": 2, "ushort": 2, "int16": 2, "uint16": 2,
                         "int": 4, "uint": 4, "int32": 4, "uint32": 4, "float": 4, "float32": 4, "double": 8, "float64": 8]
            var count = 0
            var offsets: [String: (offset: Int, type: String)] = [:]
            var stride = 0
            var inVertex = false
            for line in header.split(separator: "\n") {
                let words = line.split(separator: " ").map(String.init)
                if words.first == "element" {
                    inVertex = words.count == 3 && words[1] == "vertex"
                    if inVertex { count = Int(words[2]) ?? 0 }
                } else if words.first == "property", inVertex, words.count == 3 {
                    guard let size = sizes[words[1]] else { throw ParseError.unsupported("property type \(words[1])") }
                    offsets[words[2]] = (stride, words[1])
                    stride += size
                }
            }
            guard let x = offsets["x"], let y = offsets["y"], let z = offsets["z"],
                  [x, y, z].allSatisfy({ $0.type == "float" || $0.type == "float32" }) else { throw ParseError.unsupported("x, y, z must be floats") }
            let body = data[headerEnd.upperBound...]
            count = min(count, body.count / max(stride, 1))
            let color = ["red", "green", "blue"].compactMap { offsets[$0] }
            let hasColor = color.count == 3 && color.allSatisfy { $0.type == "uchar" || $0.type == "uint8" }
            var positions = [SIMD3<Float>](repeating: .zero, count: count)
            var colors = [SIMD3<Float>](repeating: SIMD3(1, 1, 1), count: count)
            body.withUnsafeBytes { raw in
                func float(_ at: Int) -> Float { Float(bitPattern: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian) }
                for i in 0..<count {
                    let base = i * stride
                    positions[i] = SIMD3(float(base + x.offset), float(base + y.offset), float(base + z.offset))
                    if hasColor {
                        colors[i] = SIMD3(Float(raw[base + color[0].offset]), Float(raw[base + color[1].offset]), Float(raw[base + color[2].offset])) / 255
                    }
                }
            }
            self.positions = positions
            self.colors = colors
        }

        /// Turned upright (y up) and centred, at most `limit` points, with the radius that holds them.
        func prepared(limit: Int) -> (positions: [SIMD3<Float>], colors: [SIMD3<Float>], radius: Float) {
            let step = max(1, (positions.count + limit - 1) / limit)
            var picked = [SIMD3<Float>]()
            var pickedColors = [SIMD3<Float>]()
            picked.reserveCapacity(positions.count / step + 1)
            for i in Swift.stride(from: 0, to: positions.count, by: step) {
                let p = positions[i]
                picked.append(SIMD3(p.x, -p.y, -p.z))
                pickedColors.append(colors[i])
            }
            guard !picked.isEmpty else { return ([], [], 1) }
            var low = picked[0], high = picked[0]
            for p in picked { low = simd_min(low, p); high = simd_max(high, p) }
            let center = (low + high) / 2
            var radius: Float = 0
            for i in picked.indices {
                picked[i] -= center
                radius = max(radius, simd_length(picked[i]))
            }
            return (picked, pickedColors, max(radius, 0.001))
        }
    }
}

/// Photos of a place in, a top-down map after each batch and a 3D model to turn at the end, like the web Room Mapper.
struct RoomMapperView: View {
    @EnvironmentObject private var store: ChatStore
    @Environment(\.dismiss) private var dismiss

    struct Photo: Identifiable {
        let id = UUID()
        var jpeg: Data
        var sent = false
    }

    @AppStorage("roomMapperSession") private var session = RoomMapper.newSessionName()
    @AppStorage("roomMapperHeight") private var height = 120.0
    @State private var photos: [Photo] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var showFiles = false
    @State private var showCamera = false
    @State private var queue: RoomMapper.Queue?
    @State private var sending = false
    @State private var sentCount = 0
    @State private var sendTotal = 0
    @State private var building = false
    @State private var message = ""
    @State private var messageIsError = false
    @State private var frames: Int?
    @State private var frontiers: Int?
    @State private var obstacle: Double?
    @State private var map: Data?
    @State private var cloud: RoomMapper.PointCloud?
    @State private var modelInfo = ""
    @State private var plyURL: URL?

    private var api: BlabladorAPI { store.api }
    private var unsent: Int { photos.filter { !$0.sent }.count }

    var body: some View {
        NavigationStack {
            Form {
                if let queue {
                    Section {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(queue.isBusy ? Color.orange : queue.otherSessions > 0 ? Color.yellow : Color.green)
                                .frame(width: 10, height: 10)
                                .opacity(queue.isBusy ? 0.6 : 1)
                            Text(queue.text).scaledFont(.callout)
                        }
                    }
                }

                Section {
                    TextField("Name", text: $session)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                    HStack {
                        Text("Camera height")
                        Spacer()
                        TextField("cm", value: $height, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
#if os(iOS)
                            .keyboardType(.decimalPad)
#endif
                        Text("cm").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Place")
                } footer: {
                    Text("How high the camera is above the floor: about 120 in your hand, about 10 on a robot car. Keep the floor in the pictures and move a little between them.")
                }

                Section {
                    Menu {
                        Button { showPicker = true } label: { Label("Photo library", systemImage: "photo.on.rectangle") }
                        Button { showCamera = true } label: { Label("Take photo", systemImage: "camera") }
                        Button { showFiles = true } label: { Label("Files", systemImage: "folder") }
                    } label: {
                        Label("Add photos", systemImage: "plus.circle")
                    }
                    if !photos.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
                            ForEach(photos) { photo in
                                thumbnail(photo)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button {
                        Task { await send() }
                    } label: {
                        HStack {
                            Spacer()
                            if sending {
                                ProgressView(value: Double(sentCount), total: Double(max(sendTotal, 1)))
                            } else {
                                Text(unsent > 0 ? "Send \(unsent) photo\(unsent == 1 ? "" : "s")" : "Send photos").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(unsent == 0 || sending || building)
                    if !message.isEmpty {
                        Text(message)
                            .scaledFont(.callout)
                            .foregroundStyle(messageIsError ? Color.red : Color.green)
                    }
                } header: {
                    Text("Photos")
                } footer: {
                    Text("Take photos all around the place, send them, and get a 3D model back. They go in batches of \(RoomMapper.batchSize), shrunk to \(RoomMapper.maxSide) pixels.")
                }

                if let frames {
                    Section("Map") {
                        HStack {
                            stat("\(frames)", "photos")
                            stat(frontiers.map(String.init) ?? "–", "unexplored edges")
                            stat(obstacle.map { "\(Int($0.rounded())) cm" } ?? "–", "obstacle ahead")
                        }
                        if let map, let image = RoomMapper.image( map) {
                            image
                                .resizable()
                                .interpolation(.none)
                                .scaledToFit()
                                .frame(maxWidth: 400)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .frame(maxWidth: .infinity)
                            Text("white floor · black obstacles · grey unknown · orange edges · blue path")
                                .scaledFont(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }
                        Button {
                            Task { await finish() }
                        } label: {
                            HStack {
                                Spacer()
                                if building { ProgressView().controlSize(.small) } else { Text("Build the 3D model").fontWeight(.semibold) }
                                Spacer()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(building || sending)
                    }
                }

                if let cloud {
                    Section {
                        PointCloudView(cloud: cloud)
                            .frame(height: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .listRowInsets(EdgeInsets())
                        Text(modelInfo).scaledFont(.caption).foregroundStyle(.secondary)
                        if let plyURL {
                            ShareLink(item: plyURL) { Label("Share PLY", systemImage: "square.and.arrow.up") }
                        }
                    } header: {
                        Text("3D model")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("3D room")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .cancellationAction) {
                    Button("New place") { reset() }.disabled(sending || building)
                }
            }
        }
#if os(macOS)
        .frame(minWidth: 520, minHeight: 640)
#endif
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 96, matching: .images)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            pickerItems = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) { add(data) }
                }
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            for url in (try? result.get()) ?? [] {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { add(data) }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { add($0) }
        }
        .task(id: session) {
            while !Task.isCancelled {
                await pollQueue()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func thumbnail(_ photo: Photo) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if let image = RoomMapper.image( photo.jpeg) {
                    image.resizable().scaledToFill()
                } else {
                    Color.gray
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if photo.sent {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, .green)
                    .padding(3)
            }
        }
        .contextMenu {
            if !photo.sent {
                Button("Remove", role: .destructive) { photos.removeAll { $0.id == photo.id } }
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack {
            Text(value).scaledFont(.title3).fontWeight(.semibold)
            Text(label).scaledFont(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func add(_ data: Data) {
        guard let jpeg = ImageStore.jpeg(from: data, maxPixelSize: RoomMapper.maxSide, quality: 0.85) else { return }
        photos.append(Photo(jpeg: jpeg))
    }

    private func say(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }

    private func checkedSession() throws -> String {
        let name = session.trimmingCharacters(in: .whitespaces)
        guard RoomMapper.isValidSession(name) else {
            throw RoomMapper.Failure("Name: use letters, digits, - and _ only")
        }
        return name
    }

    private func pollQueue() async {
        let name = session.trimmingCharacters(in: .whitespaces)
        let command = RoomMapper.isValidSession(name) ? "queue session=\(name)" : "queue"
        if let result = try? await api.visualGeometry(command) {
            queue = RoomMapper.Queue(result["queue"] as? [String: Any])
        }
    }

    private func show(_ result: [String: Any]) {
        if let q = result["queue"] as? [String: Any] { queue = RoomMapper.Queue(q) }
        frames = (result["frames"] as? NSNumber)?.intValue ?? frames ?? 0
        if let list = result["frontiers"] as? [Any] { frontiers = list.count }
        obstacle = (result["obstacle_ahead_cm"] as? NSNumber)?.doubleValue
        if let png = result["map_png"] as? String, let data = Data(base64Encoded: png) { map = data }
    }

    private func send() async {
        let todo = photos.filter { !$0.sent }.map(\.id)
        sending = true
        sendTotal = todo.count
        sentCount = 0
        defer { sending = false }
        var waited = ""
        var note: String?
        do {
            let name = try checkedSession()
            for start in stride(from: 0, to: todo.count, by: RoomMapper.batchSize) {
                let ids = Array(todo[start..<min(start + RoomMapper.batchSize, todo.count)])
                say("Sending photos \(start + 1)–\(start + ids.count) of \(todo.count)…")
                let jpegs = photos.filter { ids.contains($0.id) }.map(\.jpeg)
                let result = try await api.visualGeometry(RoomMapper.stepCommand(session: name, cameraHeight: height), photos: jpegs)
                for i in photos.indices where ids.contains(photos[i].id) { photos[i].sent = true }
                sentCount = start + ids.count
                show(result)
                if let text = result["note"] as? String { note = text }
                waited += RoomMapper.Queue(result["queue"] as? [String: Any]).waitedNote
            }
            if let note { say(note, error: true) } else { say("Sent. Add more photos, or build the 3D model." + waited) }
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    private func finish() async {
        building = true
        defer { building = false }
        say("Building the 3D model… this takes up to a minute" + (queue?.isBusy == true ? ", longer while others are using the GPU." : "."))
        do {
            let name = try checkedSession()
            let result = try await api.visualGeometry("finish session=\(name)")
            show(result)
            guard let parts = (result["parts"] as? NSNumber)?.intValue, parts > 0 else {
                throw RoomMapper.Failure((result["note"] as? String) ?? "No model came back.")
            }
            var ply = Data()
            for part in 0..<parts {
                say("Downloading the model, part \(part + 1) of \(parts)…")
                let piece = try await api.visualGeometry("download session=\(name) part=\(part)")
                guard let text = piece["data"] as? String, let data = Data(base64Encoded: text) else {
                    throw RoomMapper.Failure("Part \(part + 1) of the model came back broken.")
                }
                ply.append(data)
            }
            let parsed = try await Task.detached { try RoomMapper.PointCloud(ply: ply) }.value
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).ply")
            try ply.write(to: url)
            plyURL = url
            cloud = parsed
            let points = (result["points"] as? NSNumber)?.intValue ?? parsed.positions.count
            let used = (result["frames_used"] as? NSNumber)?.intValue ?? frames ?? 0
            modelInfo = "\(points.formatted()) points from \(used) photos"
                + ((result["units"] as? String) == "cm" ? ", in centimetres." : ". No floor found, so the size is not to scale.")
                + " Drag to turn, pinch to zoom."
            say("Done!" + RoomMapper.Queue(result["queue"] as? [String: Any]).waitedNote)
        } catch {
            say(error.localizedDescription, error: true)
        }
    }

    private func reset() {
        session = RoomMapper.newSessionName()
        photos = []
        frames = nil
        frontiers = nil
        obstacle = nil
        map = nil
        cloud = nil
        plyURL = nil
        say("")
    }
}

/// A coloured point cloud in SceneKit, turned with a finger or the mouse.
struct PointCloudView {
    let cloud: RoomMapper.PointCloud

    func makeScene() -> SCNScene {
        let (positions, colors, radius) = cloud.prepared(limit: 1_000_000)
        let scene = SCNScene()
        scene.background.contents = RoomMapper.NativeColor(red: 0.094, green: 0.094, blue: 0.106, alpha: 1)
        let vertices = positions.map { SCNVector3($0.x, $0.y, $0.z) }
        let colorData = colors.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<SIMD3<Float>>.stride)
        }
        let colorSource = SCNGeometrySource(data: colorData, semantic: .color, vectorCount: colors.count, usesFloatComponents: true,
                                            componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0,
                                            dataStride: MemoryLayout<SIMD3<Float>>.stride)
        let indices = (0..<Int32(vertices.count)).map { $0 }
        let element = SCNGeometryElement(indices: indices, primitiveType: .point)
        element.pointSize = 2
        element.minimumPointScreenSpaceRadius = 1
        element.maximumPointScreenSpaceRadius = 3
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: vertices), colorSource], elements: [element])
        geometry.firstMaterial?.lightingModel = .constant
        scene.rootNode.addChildNode(SCNNode(geometry: geometry))

        let camera = SCNCamera()
        camera.zNear = Double(radius) / 1000
        camera.zFar = Double(radius) * 20
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, radius * 0.9, radius * 1.4)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)
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

#if os(iOS)
extension PointCloudView: UIViewRepresentable {
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        configure(view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}
}
#else
extension PointCloudView: NSViewRepresentable {
    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        configure(view)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}
}
#endif

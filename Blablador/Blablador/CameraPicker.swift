#if os(iOS)
import SwiftUI
import UIKit

/// Wraps the system camera; returns JPEG data of the captured photo.
struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.9) {
                parent.onCapture(data)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif

#if os(macOS)
import AVFoundation
import SwiftUI

/// Mac camera: live preview and a capture button; returns JPEG data of the photo.
struct CameraPicker: View {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = MacCamera()

    static var isAvailable: Bool {
        !AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let message = camera.message {
                    Text(message)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    CameraPreview(session: camera.session)
                }
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if camera.devices.count > 1 {
                    Picker("Camera", selection: $camera.deviceID) {
                        ForEach(camera.devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                Button {
                    camera.capture { data in
                        onCapture(data)
                        dismiss()
                    }
                } label: {
                    Label("Take Photo", systemImage: "camera.fill")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!camera.isRunning)
            }
            .padding()
        }
        .frame(minWidth: 640, minHeight: 520)
        .task { await camera.start() }
        .onDisappear { camera.stop() }
    }
}

@MainActor
private final class MacCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    @Published var isRunning = false
    @Published var message: String?
    @Published var devices: [AVCaptureDevice] = []
    @Published var deviceID = "" {
        didSet { if oldValue != deviceID, !oldValue.isEmpty { configure() } }
    }

    private let output = AVCapturePhotoOutput()
    private var completion: ((Data) -> Void)?

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            message = "Camera access is off. Allow Blablador in System Settings → Privacy & Security → Camera."
            return
        }
        devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external], mediaType: .video, position: .unspecified).devices
        guard let device = AVCaptureDevice.default(for: .video) ?? devices.first else {
            message = "No camera found."
            return
        }
        deviceID = device.uniqueID
        configure()
    }

    private func configure() {
        guard let device = devices.first(where: { $0.uniqueID == deviceID }) ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            message = "The camera couldn't be opened."
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .photo
        session.inputs.forEach(session.removeInput)
        if session.canAddInput(input) { session.addInput(input) }
        if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        let session = session
        Task.detached {
            session.startRunning()
            await MainActor.run { self.isRunning = session.isRunning }
        }
    }

    func stop() {
        let session = session
        Task.detached { session.stopRunning() }
        isRunning = false
    }

    func capture(_ completion: @escaping (Data) -> Void) {
        self.completion = completion
        output.capturePhoto(with: AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg]), delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            if let data { self.completion?(data) } else { self.message = error?.localizedDescription ?? "The photo couldn't be taken." }
            self.completion = nil
        }
    }
}

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspect
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#endif

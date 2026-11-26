import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum Evidence {
    static func jpeg(from data: Data) throws -> Data {
        guard data.count <= 60 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: 2048,
                kCGImageSourceShouldCacheImmediately as String: true
              ] as CFDictionary) else { throw JournalFailure.attachment }
        let result = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(result as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw JournalFailure.attachment }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality as String: 0.86] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw JournalFailure.attachment }
        return result as Data
    }

    static func cameraAllowed() async -> Bool {
        if Launch.testing { return !Launch.testFlag("-deny-camera") }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.mediaTypes = [UTType.image.identifier]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void

        init(done: @escaping (UIImage?) -> Void) { self.done = done }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { done(nil) }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
    }
}

struct ShareRequest: Identifiable {
    let id = UUID()
    let items: [Any]
    var file: URL?
}

struct ActivitySheet: UIViewControllerRepresentable {
    let request: ShareRequest

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: request.items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

enum TransferFiles {
    static func read(_ url: URL) throws -> String {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= JournalCSV.maximumBytes else { throw JournalFailure.file }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= JournalCSV.maximumBytes, let text = String(data: data, encoding: .utf8)
        else { throw JournalFailure.file }
        return text
    }

    static func temporary(_ data: Data, name: String) throws -> URL {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("BragLogShares", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let files = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(date) > 86_400 {
                try? manager.removeItem(at: file)
            }
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        do { try data.write(to: url, options: .atomic) }
        catch {
            try? manager.removeItem(at: folder)
            throw error
        }
        return url
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

import Foundation
import Flutter
import Photos

/// Saves downloaded media into the system photo library.
///
/// The app downloads through the shared engine first (cookies, UA, Referer),
/// so the original bytes already exist in the sandbox. Handing Photos a file
/// URL avoids pushing a large video through the method channel in one buffer.
///
/// Only add-only permission is requested: the browser never reads the user's
/// existing library.
final class MediaBridge {
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "saveToPhotos":
            saveToPhotos(call.arguments as? [String: Any] ?? [:], result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func saveToPhotos(_ args: [String: Any],
                              result: @escaping FlutterResult) {
        guard let path = args["path"] as? String, !path.isEmpty else {
            result("error: missing path")
            return
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            result("error: file not found")
            return
        }

        let kind = (args["type"] as? String) ?? "photo"
        let resourceType: PHAssetResourceType =
            kind == "video" ? .video : .photo
        let filename = (args["filename"] as? String)
            ?? url.lastPathComponent

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { result("denied") }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = filename
                request.addResource(
                    with: resourceType,
                    fileURL: url,
                    options: options
                )
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        result("ok")
                    } else {
                        result("error: \(error?.localizedDescription ?? "save failed")")
                    }
                }
            }
        }
    }
}

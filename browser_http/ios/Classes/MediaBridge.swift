import AVFoundation
import AVKit
import CommonCrypto
import Flutter
import Photos
import UIKit

/// Media work that has to stay native: Photos import, HLS AES-128
/// decryption, TS → MP4 remuxing, playback and system share/export.
///
/// The app downloads through the shared engine first (cookies, UA, Referer),
/// so the original bytes already exist in the sandbox. Handing native code a
/// file URL avoids pushing a large video through the method channel in one
/// buffer.
///
/// Only add-only Photos permission is requested: the browser never reads the
/// user's existing library.
final class MediaBridge {
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "saveToPhotos":
            saveToPhotos(args, result: result)
        case "aesDecrypt":
            aesDecrypt(args, result: result)
        case "remuxToMp4":
            remuxToMp4(args, result: result)
        case "playFile":
            playFile(args, result: result)
        case "shareFile":
            shareFile(args, result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Photos

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

    // MARK: - HLS

    /// Decrypts one AES-128-CBC segment from an `#EXT-X-KEY` playlist.
    private func aesDecrypt(_ args: [String: Any],
                            result: @escaping FlutterResult) {
        guard let payload = args["data"] as? FlutterStandardTypedData,
              let keyData = args["key"] as? FlutterStandardTypedData,
              let ivData = args["iv"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "bad_args",
                                message: "missing data/key/iv",
                                details: nil))
            return
        }
        let data = payload.data
        let key = keyData.data
        let iv = ivData.data
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            result(FlutterError(code: "bad_args",
                                message: "AES-128 needs a 16-byte key and IV",
                                details: nil))
            return
        }
        if data.isEmpty {
            result(FlutterStandardTypedData(bytes: Data()))
            return
        }
        if let out = Self.decryptCbc(data, key: key, iv: iv, padding: true),
           !out.isEmpty {
            result(FlutterStandardTypedData(bytes: out))
            return
        }
        // A few packagers omit PKCS7 padding even though RFC 8216 asks for it.
        if let out = Self.decryptCbc(data, key: key, iv: iv, padding: false),
           !out.isEmpty {
            result(FlutterStandardTypedData(bytes: out))
            return
        }
        result(FlutterError(code: "decrypt_failed",
                            message: "AES-CBC decryption failed",
                            details: nil))
    }

    private static func decryptCbc(_ data: Data,
                                   key: Data,
                                   iv: Data,
                                   padding: Bool) -> Data? {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = out.count
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { outBytes in
            guard let outBase = outBytes.baseAddress else {
                return CCCryptorStatus(kCCMemoryFailure)
            }
            return data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(padding ? kCCOptionPKCS7Padding : 0),
                                keyBytes.baseAddress,
                                key.count,
                                ivBytes.baseAddress,
                                inBytes.baseAddress,
                                data.count,
                                outBase,
                                capacity,
                                &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(moved..<out.count)
        return out
    }

    /// Re-muxes a concatenated MPEG-TS file into an MP4 container without
    /// re-encoding. AVFoundation reads the TS demuxer through the same path
    /// it uses for HLS playback, so no third-party muxer is involved.
    private func remuxToMp4(_ args: [String: Any],
                            result: @escaping FlutterResult) {
        guard let sourcePath = args["source"] as? String,
              let destinationPath = args["destination"] as? String else {
            result("error: missing source or destination")
            return
        }
        let source = URL(fileURLWithPath: sourcePath)
        let destination = URL(fileURLWithPath: destinationPath)
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            result("error: source file not found")
            return
        }
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(
            url: source,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        asset.loadValuesAsynchronously(forKeys: ["tracks", "duration"]) {
            var error: NSError?
            let status = asset.statusOfValue(forKey: "tracks", error: &error)
            guard status == .loaded else {
                DispatchQueue.main.async {
                    result("error: 无法读取视频轨道（\(error?.localizedDescription ?? "unknown")）")
                }
                return
            }
            guard !asset.tracks(withMediaType: .video).isEmpty else {
                DispatchQueue.main.async {
                    result("error: 源文件没有视频轨道")
                }
                return
            }
            guard let session = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetPassthrough
            ) else {
                DispatchQueue.main.async {
                    result("error: 无法创建转封装任务")
                }
                return
            }
            guard session.supportedFileTypes.contains(.mp4) else {
                DispatchQueue.main.async {
                    result("error: 系统不支持 MP4 转封装")
                }
                return
            }
            session.outputURL = destination
            session.outputFileType = .mp4
            session.shouldOptimizeForNetworkUse = true
            session.exportAsynchronously {
                DispatchQueue.main.async {
                    switch session.status {
                    case .completed:
                        result("ok")
                    case .cancelled:
                        result("error: 转封装被取消")
                    default:
                        result("error: \(session.error?.localizedDescription ?? "转封装失败")")
                    }
                }
            }
        }
    }

    // MARK: - Playback + share

    private func playFile(_ args: [String: Any],
                          result: @escaping FlutterResult) {
        guard let path = args["path"] as? String,
              FileManager.default.fileExists(atPath: path) else {
            result("error: file not found")
            return
        }
        DispatchQueue.main.async {
            guard let presenter = Self.topViewController() else {
                result("error: no window to present from")
                return
            }
            try? AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback
            )
            try? AVAudioSession.sharedInstance().setActive(true)
            let player = AVPlayer(url: URL(fileURLWithPath: path))
            let controller = AVPlayerViewController()
            controller.player = player
            controller.modalPresentationStyle = .fullScreen
            presenter.present(controller, animated: true) {
                player.play()
                result("ok")
            }
        }
    }

    private func shareFile(_ args: [String: Any],
                           result: @escaping FlutterResult) {
        guard let path = args["path"] as? String,
              FileManager.default.fileExists(atPath: path) else {
            result("error: file not found")
            return
        }
        DispatchQueue.main.async {
            guard let presenter = Self.topViewController() else {
                result("error: no window to present from")
                return
            }
            let url = URL(fileURLWithPath: path)
            let controller = UIActivityViewController(
                activityItems: [url],
                applicationActivities: nil
            )
            if let popover = controller.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(
                    x: presenter.view.bounds.midX,
                    y: presenter.view.bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            presenter.present(controller, animated: true) {
                result("ok")
            }
        }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first
        let window = active?.windows.first { $0.isKeyWindow }
            ?? active?.windows.first
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }
}

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
        case "documentsPath":
            // The app process has no usable HOME, so Dart cannot build the
            // sandbox path itself. This is the one hook it needs.
            result(Self.documentsDirectory()?.path)
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

        // Two passes. The precise-timing read indexes the whole file, and a
        // stream stitched from hundreds of segments sometimes fails there
        // (PCR gaps, a PAT/PMT only in the first packet group) while the
        // cheap duration-only load reads the tracks fine.
        Self.readTracks(of: source, precise: true) { first in
            switch first {
            case .ready(let asset):
                Self.export(asset, to: destination, result: result)
            case .noVideo:
                DispatchQueue.main.async {
                    result("error: 源文件没有视频轨道")
                }
            case .unloadable(let error):
                Self.readTracks(of: source, precise: false) { second in
                    switch second {
                    case .ready(let asset):
                        Self.export(asset, to: destination, result: result)
                    case .noVideo:
                        DispatchQueue.main.async {
                            result("error: 源文件没有视频轨道")
                        }
                    case .unloadable(let retryError):
                        // The host shows this string; a bare
                        // "cannot open file" told nobody whether the bytes
                        // were the container the playlist promised.
                        DispatchQueue.main.async {
                            result("error: 无法读取视频轨道（"
                                   + Self.describe(retryError ?? error) + "）")
                        }
                    }
                }
            }
        }
    }

    private enum TrackRead {
        case ready(AVURLAsset)
        case unloadable(NSError?)
        case noVideo
    }

    private static func readTracks(of source: URL,
                                   precise: Bool,
                                   completion: @escaping (TrackRead) -> Void) {
        let asset = AVURLAsset(
            url: source,
            options: precise
                ? [AVURLAssetPreferPreciseDurationAndTimingKey: true]
                : [:]
        )
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            var error: NSError?
            if asset.statusOfValue(forKey: "tracks", error: &error) != .loaded {
                completion(.unloadable(error))
                return
            }
            if asset.tracks(withMediaType: .video).isEmpty {
                completion(.noVideo)
                return
            }
            completion(.ready(asset))
        }
    }

    private static func describe(_ error: NSError?) -> String {
        guard let error else { return "未知错误" }
        return "\(error.domain) \(error.code) · \(error.localizedDescription)"
    }

    private static func export(_ asset: AVURLAsset,
                               to destination: URL,
                               result: @escaping FlutterResult) {
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
                    result("error: \(Self.describe(session.error))")
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
            // .playback keeps audio alive when the app is backgrounded (the
            // Info.plist audio background mode has to be present as well).
            try? AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback
            )
            try? AVAudioSession.sharedInstance().setActive(true)
            let player = AVPlayer(url: URL(fileURLWithPath: path))
            let controller = AVPlayerViewController()
            controller.player = player
            controller.modalPresentationStyle = .fullScreen
            controller.allowsPictureInPicturePlayback = true
            if #available(iOS 14.2, *) {
                controller.canStartPictureInPictureAutomaticallyFromInline = true
            }
            if #available(iOS 16.0, *) {
                // Adds the native speed menu to the transport controls.
                controller.speeds = Self.playbackSpeeds.map {
                    AVPlaybackSpeed(rate: $0, localizedName: Self.speedTitle($0))
                }
            } else {
                // iOS 15 has no speed menu; a small overlay button stands in.
                controller.loadViewIfNeeded()
                Self.attachSpeedButton(to: controller, player: player)
            }
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

    // MARK: - Sandbox + playback helpers

    private static func documentsDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first
    }

    private static let playbackSpeeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    private static func speedTitle(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate)×"
    }

    /// iOS 15 fallback: AVPlayerViewController only grew a speed menu in 16.
    private static func attachSpeedButton(to controller: AVPlayerViewController,
                                          player: AVPlayer) {
        guard let overlay = controller.contentOverlayView else { return }
        var config = UIButton.Configuration.filled()
        config.title = speedTitle(1)
        config.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        config.baseForegroundColor = .white
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 5,
            leading: 12,
            bottom: 5,
            trailing: 12
        )
        let button = UIButton(configuration: config)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.showsMenuAsPrimaryAction = true
        button.menu = makeSpeedMenu(player: player, button: button)
        overlay.addSubview(button)
        let safe = overlay.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(
                equalTo: safe.trailingAnchor,
                constant: -16
            ),
            button.topAnchor.constraint(
                equalTo: safe.topAnchor,
                constant: 14
            ),
        ])
    }

    private static func makeSpeedMenu(player: AVPlayer,
                                      button: UIButton) -> UIMenu {
        let actions: [UIMenuElement] = playbackSpeeds.map { rate in
            return UIAction(title: speedTitle(rate)) { [weak button] _ in
                guard let button else { return }
                // AVPlayer.defaultRate only exists on iOS 16, so on this
                // legacy path picking a speed also resumes playback — which
                // is what the tap means anyway.
                player.rate = rate
                var config = button.configuration
                config?.title = speedTitle(rate)
                button.configuration = config
                button.menu = makeSpeedMenu(player: player, button: button)
            }
        }
        return UIMenu(title: "播放速度", children: actions)
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

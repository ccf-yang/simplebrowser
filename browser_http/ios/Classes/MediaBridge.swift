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
    ///
    /// A stream stitched from hundreds of segments is rarely clean: one CDN
    /// error page, one truncated last segment, or one oversized write shifts
    /// the 188-byte packet grid, and MediaToolbox then reports the *whole*
    /// file as unopenable. So the order is: read the packets themselves, try
    /// the export, and if that fails try once more on a copy with the
    /// off-grid bytes dropped. Whatever those passes learn goes into the one
    /// line the app shows, because "Cannot open MPEG TS" on its own is
    /// something nobody can act on.
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

        // Reading three hundred megabytes packet by packet, and possibly
        // rewriting them, must not happen on the platform thread.
        let reply: (String) -> Void = { outcome in
            DispatchQueue.main.async { result(outcome) }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            Self.remux(source: source, destination: destination, reply: reply)
        }
    }

    private static func remux(source: URL,
                              destination: URL,
                              reply: @escaping (String) -> Void) {
        let probe = Self.probeTs(url: source)
        Self.openAndExport(source: source, destination: destination) { first in
            switch first {
            case .ok:
                Self.verify(destination: destination) { note in
                    reply(note == nil ? "ok" : "ok: \(note!)")
                }
            case .failed(let reason):
                switch Self.repairedCopy(of: source, probe: probe) {
                case .wrote(let path, let skipped):
                    let repaired = URL(fileURLWithPath: path)
                    let staging = Self.sibling(of: source, named: "fixed.mp4")
                    Self.openAndExport(source: repaired,
                                       destination: staging) { second in
                        try? FileManager.default.removeItem(at: repaired)
                        switch second {
                        case .ok:
                            do {
                                try FileManager.default.moveItem(at: staging,
                                                                 to: destination)
                                let note = "已丢弃失步数据 "
                                    + Self.megabytes(skipped)
                                    + "（" + probe.breakNote + "）"
                                Self.verify(destination: destination) { check in
                                    reply("ok: " + [note, check]
                                        .compactMap { $0 }
                                        .joined(separator: "；"))
                                }
                            } catch {
                                try? FileManager.default.removeItem(at: staging)
                                reply("error: 修复结果写入失败（\(Self.describe(error))）")
                            }
                        case .failed(let retryReason):
                            try? FileManager.default.removeItem(at: staging)
                            reply("error: \(retryReason)（\(probe.summary)）")
                        }
                    }
                case .refused(let why):
                    reply("error: \(reason)（\(probe.summary)；修复：\(why)）")
                }
            }
        }
    }

    /// A hidden sibling file, so an interrupted repair never shows up in the
    /// offline library, which skips names starting with a dot.
    private static func sibling(of url: URL, named name: String) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent("." + url.lastPathComponent + "." + name)
    }

    /// The export reports success on a file MediaToolbox cannot read back, so
    /// the MP4 is re-opened before the app is told it worked. A nil answer
    /// means the file is good; a string is what went wrong.
    private static func verify(destination: URL,
                               completion: @escaping (String?) -> Void) {
        Self.readTracks(of: destination, precise: false) { read in
            switch read {
            case .ready(let asset):
                let duration = CMTimeGetSeconds(asset.duration)
                let hasVideo = !asset.tracks(withMediaType: .video).isEmpty
                if !hasVideo {
                    completion("转出的文件没有视频轨道")
                } else if duration.isNaN || duration <= 0.1 {
                    completion("转出的文件读不到时长，可能不完整")
                } else {
                    completion(nil)
                }
            case .noVideo:
                completion("转出的文件没有视频轨道")
            case .unloadable(let error):
                completion("转出的文件读不出来（\(Self.describe(error))）")
            }
        }
    }

    private enum OpenOutcome {
        case ok
        case failed(String)
    }

    private static func openAndExport(source: URL,
                                      destination: URL,
                                      completion: @escaping (OpenOutcome) -> Void) {
        // Two passes. The precise-timing read indexes the whole file, and a
        // stream stitched from hundreds of segments sometimes fails there
        // (PCR gaps, a PAT/PMT only in the first packet group) while the
        // cheap duration-only load reads the tracks fine.
        readTracks(of: source, precise: true) { first in
            switch first {
            case .ready(let asset):
                export(asset, to: destination, completion: completion)
            case .noVideo:
                completion(.failed("源文件没有视频轨道"))
            case .unloadable(let error):
                readTracks(of: source, precise: false) { second in
                    switch second {
                    case .ready(let asset):
                        export(asset, to: destination, completion: completion)
                    case .noVideo:
                        completion(.failed("源文件没有视频轨道"))
                    case .unloadable(let retryError):
                        completion(.failed("无法读取视频轨道（"
                                           + Self.describe(retryError ?? error)
                                           + "）"))
                    }
                }
            }
        }
    }

    // MARK: - TS inspection

    /// What the bytes of a concatenated stream actually are. The playlist is
    /// not evidence: several CDNs put fMP4 behind a `.ts` name, drop the PSI
    /// tables, or answer one request out of three hundred with an HTML page.
    private struct TsProbe {
        var size = 0
        var stride = 0
        var headHex = ""
        var packets = 0
        var syncBreaks = 0
        var firstBreakAt = -1
        var hasPat = false
        var patPid = -1
        var hasPmt = false
        var pmtBytes = [UInt8]()
        var streamTypes: [Int] = []
        var pcrPackets = 0
        var pesPackets = 0
        var pids: [Int] = []

        var broken: Bool { syncBreaks > 0 }

        /// A shifted grid makes every following packet look broken, so this
        /// counts mismatches rather than damage: the offset of the first one is
        /// the part that actually locates the bad segment.
        var breakNote: String {
            guard broken else { return "" }
            return "首个失步包在 \(MediaBridge.megabytes(firstBreakAt))，其后 \(syncBreaks) 处对不上"
        }

        var summary: String {
            guard stride > 0 else {
                return "不是 MPEG-TS 网格，开头 \(headHex)"
            }
            var parts = [
                "\(packets) 个 \(stride)B 包",
                hasPat ? (patPid >= 0 ? "PAT ✓ PMT \(patPid)" : "PAT ✓ 无 PMT") : "无 PAT",
                pcrPackets > 0 ? "PCR ✓" : "无 PCR",
            ]
            if hasPmt {
                parts.append(streamTypes.isEmpty
                    ? "PMT 无流"
                    : "流类型 " + streamTypes
                        .map { String(format: "0x%02X", $0) }
                        .joined(separator: ","))
            } else if pids.count > 1 {
                // No PSI to point at the tracks: the PID list is the next
                // best clue about what kind of stream this is.
                parts.append("PID " + pids
                    .map { String(format: "0x%X", $0) }
                    .joined(separator: ","))
            }
            if broken { parts.append(breakNote) }
            return parts.joined(separator: " · ")
        }
    }

    /// Sizes in the unit a person reads them in: a break 18 KB into a file is
    /// not "0.0 MB".
    private static func megabytes(_ bytes: Int) -> String {
        if bytes < 0 { return "未知" }
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1 << 20 {
            let kb = Double(bytes) / 1024
            return kb < 10
                ? String(format: "%.1f KB", kb)
                : String(format: "%.0f KB", kb)
        }
        return String(format: "%.1f MB", Double(bytes) / 1_048_576)
    }

    /// Packet sizes seen in the wild: plain TS, TS with a 4-byte timestamp,
    /// and the 204/208 variants some broadcasters use.
    private static let tsStrides = [188, 192, 204, 208, 194]

    /// The stride whose packets all start with the sync byte, or 0.
    private static func tsStride(of head: [UInt8]) -> Int {
        guard head.count > 4, head[0] == 0x47 else { return 0 }
        for stride in tsStrides where head.count > stride * 3 {
            if head[stride] == 0x47,
               head[stride * 2] == 0x47,
               head[stride * 3] == 0x47 {
                return stride
            }
        }
        return 0
    }

    /// Walks the file packet by packet. Streaming, because these files run to
    /// hundreds of megabytes and the answer is a handful of counters.
    private static func probeTs(url: URL) -> TsProbe {
        var probe = TsProbe()
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        probe.size = (attributes?[.size] as? NSNumber).map { Int(truncating: $0) } ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            probe.headHex = "读不到文件"
            return probe
        }
        defer { try? handle.close() }

        let head = (try? handle.read(
            upToCount: min(max(probe.size, 1), 1 << 16))) ?? Data()
        let headBytes = Array(head)
        probe.stride = tsStride(of: headBytes)
        probe.headHex = headBytes.prefix(8)
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
        guard probe.stride > 0 else { return probe }

        try? handle.seek(toOffset: 0)
        var carry = [UInt8]()
        var absolute = 0
        var done = false
        while !done {
            guard let chunk = try? handle.read(upToCount: 1 << 19) else { break }
            if chunk.isEmpty { break }
            var buffer = carry
            buffer.append(contentsOf: chunk)
            carry = []
            var off = 0
            let stride = probe.stride
            while off + stride <= buffer.count {
                inspectPacket(buffer, off, absolute + off, &probe)
                off += stride
            }
            if off < buffer.count {
                carry = Array(buffer[off..<buffer.count])
            }
            absolute += off
            done = chunk.count < (1 << 19)
        }
        return probe
    }

    private static func inspectPacket(_ buffer: [UInt8],
                                      _ off: Int,
                                      _ at: Int,
                                      _ probe: inout TsProbe) {
        let stride = probe.stride
        guard buffer[off] == 0x47 else {
            if probe.firstBreakAt < 0 { probe.firstBreakAt = at }
            probe.syncBreaks += 1
            return
        }
        probe.packets += 1

        let second = buffer[off + 1]
        let third = buffer[off + 2]
        let fourth = buffer[off + 3]
        let pusi = (second & 0x40) != 0
        let pid = (Int(second & 0x1F) << 8) | Int(third)
        let adaptation = Int((fourth >> 4) & 3)
        if probe.pids.count < 12, !probe.pids.contains(pid) {
            probe.pids.append(pid)
        }

        var payload = off + 4
        if adaptation >= 2 {
            let length = Int(buffer[payload])
            if length > 0 {
                let flags = buffer[payload + 1]
                if (flags & 0x40) != 0 { probe.pcrPackets += 1 }
            }
            payload += 1 + length
        }
        if pusi { probe.pesPackets += 1 }
        guard adaptation != 0, payload + 1 < off + stride else { return }

        let pointer = Int(buffer[payload])
        let section = payload + 1 + pointer
        guard section + 2 < off + stride else { return }
        let sectionLength = (Int(buffer[section + 1] & 0x0F) << 8)
            | Int(buffer[section + 2])

        if pid == 0, !probe.hasPat, buffer[section] == 0x00 {
            probe.hasPat = true
            // After the three-byte header: transport stream id (2), status (1),
            // section number (1), last section number (1), four bytes per
            // program, then CRC32 — all of it counted by `sectionLength`.
            let entries = (sectionLength - 9) / 4
            guard entries > 0,
                  section + 11 + (entries - 1) * 4 < off + stride else { return }
            for index in 0..<entries {
                let base = section + 10 + index * 4
                let found = (Int(buffer[base] & 0x1F) << 8) | Int(buffer[base + 1])
                if found > 0 {
                    probe.patPid = found
                    return
                }
            }
            return
        }

        guard pid == probe.patPid, !probe.hasPmt else { return }
        // A section that never finishes is not worth chasing across the file.
        guard probe.pmtBytes.count < 8192 else { return }
        if pusi { probe.pmtBytes = Array(buffer[section..<off + stride]) }
        else if !probe.pmtBytes.isEmpty {
            probe.pmtBytes.append(contentsOf: buffer[payload..<(off + stride)])
        }
        let needed = 3 + sectionLength
        // 13 bytes is the fixed part of a PMT before any stream entry; anything
        // shorter is not a PMT no matter which PID it arrived on.
        guard needed >= 13, probe.pmtBytes.count >= needed,
              probe.pmtBytes[0] == 0x02 else { return }

        probe.hasPmt = true
        // program_number (2), status (1), section numbers (2), PCR pid (2),
        // then the program info length; the stream list follows it.
        let programInfo = ((Int(probe.pmtBytes[10] & 0x0F) << 8)
            | Int(probe.pmtBytes[11]))
        var cursor = 12 + programInfo
        let stop = needed - 4
        while cursor + 4 < stop {
            let type = Int(probe.pmtBytes[cursor])
            if !probe.streamTypes.contains(type) {
                probe.streamTypes.append(type)
            }
            let descriptor = ((Int(probe.pmtBytes[cursor + 3] & 0x0F) << 8)
                | Int(probe.pmtBytes[cursor + 4]))
            cursor += 5 + descriptor
        }
    }

    /// Rewrites the stream with the off-grid bytes removed: copy packets while
    /// the sync byte holds, and when it does, skip forward until four packets
    /// in a row line up again. A trailing block that never resyncs — the usual
    /// result of one truncated segment — is dropped.
    private enum Repair {
        case wrote(path: String, skipped: Int)
        case refused(String)
    }

    /// The repair file is as large as the source, so this refuses to run
    /// unless the device has room for another copy.
    private static func repairedCopy(of source: URL,
                                     probe: TsProbe) -> Repair {
        guard probe.stride > 0 else { return .refused("开头就不是 MPEG-TS") }
        guard probe.broken else {
            return .refused("数据包都在网格上，没有可跳过的坏字节")
        }
        let free = (try? FileManager.default.attributesOfFileSystem(
            forPath: source.deletingLastPathComponent().path))
            .flatMap { $0[.systemFreeSize] as? NSNumber }
            .map { Int(truncating: $0) } ?? 0
        guard free > probe.size + (256 << 20) else {
            return .refused("磁盘剩余空间不够再写一份")
        }

        let stride = probe.stride
        let destination = sibling(of: source, named: "repair")
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let input = try? FileHandle(forReadingFrom: source),
              let output = try? FileHandle(forWritingTo: destination) else {
            try? FileManager.default.removeItem(at: destination)
            return .refused("打不开修复用的临时文件")
        }
        defer {
            try? input.close()
            try? output.close()
        }

        let chunk = 1 << 19
        let window = chunk + stride * 8
        var buffer = [UInt8]()
        var position = 0
        var out = Data()
        var skipped = 0
        var endOfFile = false
        var wroteAnything = false

        while true {
            if buffer.count - position < window, !endOfFile {
                if position > 0 {
                    buffer.removeFirst(position)
                    position = 0
                }
                let next = (try? input.read(upToCount: chunk)) ?? Data()
                if next.isEmpty {
                    endOfFile = true
                } else {
                    buffer.append(contentsOf: next)
                }
                continue
            }
            if position >= buffer.count { break }

            if buffer[position] == 0x47,
               position + stride <= buffer.count,
               alignedAfter(buffer, position, stride, 3, endOfFile) {
                out.append(contentsOf: buffer[position..<(position + stride)])
                position += stride
            } else {
                skipped += 1
                position += 1
                // More than a third of the file is not on the grid: this is
                // not one bad segment, and copying half a gigabyte of junk
                // out of a stream that will still be refused is pointless.
                if probe.size > 0, skipped * 3 > probe.size {
                    out.removeAll(keepingCapacity: true)
                    try? FileManager.default.removeItem(at: destination)
                    return .refused("失步范围太大，跳过修复")
                }
            }
            if out.count >= (1 << 18) {
                output.write(out)
                out.removeAll(keepingCapacity: true)
                wroteAnything = true
            }
        }
        if !out.isEmpty {
            output.write(out)
            wroteAnything = true
        }

        let written = ((try? FileManager.default.attributesOfItem(
            atPath: destination.path))?[.size] as? NSNumber)
            .map { Int(truncating: $0) } ?? 0
        // Less than two thirds survived, or as much was dropped as junk: the
        // file cannot be salvaged by resyncing, and a half video is harder to
        // explain than a failed export.
        guard wroteAnything,
              Double(written) >= Double(probe.size) * 0.66,
              Double(skipped) <= Double(probe.size) * 0.34 else {
            try? FileManager.default.removeItem(at: destination)
            return .refused("失步范围太大，跳过修复")
        }
        return .wrote(path: destination.path, skipped: skipped)
    }

    /// True when the next `count` packets after this one start with the sync
    /// byte, which is what separates a real packet from a stray 0x47 inside an
    /// HTML error page. At the end of the file there is nothing left to
    /// disagree with, so the last packets are taken at their word — dropping
    /// them because the buffer ran short would cut the video off early.
    private static func alignedAfter(_ buffer: [UInt8],
                                     _ position: Int,
                                     _ stride: Int,
                                     _ count: Int,
                                     _ atEnd: Bool) -> Bool {
        for index in 1...count {
            let at = position + index * stride
            if at >= buffer.count { return atEnd }
            if buffer[at] != 0x47 { return false }
        }
        return true
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

    private static func describe(_ error: (any Error)?) -> String {
        guard let error else { return "未知错误" }
        let bridged = error as NSError
        return "\(bridged.domain) \(bridged.code) · \(bridged.localizedDescription)"
    }

    private static func export(_ asset: AVURLAsset,
                               to destination: URL,
                               completion: @escaping (OpenOutcome) -> Void) {
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetPassthrough
        ) else {
            completion(.failed("无法创建转封装任务"))
            return
        }
        guard session.supportedFileTypes.contains(.mp4) else {
            completion(.failed("系统不支持 MP4 转封装"))
            return
        }
        session.outputURL = destination
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        session.exportAsynchronously {
            switch session.status {
            case .completed:
                completion(.ok)
            case .cancelled:
                completion(.failed("转封装被取消"))
            default:
                completion(.failed(Self.describe(session.error)))
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

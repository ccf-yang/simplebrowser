import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation

/// Turns one concatenated MPEG-2 Transport Stream into an MP4 without
/// re-encoding anything.
///
/// This exists because AVFoundation's transport-stream importer is a Mac
/// component. The same bytes load on macOS (`video=1 audio=1`, and
/// `AVAssetExportSession` writes an MP4) while iOS answers
/// `AVFoundationErrorDomain -11828 · Cannot Open` for every file the HLS
/// downloader writes, and the iOS Simulator reproduces that even for a stream
/// freshly muxed by ffmpeg. So the container work happens here instead: walk
/// the 188-byte packets, read PAT → PMT → PES, rewrite H.264/HEVC start codes
/// into the four-byte lengths MP4 wants, drop the ADTS headers off AAC frames,
/// and hand the compressed samples to `AVAssetWriter` with no output settings,
/// so nothing is decoded.
///
/// The walk resyncs on its own. A stream stitched from hundreds of HTTP
/// requests picks up stray bytes wherever a CDN answered one packet short, and
/// those bytes belong to no packet at all: they are counted and skipped. That
/// also drops the old requirement to fit a second copy of a 500 MB file on
/// disk before anything could be repaired.
enum TsToMp4 {

    struct Summary {
        /// Elementary-stream samples written to each track.
        let videoSamples: Int
        let audioSamples: Int
        /// Bytes discarded because they sat between two packet boundaries.
        let skippedBytes: Int
        /// Length of the video track, in seconds.
        let seconds: Double
        /// What the program map declared, for the line the app shows when the
        /// result needs explaining.
        let trackNote: String
    }

    struct Failure: Error {
        let message: String
    }

    /// Packet sizes in the wild: plain TS plus the 4-byte timestamp and the
    /// 204/208 FEC variants some packagers ship. All of them start with the
    /// same 188-byte packet.
    static let strideCandidates = [188, 192, 204, 208, 194]

    /// The 33-bit presentation clock, and its wrap point.
    static let timescale = 90_000
    static let clockSpan = Int64(1) << 33

    // MARK: - Entry

    static func convert(source: URL, destination: URL) throws -> Summary {
        // The writer truncates its destination on the first sample. Writing
        // over the only copy of a stream nobody else can open would lose the
        // download outright, so the two paths have to differ.
        guard source.absoluteURL.path != destination.absoluteURL.path else {
            throw Failure(message: "目标和源文件是同一个路径")
        }
        // Long GOP streams can go minutes before their first SPS, so the first
        // look is deliberately impatient: tables and timestamps out of the
        // front of the file, and a placeholder format description if no
        // parameter set turned up. Only when that happens does the whole file
        // get read looking for one.
        var layout = try inspect(source, stopAfter: 8 << 20, patient: false)
        if !layout.hasParameterSets {
            layout = try inspect(source, stopAfter: 0, patient: true)
        }

        let writer = try AVAssetWriter(outputURL: destination.absoluteURL,
                                       fileType: .mp4)
        // No `shouldOptimizeForNetworkUse`: laying the index out in front costs
        // a pass over every sample, and the chunk offsets are only worth
        // something to a reader that asks for the file over HTTP. This one is
        // played from the library it was written into.

        var videoInput: AVAssetWriterInput?
        var audioInput: AVAssetWriterInput?
        if let description = layout.videoDescription {
            let input = AVAssetWriterInput(mediaType: .video,
                                           outputSettings: nil,
                                           sourceFormatHint: description)
            guard writer.canAdd(input) else {
                throw Failure(message: "视频格式写不进 MP4（\(layout.videoKind)）")
            }
            writer.add(input)
            videoInput = input
        }
        if let description = layout.audioDescription {
            let input = AVAssetWriterInput(mediaType: .audio,
                                           outputSettings: nil,
                                           sourceFormatHint: description)
            guard writer.canAdd(input) else {
                throw Failure(message: "音频格式写不进 MP4（\(layout.audioKind)）")
            }
            writer.add(input)
            audioInput = input
        }
        guard writer.startWriting() else {
            throw Failure(message: "写入器启动失败（\(describe(writer.error))）")
        }
        writer.startSession(atSourceTime: .zero)

        let state = mux(source: source, layout: layout,
                        videoInput: videoInput, audioInput: audioInput,
                        writer: writer)
        if state.aborted {
            throw Failure(message: state.error ?? "写入中断")
        }
        guard state.videoSamples > 0 else {
            throw Failure(message: state.error
                ?? "一条视频样本都没写出来（\(layout.trackNote)）")
        }

        state.close(video: true)
        state.close(video: false)
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw Failure(message: "写入收尾失败（\(describe(writer.error))）"
                + "，已写 \(state.videoSamples) 帧视频")
        }
        return Summary(videoSamples: state.videoSamples,
                       audioSamples: state.audioSamples,
                       skippedBytes: layout.skippedBytes + state.skippedBytes,
                       seconds: state.seconds,
                       trackNote: layout.trackNote)
    }

    // MARK: - What the stream holds

    /// Everything the writer needs before its first sample: the PIDs to read,
    /// both format descriptions, the packet stride, and the two starting
    /// timestamps that line the tracks up against each other.
    struct Layout {
        var stride = 188
        var hevc = false
        var videoPid = -1
        var audioPid = -1
        var videoDescription: CMFormatDescription?
        var audioDescription: CMFormatDescription?
        var videoKind = ""
        var audioKind = ""
        var trackNote = ""
        var audioRate = 0
        var hasParameterSets = false
        var firstVideoPTS: Int64?
        var firstAudioPTS: Int64?
        var skippedBytes = 0
    }

    /// Reads the PSI tables, then the first access unit's parameter sets and
    /// the first ADTS header. `stopAfter` bounds how much of the file that
    /// costs; `patient` decides whether a stream that has not shown an SPS
    /// yet is an error or a placeholder format.
    static func inspect(_ source: URL,
                        stopAfter: Int,
                        patient: Bool) throws -> Layout {
        let head = try readPrefix(source, count: 64 << 10)
        guard let stride = detectStride(head) else {
            let hex = head.prefix(8).map { String(format: "%02X", $0) }
                .joined(separator: " ")
            throw Failure(message: "开头不是 MPEG-TS 网格（\(hex)）")
        }
        var layout = Layout(stride: stride)

        var pmtPid = -1
        var pmtBytes: [UInt8] = []
        var sets: [[UInt8]] = []
        var adts: AdtsHeader?

        /// Folds one program-map payload in and reads the PIDs out of it once
        /// the section is whole. A PSI section opens with a pointer field, so
        /// the table_id is not the first byte of the packet.
        func takeProgramMap(_ payload: [UInt8], fresh: Bool) {
            if fresh {
                let pointer = Int(payload.first ?? 0)
                pmtBytes = pointer + 1 < payload.count
                    ? Array(payload[(pointer + 1)...]) : []
                if pmtBytes.first != 0x02 { pmtBytes = [] }
            } else if !pmtBytes.isEmpty {
                pmtBytes.append(contentsOf: payload)
            }
            guard pmtBytes.first == 0x02, let parsed = parsePMT(pmtBytes)
            else { return }
            layout.trackNote = parsed.note
            if let video = parsed.streams.first(where: { isVideo($0.type) }) {
                layout.videoPid = video.pid
                layout.videoKind = name(ofStreamType: video.type)
                layout.hevc = video.type == 0x24
            }
            if let audio = parsed.streams.first(where: { isAac($0.type) }) {
                layout.audioPid = audio.pid
                layout.audioKind = "AAC"
            }
        }

        layout.skippedBytes = try walk(source, stride: stride,
                                       stopAfter: stopAfter) { read in
            let pid = read.pid
            if read.pusi {
                if pid == 0, pmtPid < 0 {
                    pmtPid = patProgramMapPID(read.payload)
                } else if pid == pmtPid {
                    // The map can span packets: take payloads until one
                    // declares itself complete.
                    takeProgramMap(read.payload, fresh: true)
                } else if pid == layout.videoPid {
                    let pes = PesStream()
                    pes.begin(read.payload)
                    if layout.firstVideoPTS == nil, let pts = pes.pts {
                        layout.firstVideoPTS = pts
                    }
                    if !layout.hasParameterSets,
                       let frame = pes.close(hevc: layout.hevc) {
                        collectParameterSets(in: frame.bytes,
                                             into: &sets,
                                             hevc: layout.hevc)
                        layout.hasParameterSets = complete(sets,
                                                           hevc: layout.hevc)
                    }
                } else if pid == layout.audioPid {
                    let pes = PesStream()
                    pes.begin(read.payload)
                    if layout.firstAudioPTS == nil, let pts = pes.pts {
                        layout.firstAudioPTS = pts
                    }
                    if adts == nil, let frame = pes.takeAdtsFrame() {
                        adts = frame.header
                    }
                }
            } else if pid == pmtPid, layout.videoPid < 0 {
                takeProgramMap(read.payload, fresh: false)
            } else if pid == layout.audioPid, adts == nil {
                adts = AdtsHeader(read.payload)
            }
            return layout.videoPid >= 0
                && layout.hasParameterSets
                && layout.firstVideoPTS != nil
                && adts != nil
        }

        guard layout.videoPid >= 0 else {
            throw Failure(message: "节目表里没有视频流（\(layout.trackNote)）")
        }
        if layout.hasParameterSets {
            layout.videoDescription = try videoFormat(parameterSets: sets,
                                                      hevc: layout.hevc,
                                                      kind: layout.videoKind)
        } else if patient {
            throw Failure(message: "整条流里都没有视频参数集"
                + "（SPS/PPS 缺失，\(layout.videoKind)）")
        } else {
            layout.videoDescription = placeholderVideo(hevc: layout.hevc)
        }
        if layout.audioPid >= 0, let header = adts {
            layout.audioRate = header.sampleRate
            layout.audioDescription = try audioFormat(header)
        }
        return layout
    }

    // MARK: - The writing pass

    /// One access unit whose place on the MP4 timeline is already known.
    struct Held {
        let frame: PESFrame
        let present: Int64
        let decode: Int64
    }

    /// Second pass: PES reassembly on the two PIDs, one compressed sample per
    /// access unit, appended straight into the writer.
    static func mux(source: URL,
                    layout: Layout,
                    videoInput: AVAssetWriterInput?,
                    audioInput: AVAssetWriterInput?,
                    writer: AVAssetWriter) -> MuxState {
        let state = MuxState()
        state.writer = writer
        state.video = videoInput
        state.audio = audioInput
        guard let description = layout.videoDescription, videoInput != nil
        else {
            state.error = "读不出视频格式（\(layout.trackNote)）"
            return state
        }
        let videoPes = PesStream()
        let audioPes = PesStream()
        var held: Held?
        var videoPresent = Unwrap()
        var videoDecode = Unwrap()
        var audioClock = Unwrap()
        var audioIndex = 0
        var audioAnchor: Int64?

        // One shared zero. Whichever track starts first defines it, so neither
        // ends up with a negative sample time and the pair keeps the offset
        // the stream was authored with.
        let first = layout.firstVideoPTS ?? layout.firstAudioPTS ?? 0
        let base = min(first, layout.firstAudioPTS ?? first)
        // Samples reach the writer in decode order, so the decode clock is the
        // one whose monotonicity the writer insists on. Times are relative to
        // `base` from here on, so this zero is the shared one, not `base`
        // itself — a first sample measured against the raw clock is smaller
        // than it and never gets written.
        var lastDecode: Int64 = 0
        let ticksPerAudioFrame = layout.audioRate > 0
            ? 1024.0 * Double(timescale) / Double(layout.audioRate) : 0

        do {
            state.skippedBytes = try walk(source, stride: layout.stride) { read in
                if read.discontinuity {
                    // A splice or a truncated stream: whatever was in flight
                    // is only part of an access unit, so it is thrown away
                    // rather than written as one.
                    if read.pid == layout.videoPid, videoPes.isCollecting {
                        if let older = held {
                            state.writePending(older, description: description)
                            held = nil
                        }
                        videoPes.drop()
                    }
                    if read.pid == layout.audioPid { audioPes.drop() }
                }
                if read.pid == layout.videoPid {
                    if read.pusi {
                        if let closed = videoPes.close(hevc: layout.hevc),
                           let pts = closed.pts {
                            let present = videoPresent.continuous(pts) - base
                            let decode = videoDecode
                                .continuous(closed.decode ?? pts) - base
                            // A unit that starts before the one already
                            // accepted would stop the writer mid-file, so it
                            // is dropped instead.
                            if present >= 0, decode >= lastDecode, decode >= 0 {
                                if let older = held {
                                    let duration = max(1, decode - older.decode)
                                    state.lastDuration = duration
                                    if state.writeVideo(older.frame,
                                                        start: older.present,
                                                        duration: duration,
                                                        decode: older.decode,
                                                        description:
                                                            description) {
                                        state.lastPresent = older.present + duration
                                    }
                                }
                                held = Held(frame: closed,
                                            present: present,
                                            decode: decode)
                                lastDecode = decode
                            }
                        }
                        videoPes.begin(read.payload)
                    } else {
                        videoPes.append(read.payload)
                    }
                } else if read.pid == layout.audioPid,
                          let audioFormat = layout.audioDescription,
                          audioInput != nil {
                    if read.pusi {
                        audioPes.begin(read.payload)
                        audioIndex = 0
                        audioAnchor = nil
                    } else {
                        audioPes.append(read.payload)
                    }
                    // AAC is written frame by frame, timed off the frame's
                    // index inside its own PES: one PES can carry three
                    // 1024-sample frames and time only the first, so letting
                    // the header clock each one is how audio drifts seconds
                    // behind an episode.
                    while let frame = audioPes.takeAdtsFrame() {
                        defer { audioIndex += 1 }
                        if audioIndex == 0, let pts = frame.pts {
                            audioAnchor = audioClock.continuous(pts) - base
                        }
                        guard let anchor = audioAnchor, anchor >= 0 else { continue }
                        let measured = Double(audioIndex) * ticksPerAudioFrame
                        let counted = Double(audioIndex + 1) * ticksPerAudioFrame
                        let start = anchor + Int64(measured.rounded())
                        guard start > state.lastStart else { continue }
                        let duration = max(1, Int64(counted.rounded())
                                            - Int64(measured.rounded()))
                        let sample = PESFrame(bytes: frame.bytes,
                                              pts: start, decode: nil)
                        if state.writeAudio(sample, start: start,
                                           duration: duration,
                                           description: audioFormat) {
                            state.lastStart = start
                        }
                    }
                }
                return state.aborted
            }
        } catch {
            state.error = describe(error)
        }

        // The final access unit has no successor to measure against, so it
        // keeps the pacing the rest of the track used.
        if let last = held {
            if state.writeVideo(last.frame, start: last.present,
                               duration: state.lastDuration,
                               decode: last.decode,
                               description: description) {
                state.lastPresent = last.present + state.lastDuration
            }
        }
        // Samples the writer had no room for are written before the walk is
        // called finished, because the inputs are closed right after it.
        state.flush()
        state.close(video: true)
        state.close(video: false)
        return state
    }

    // MARK: - Packet walk

    /// One TS packet header already decoded.
    struct PacketRead {
        let pid: Int
        let pusi: Bool
        /// The packet's adaptation_field_control, kept for the diagnostic pass.
        let control: Int
        /// Set by the adaptation field's own flag byte, where a producer marks
        /// a splice or a truncated stream. The elementary stream in flight at
        /// that point is cut off, so it must not be trusted.
        let discontinuity: Bool
        let payload: [UInt8]
    }

    /// Streams the file in 512 KB blocks and calls `consume` for every packet.
    /// Reading three hundred megabytes a packet at a time would be dominated
    /// by syscalls.
    ///
    /// Returns the bytes discarded while re-finding the grid. `stopAfter`
    /// reads only the front of the file, which is how the inspection pass
    /// looks at the tables without touching the whole stream.
    static func walk(_ source: URL,
                     stride: Int,
                     stopAfter: Int = 0,
                     consume: (PacketRead) -> Bool) throws -> Int {
        guard let handle = try? FileHandle(forReadingFrom: source.absoluteURL) else {
            throw Failure(message: "读不到文件")
        }
        defer { try? handle.close() }

        let body = min(stride, 188)
        var carry: [UInt8] = []
        var absolute = 0
        var skipped = 0
        var stop = false
        while !stop {
            let data = handle.readData(ofLength: 1 << 19)
            if data.isEmpty { break }
            var buffer = carry
            buffer.append(contentsOf: data)
            carry = []
            var offset = 0
            while true {
                guard offset < buffer.count else { break }
                if buffer[offset] != 0x47 {
                    guard let next = alignedGrid(in: buffer, from: offset,
                                                 stride: stride) else {
                        skipped += buffer.count - offset
                        offset = buffer.count
                        break
                    }
                    skipped += next - offset
                    offset = next
                    continue
                }
                guard offset + stride <= buffer.count else { break }
                let start = offset
                let second = buffer[start + 1]
                let fourth = buffer[start + 3]
                let pid = ((Int(second & 0x1F) << 8) | Int(buffer[start + 2]))
                    & 0x1FFF
                let control = Int(fourth >> 4) & 3
                // Where the bytes this packet carries begin.
                //
                // '11' declares an adaptation field, and that field's first byte
                // is its own length, so nothing before it can be trusted as
                // payload. '10' is payload only. '01' is reserved by the
                // standard, and the muxers that write these files — ffmpeg, and
                // the CDNs whose packet layout it produced — use it for payload
                // only too: in a reference clip every access unit that starts in
                // such a packet has its '00 00 01' in the fourth byte, never the
                // fifth, and their tables only parse from there. So '01' shares
                // the offset with '10', and treating it as an adaptation field
                // would drop the payload it carries.
                var from = start + 4
                var to = start + body
                var discontinuity = false
                if control == 3 {
                    let length = Int(buffer[start + 4])
                    from = min(start + 5 + length, to)
                    // The flag byte is the first byte of the adaptation field,
                    // which fills the rest of the packet when there is no
                    // payload.
                    if length > 0, start + 5 < start + body {
                        discontinuity = (buffer[start + 5] & 0x80) != 0
                    }
                }
                if control != 0, from < to, pid != 0x1FFF {
                    if consume(PacketRead(pid: pid,
                                          pusi: (second & 0x40) != 0,
                                          control: control,
                                          discontinuity: discontinuity,
                                          payload: Array(buffer[from..<to]))) {
                        stop = true
                        break
                    }
                }
                offset += stride
                absolute += stride
                if stopAfter > 0, absolute >= stopAfter { break }
            }
            if offset < buffer.count {
                carry = Array(buffer[offset..<buffer.count])
            }
        }
        return skipped
    }

    /// The next offset from which four packets in a row start on the sync
    /// byte. A lone 0x47 is not evidence — H.264 payloads are full of them.
    static func alignedGrid(in buffer: [UInt8],
                            from offset: Int,
                            stride: Int) -> Int? {
        var candidate = offset + 1
        while candidate + stride * 3 < buffer.count {
            if buffer[candidate] == 0x47,
               buffer[candidate + stride] == 0x47,
               buffer[candidate + stride * 2] == 0x47,
               buffer[candidate + stride * 3] == 0x47 {
                return candidate
            }
            candidate += 1
        }
        return nil
    }

    static func detectStride(_ head: [UInt8]) -> Int? {
        guard head.count > 4, head[0] == 0x47 else { return nil }
        for stride in strideCandidates where head.count > stride * 3 {
            if head[stride] == 0x47, head[stride * 2] == 0x47,
               head[stride * 3] == 0x47 {
                return stride
            }
        }
        return nil
    }

    static func readPrefix(_ source: URL, count: Int) throws -> [UInt8] {
        guard let handle = try? FileHandle(forReadingFrom: source.absoluteURL) else {
            throw Failure(message: "读不到文件")
        }
        defer { try? handle.close() }
        return Array(handle.readData(ofLength: count))
    }

    // MARK: - PSI

    /// The first program's program_map_pid. A PAT entry with program_number 0
    /// points at the network information table, not a program.
    static func patProgramMapPID(_ payload: [UInt8]) -> Int {
        guard payload.count > 13 else { return -1 }
        let pointer = Int(payload[0])
        let section = pointer + 1
        guard section + 12 < payload.count, payload[section] == 0x00 else {
            return -1
        }
        let length = (Int(payload[section + 1] & 0x0F) << 8)
            | Int(payload[section + 2])
        let entries = (length - 9) / 4
        guard entries > 0 else { return -1 }
        var index = 0
        while index < entries, section + 12 + index * 4 <= payload.count {
            let base = section + 8 + index * 4
            let program = (Int(payload[base]) << 8) | Int(payload[base + 1])
            let found = ((Int(payload[base + 2] & 0x1F) << 8)
                | Int(payload[base + 3])) & 0x1FFF
            if program > 0, found > 0 {
                return found
            }
            index += 1
        }
        return -1
    }

    /// `section_length` counts everything after the first three bytes, CRC
    /// included; sixteen is the shortest PMT that can name a stream.
    static func parsePMT(_ bytes: [UInt8])
    -> (streams: [(type: Int, pid: Int)], note: String)? {
        guard bytes.count > 12, bytes[0] == 0x02 else { return nil }
        let length = (Int(bytes[1] & 0x0F) << 8) | Int(bytes[2])
        let needed = 3 + length
        guard needed >= 16, bytes.count >= needed else { return nil }
        let stop = needed - 4
        let programInfo = (Int(bytes[10] & 0x0F) << 8) | Int(bytes[11])
        var cursor = 12 + programInfo
        var streams: [(type: Int, pid: Int)] = []
        var types: [Int] = []
        while cursor + 4 < stop {
            let type = Int(bytes[cursor])
            let pid = ((Int(bytes[cursor + 1] & 0x1F) << 8)
                | Int(bytes[cursor + 2])) & 0x1FFF
            let descriptor = (Int(bytes[cursor + 3] & 0x0F) << 8)
                | Int(bytes[cursor + 4])
            if !types.contains(type) { types.append(type) }
            if !streams.contains(where: { $0.type == type && $0.pid == pid }) {
                streams.append((type, pid))
            }
            cursor += 5 + descriptor
        }
        let note = types.isEmpty ? "节目表没有流"
            : types.map { name(ofStreamType: $0) }.joined(separator: "、")
        return (streams, note)
    }

    static func isVideo(_ type: Int) -> Bool {
        type == 0x1B || type == 0x24
    }

    /// Only ADTS AAC. Stream type 0x11 is LATM, whose configuration lives in
    /// the stream itself, and writing an `mp4a` for it would give a file that
    /// plays silent.
    static func isAac(_ type: Int) -> Bool {
        type == 0x0F
    }

    /// Named in the error text, because "流类型 0x24" tells nobody anything.
    static func name(ofStreamType type: Int) -> String {
        switch type {
        case 0x1B: return "H.264"
        case 0x24: return "HEVC"
        case 0x0F: return "AAC"
        case 0x11: return "AAC-LATM"
        case 0x02: return "MPEG-2 视频"
        case 0x01: return "MPEG-1 视频"
        case 0x03, 0x04: return "MP3"
        case 0x06: return "私有数据"
        case 0x15: return "ID3 字幕"
        default: return String(format: "0x%02X", type)
        }
    }

    // MARK: - Parameter sets and format descriptions

    /// Collects Annex-B parameter sets (H.264 SPS/PPS, HEVC VPS/SPS/PPS) out of
    /// elementary-stream bytes. A type already collected is not collected
    /// again, so the caller can stop as soon as the set is complete.
    static func collectParameterSets(in data: [UInt8],
                                     into sets: inout [[UInt8]],
                                     hevc: Bool) {
        guard !data.isEmpty else { return }
        data.withUnsafeBufferPointer { buffer in
            for unit in nals(in: buffer, hevc: hevc) {
                let wanted = hevc ? (32...34).contains(unit.type)
                    : (unit.type == 7 || unit.type == 8)
                guard wanted, !sets.contains(where: {
                    nalType(of: $0, hevc: hevc) == unit.type
                }) else { continue }
                sets.append(Array(data[unit.offset..<(unit.offset + unit.length)]))
            }
        }
    }

    static func complete(_ sets: [[UInt8]], hevc: Bool) -> Bool {
        let kinds = sets.compactMap { nalType(of: $0, hevc: hevc) }
        return hevc ? (32...34).allSatisfy { kinds.contains($0) }
            : kinds.contains(7) && kinds.contains(8)
    }

    static func nalType(of unit: [UInt8], hevc: Bool) -> Int? {
        guard let first = unit.first else { return nil }
        return hevc ? Int((first >> 1) & 0x3F) : Int(first & 0x1F)
    }

    /// A NAL unit's header type and the bytes it occupies, start codes
    /// excluded. Nothing is copied: a whole access unit is scanned by index.
    struct Nal {
        let type: Int
        let offset: Int
        let length: Int
    }

    static func nals(in data: UnsafeBufferPointer<UInt8>,
                     hevc: Bool) -> [Nal] {
        let codes = startCodes(in: data)
        guard !codes.isEmpty else { return [] }
        var units: [Nal] = []
        for (index, code) in codes.enumerated() {
            let begin = code.offset + code.length
            let end = index + 1 < codes.count
                ? codes[index + 1].previousEnd : trimZeros(data, data.count)
            guard begin < end, data.count > begin else { continue }
            let first = data[begin]
            units.append(Nal(type: hevc ? Int((first >> 1) & 0x3F)
                                        : Int(first & 0x1F),
                            offset: begin,
                            length: end - begin))
        }
        return units
    }

    /// Start codes, each with the offset where the previous NAL really ended:
    /// the zeros that precede a code belong to the padding, never to the NAL.
    static func startCodes(in data: UnsafeBufferPointer<UInt8>)
    -> [(offset: Int, length: Int, previousEnd: Int)] {
        var found: [(offset: Int, length: Int, previousEnd: Int)] = []
        var index = 0
        while index + 2 < data.count {
            if data[index] == 0x00, data[index + 1] == 0x00 {
                if data[index + 2] == 0x01 {
                    found.append((index, 3, trimZeros(data, index)))
                    index += 3
                    continue
                }
                if index + 3 < data.count, data[index + 2] == 0x00,
                   data[index + 3] == 0x01 {
                    found.append((index, 4, trimZeros(data, index)))
                    index += 4
                    continue
                }
            }
            index += 1
        }
        var codes: [(offset: Int, length: Int, previousEnd: Int)] = []
        for entry in found {
            if let last = codes.last, entry.offset - last.offset <= 4 {
                if entry.length > last.length { codes[codes.count - 1] = entry }
                continue
            }
            codes.append(entry)
        }
        return codes
    }

    static func trimZeros(_ data: UnsafeBufferPointer<UInt8>,
                          _ upper: Int) -> Int {
        var end = upper
        while end > 0, data[end - 1] == 0x00 { end -= 1 }
        return end
    }

    /// Whether an access unit can be decoded on its own, which is what MP4's
    /// sync-sample table asks for.
    static func startsKeyframe(_ data: [UInt8], hevc: Bool) -> Bool {
        data.withUnsafeBufferPointer { buffer in
            for unit in nals(in: buffer, hevc: hevc) {
                if hevc, (16...21).contains(unit.type) { return true }
                if !hevc, unit.type == 5 { return true }
            }
            return false
        }
    }

    static func videoFormat(parameterSets: [[UInt8]],
                            hevc: Bool,
                            kind: String) throws -> CMFormatDescription {
        var description: CMFormatDescription?
        // The two calls differ by one parameter: HEVC takes an extensions
        // dictionary, H.264 does not.
        let status = withParameterSetArrays(parameterSets) { pointers, sizes, count in
            hevc
                ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description)
                : CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description)
        }
        guard status == noErr, let made = description else {
            throw Failure(message: "\(kind) 参数集建不出视频格式"
                + "（\(parameterSets.count) 组）")
        }
        return made
    }

    /// An otherwise empty format description carrying only the codec fourcc.
    /// Enough for passthrough writing when the stream has not shown an SPS
    /// yet; the real one is built on the second look.
    static func placeholderVideo(hevc: Bool) -> CMFormatDescription? {
        var description: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            mediaType: kCMMediaType_Video,
            mediaSubType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            extensions: nil,
            formatDescriptionOut: &description)
        guard status == noErr else { return nil }
        return description
    }

    static func audioFormat(_ header: AdtsHeader) throws -> CMFormatDescription {
        // The AudioSpecificConfig: object type, sampling frequency and channel
        // configuration, zero padded out to the byte. The channel field is four
        // bits wide in the config although an ADTS header only carries three;
        // writing three shifts the padding and mono comes out reading as
        // stereo.
        var bits = BitWriter()
        bits.put(header.profile + 1, 5)
        bits.put(header.frequencyIndex, 4)
        if header.frequencyIndex == 15 {
            bits.put(header.sampleRate, 24)
        }
        bits.put(header.channels, 4)
        bits.finish()
        let config = bits.bytes

        // The ES descriptor the MP4 `esds` box holds. The magic cookie is
        // copied into that box as it stands, so it has to be the whole
        // descriptor around the AudioSpecificConfig; the bare config makes a
        // box nothing recognises, and a file whose audio track no player will
        // list at all.
        //
        // The shape follows what a muxed reference of the same stream writes:
        // every tag carries the expanded five-byte length form (`80 80 80 n`),
        // the decoder-config descriptor's length covers the config block nested
        // inside it, `40` names AAC as the object type and `15` packs the audio
        // stream type into its six high bits, and both bitrate fields hold the
        // real average — a file advertising one bit a second reads as broken to
        // anything that trusts the metadata.
        let rate = header.sampleRate
        let bitrate = max(1_024, header.frameLength * 8 * rate / 1024)
        let configBlock = 5 + config.count
        var audio = [UInt8]([0x04, 0x80, 0x80, 0x80, UInt8(13 + configBlock),
                             0x40, 0x15, 0x00, 0x00, 0x00])
        audio += bytes4(bitrate)
        audio += bytes4(bitrate)
        audio += [0x05, 0x80, 0x80, 0x80, UInt8(config.count)] + config
        audio += [0x06, 0x80, 0x80, 0x80, 0x01, 0x02]
        var cookie: [UInt8] = [0x03, 0x80, 0x80, 0x80,
                               UInt8(3 + audio.count), 0x00, 0x02, 0x00]
        cookie += audio

        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(rate),
            mFormatID: kAudioFormatMPEG4AAC,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1024,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(header.channels),
            mBitsPerChannel: 0,
            mReserved: 0)
        // The channel count the sample entry gets is taken from the layout, so
        // a mono stream without one comes out of the writer as stereo. A zeroed
        // `AudioChannelLayout` naming a standard configuration is all the format
        // description reads: it stops at the tag when no descriptions follow.
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channelLayoutTag(header.channels)
        var description: CMAudioFormatDescription?
        let status = withUnsafePointer(to: &asbd) { asbdPointer in
            withUnsafePointer(to: &layout) { layoutPointer in
                cookie.withUnsafeBufferPointer { cookieBuffer in
                    CMAudioFormatDescriptionCreate(
                        allocator: kCFAllocatorDefault,
                        asbd: asbdPointer,
                        layoutSize: MemoryLayout<AudioChannelLayout>.size,
                        layout: layoutPointer,
                        magicCookieSize: cookieBuffer.count,
                        magicCookie: cookieBuffer.baseAddress,
                        extensions: nil,
                        formatDescriptionOut: &description)
                }
            }
        }
        guard status == noErr, let made = description else {
            throw Failure(message: "AAC 格式建不出来"
                + "（\(rate) Hz、\(header.channels) 声道）")
        }
        return made
    }

    /// Four big-endian bytes: the bitrate fields of an ES descriptor are
    /// thirty-one bits wide and counted in bits per second.
    private static func bytes4(_ value: Int) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// `kAudioChannelLayoutTag_Mono`, `…_Stereo`, or a count of channels in
    /// declaration order for the surround layouts no phone browser meets twice.
    private static func channelLayoutTag(_ channels: Int) -> UInt32 {
        if channels == 1 { return 101 }
        if channels == 2 { return 100 }
        return 0x4000 | UInt32(max(0, channels))
    }

    // MARK: - Samples

    /// Builds one compressed sample buffer. Video arrives already converted
    /// from Annex-B to length-prefixed form, which is the only rewrite an MP4
    /// sample actually requires; audio arrives as a bare AAC frame.
    static func sampleBuffer(bytes: [UInt8],
                             start: Int64,
                             duration: Int64,
                             decode: Int64,
                             description: CMFormatDescription,
                             isKey: Bool,
                             flagged: Bool) -> CMSampleBuffer? {
        guard bytes.count > 1, start >= 0, duration > 0 else { return nil }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &block) == kCMBlockBufferNoErr,
            let blockBuffer = block else { return nil }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(with: base,
                                          blockBuffer: blockBuffer,
                                          offsetIntoDestination: 0,
                                          dataLength: bytes.count)
        }

        let scale = Int32(timescale)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: duration, timescale: scale),
            presentationTimeStamp: CMTime(value: start, timescale: scale),
            decodeTimeStamp: CMTime(value: decode, timescale: scale))
        // The writer needs the sample's size declared, not just the length of
        // the block buffer: without a size entry an audio append fails with
        // kCMSampleBufferError_BufferHasNoSampleSizes.
        var size = bytes.count

        var sample: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr,
            let made = sample else { return nil }
        if flagged {
            markKeyframe(made, isKey: isKey)
        }
        return made
    }

    /// The one attachment the writer reads. Without it every video sample
    /// looks inter-predicted, so the MP4 gets a single sync sample at the very
    /// front and seeks badly. The attachments array exists only once asked
    /// for, and its dictionaries are only writable through the C API.
    static func markKeyframe(_ sample: CMSampleBuffer, isKey: Bool) {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: true),
            CFArrayGetCount(array) > 0,
            let slot = CFArrayGetValueAtIndex(array, 0) else { return }
        let dictionary = Unmanaged<CFMutableDictionary>.fromOpaque(slot)
            .takeUnretainedValue()
        let key = Unmanaged.passUnretained(
            kCMSampleAttachmentKey_DependsOnOthers as CFString).toOpaque()
        let flag: CFBoolean = isKey ? kCFBooleanFalse : kCFBooleanTrue
        CFDictionarySetValue(dictionary, key,
                             Unmanaged.passUnretained(flag).toOpaque())
    }

    /// Rewrites Annex-B start codes into four-byte big-endian lengths. The NAL
    /// bytes themselves are copied untouched, so the sample stays bit-exact.
    static func annexBToLengthPrefixed(_ data: [UInt8]) -> [UInt8] {
        data.withUnsafeBufferPointer { buffer in
            let codes = startCodes(in: buffer)
            guard !codes.isEmpty else { return [] }
            var out: [UInt8] = []
            out.reserveCapacity(data.count + codes.count * 4)
            for (index, code) in codes.enumerated() {
                let begin = code.offset + code.length
                let end = index + 1 < codes.count
                    ? codes[index + 1].previousEnd : trimZeros(buffer, buffer.count)
                guard begin <= end, end <= buffer.count else { continue }
                let length = end - begin
                out.append(UInt8((length >> 24) & 0xFF))
                out.append(UInt8((length >> 16) & 0xFF))
                out.append(UInt8((length >> 8) & 0xFF))
                out.append(UInt8(length & 0xFF))
                out.append(contentsOf: data[begin..<end])
            }
            return out
        }
    }

    static func describe(_ error: (any Error)?) -> String {
        guard let error else { return "未知错误" }
        let bridged = error as NSError
        var text = "\(bridged.domain) \(bridged.code) · "
            + bridged.localizedDescription
        // The writer's own code is usually the generic one; the real reason
        // hides in the CoreMedia or OSStatus error underneath it.
        if let underlying = bridged.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += "（底层 \(underlying.domain) \(underlying.code)"
            text += " · \(underlying.localizedDescription)）"
        }
        return text
    }
}

// MARK: - Elementary-stream bookkeeping

/// One access unit, or one AAC frame, with the timestamps its PES header
/// carried.
struct PESFrame {
    let bytes: [UInt8]
    let pts: Int64?
    let decode: Int64?
    var isKey = false
}

/// Accumulates the payloads of one elementary stream between two start
/// pointers, and reads the PES header off the front of a fresh one.
final class PesStream {
    private var bytes: [UInt8] = []
    private var info: PesInfo?

    var pts: Int64? { info?.pts }

    /// Whether bytes are being collected for an access unit that has a valid
    /// header.
    var isCollecting: Bool { info != nil && !bytes.isEmpty }

    /// Opens a new PES at a start pointer.
    func begin(_ payload: [UInt8]) {
        bytes = payload
        info = nil
        stripHeader()
    }

    func append(_ payload: [UInt8]) {
        bytes.append(contentsOf: payload)
        if info == nil {
            // A long PES header can cross a packet boundary.
            stripHeader()
            return
        }
        if bytes.count > 32 << 20 {
            // No live access unit is 32 MB. The start pointer was almost
            // certainly lost, so stop carrying garbage forward.
            bytes.removeAll(keepingCapacity: true)
            info = nil
        }
    }

    /// Throws away whatever is in flight: a discontinuity indicator means the
    /// stream was cut here, so the bytes collected so far belong to no
    /// complete access unit.
    func drop() {
        bytes.removeAll(keepingCapacity: true)
        info = nil
    }

    /// The completed access unit, or nil when the header never made sense.
    func close(hevc: Bool) -> PESFrame? {
        defer {
            bytes.removeAll(keepingCapacity: true)
            info = nil
        }
        guard let info, let pts = info.pts, bytes.count > 4 else { return nil }
        return PESFrame(bytes: bytes, pts: pts, decode: info.decode,
                        isKey: TsToMp4.startsKeyframe(bytes, hevc: hevc))
    }

    /// The next complete ADTS frame in the audio payload, already stripped of
    /// its header, plus that header: the sampling rate and channel count the
    /// MP4 needs are only in the header. Video streams never answer.
    func takeAdtsFrame() -> (bytes: [UInt8], header: AdtsHeader, pts: Int64?)? {
        guard let info, !info.isVideo, bytes.count > 8,
              let header = AdtsHeader(bytes) else { return nil }
        // `aac_frame_length` counts the header itself, so it is both how far
        // this frame reaches and how much to drop. Adding the header size
        // again would read past the frame, and the next header would not be a
        // header: only the first frame of a packed audio PES would survive.
        let total = header.frameLength
        guard total <= bytes.count else { return nil }
        let raw = Array(bytes[header.headerSize..<total])
        bytes.removeFirst(total)
        return (raw, header, info.pts)
    }

    /// Drops the PES header once enough bytes have arrived to hold it.
    private func stripHeader() {
        guard let parsed = TsToMp4.pesInfo(bytes) else { return }
        guard parsed.bodyStart <= bytes.count else { return }
        bytes.removeFirst(parsed.bodyStart)
        info = parsed
    }
}

/// The fields of a PES header, and where the elementary data starts.
struct PesInfo {
    let streamID: Int
    let pts: Int64?
    let decode: Int64?
    let bodyStart: Int

    /// 0xE0…0xEF is the video range; anything below is audio or data.
    var isVideo: Bool { streamID >= 0xE0 }
}

/// `packet_stream_id`, the PTS/DTS flags and the header length — none of
/// which mean anything unless the three-byte prefix is there.
extension TsToMp4 {
    static func pesInfo(_ data: [UInt8]) -> PesInfo? {
        guard data.count > 9, data[0] == 0x00, data[1] == 0x00,
              data[2] == 0x01 else { return nil }
        let streamID = Int(data[3])
        // 0xBC is program_stream_map, 0xBE padding_stream.
        guard streamID != 0xBC, streamID != 0xBE else { return nil }
        let flags = data[7]
        let timing = (flags >> 6) & 3
        let headerLength = Int(data[8])
        var pts: Int64?
        var decode: Int64?
        if timing >= 2 {
            pts = timestamp(at: 9, in: data)
            if timing == 3 {
                decode = timestamp(at: 14, in: data)
            }
        }
        var start = 9 + headerLength
        let declared = (Int(data[4]) << 8) | Int(data[5])
        if declared > 0 {
            // A live segment leaves the length at zero, which means
            // "unbounded": the whole packet belongs to this PES.
            start = min(start, 6 + declared)
        }
        guard start >= 9 else { return nil }
        return PesInfo(streamID: streamID, pts: pts, decode: decode,
                       bodyStart: start)
    }

    /// 33-bit PTS/DTS, with the marker bits every specification reminds you
    /// about: the five bytes are `xxx1` `8 bits` `xxx8 bits` `8 bits`
    /// `xxx4 bits+marker`, and every one of the 33 value bits sits in a
    /// different field than the padding around it.
    static func timestamp(at index: Int, in data: [UInt8]) -> Int64? {
        guard index + 4 < data.count else { return nil }
        let value = (Int64(data[index] & 0x0E) << 29)
            | (Int64(data[index + 1]) << 22)
            | (Int64(data[index + 2] & 0xFE) << 14)
            | (Int64(data[index + 3]) << 7)
            | Int64(data[index + 4] >> 1)
        return value & (clockSpan - 1)
    }
}

/// Unwraps 33-bit timestamps that went around once, so a two-hour stream does
/// not end up with negative sample times.
struct Unwrap {
    private var offset: Int64 = 0
    private var last: Int64?

    mutating func continuous(_ raw: Int64) -> Int64 {
        if let previous = last {
            if raw + 4_000_000_000 < previous { offset += TsToMp4.clockSpan }
            if raw > previous + 4_000_000_000 { offset -= TsToMp4.clockSpan }
        }
        last = raw
        return raw + offset
    }
}

/// One AAC frame's ADTS header.
struct AdtsHeader {
    let profile: Int
    let frequencyIndex: Int
    let channels: Int
    let frameLength: Int
    let headerSize: Int
    let exactFrequency: Int?

    var sampleRate: Int {
        if frequencyIndex == 15 { return exactFrequency ?? 44_100 }
        return AdtsHeader.rates.indices.contains(frequencyIndex)
            ? AdtsHeader.rates[frequencyIndex] : 44_100
    }

    static let rates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
                        22_050, 16_000, 12_000, 11_025, 8_000, 7_350]

    init?(_ data: [UInt8]) {
        guard data.count > 8, data[0] == 0xFF, (data[1] & 0xF0) == 0xF0 else {
            return nil
        }
        var bits = BitCursor(data)
        _ = bits.take(12)                             // syncword
        _ = bits.take(1)                              // MPEG version
        guard bits.take(2) == 0 else { return nil }   // layer is always zero
        let protection = bits.take(1)
        profile = bits.take(2)
        frequencyIndex = bits.take(4)
        _ = bits.take(1)                              // private bit
        channels = bits.take(3)
        _ = bits.take(1)                              // original copy
        _ = bits.take(1)                              // home
        _ = bits.take(1)                              // copyright id
        _ = bits.take(1)                              // copyright start
        frameLength = bits.take(13)
        _ = bits.take(11)                             // buffer fullness
        _ = bits.take(2)                              // raw data blocks
        headerSize = protection == 1 ? 7 : 9
        guard frameLength > headerSize else { return nil }
        exactFrequency = frequencyIndex == 15 ? bits.take(24) : nil
    }
}

/// Most-significant-bit-first cursor: ADTS fields are 13 and 11 bits wide, so
/// byte indexing would only be a longer way to the same answer.
struct BitCursor {
    private let data: [UInt8]
    private var position = 0

    init(_ data: [UInt8]) {
        self.data = data
    }

    mutating func take(_ count: Int) -> Int {
        var value = 0
        for _ in 0..<count {
            guard position >> 3 < data.count else { break }
            let bit = (Int(data[position >> 3]) >> (7 - (position & 7))) & 1
            value = (value << 1) | bit
            position += 1
        }
        return value
    }
}

/// The other half of the same problem, for writing the AudioSpecificConfig.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var pending = 0
    private var width = 0

    mutating func put(_ value: Int, _ count: Int) {
        for index in stride(from: count - 1, through: 0, by: -1) {
            pending = (pending << 1) | ((value >> index) & 1)
            width += 1
            if width == 8 {
                bytes.append(UInt8(pending & 0xFF))
                pending = 0
                width = 0
            }
        }
    }

    mutating func finish() {
        guard width > 0 else { return }
        pending <<= (8 - width)
        bytes.append(UInt8(pending & 0xFF))
        pending = 0
        width = 0
    }
}

/// What the writing pass produced, plus the one place that talks to the
/// writer, so a rejected sample is reported instead of silently missing.
final class MuxState {
    var videoSamples = 0
    var audioSamples = 0
    var skippedBytes = 0
    var lastDuration: Int64 = 3_000
    var lastPresent: Int64 = 0
    var lastStart: Int64 = -1
    var error: String?

    /// Once the writer has refused a sample it never accepts another, so the
    /// rest of a three-hundred-megabyte file would only be read to be thrown
    /// away — thirty seconds of waiting per sample. The walk stops here.
    var aborted = false

    /// The input has no status of its own, so failures are reported through
    /// the writer they belong to.
    weak var writer: AVAssetWriter?

    /// Both inputs, because samples are handed to the writer two tracks at a
    /// time: it wants the second one before it goes on draining the first.
    weak var video: AVAssetWriterInput?
    weak var audio: AVAssetWriterInput?

    /// Whether each input has already been told the stream is over, so closing
    /// is something the writer hears once per track.
    private var videoClosed = false
    private var audioClosed = false

    var seconds: Double {
        Double(max(0, lastPresent)) / Double(TsToMp4.timescale)
    }

    /// Hands one video access unit to the writer, or holds it until the video
    /// input has room.
    func writeVideo(_ frame: PESFrame,
                    start: Int64,
                    duration: Int64,
                    decode: Int64,
                    description: CMFormatDescription) -> Bool {
        write(bytes: TsToMp4.annexBToLengthPrefixed(frame.bytes),
              start: start, duration: duration, decode: decode,
              description: description, isKey: frame.isKey,
              flagged: true, video: true)
    }

    /// Writes an access unit whose place on the timeline was settled when it
    /// was accepted, using the pacing the rest of the track has.
    @discardableResult
    func writePending(_ older: TsToMp4.Held,
                      description: CMFormatDescription) -> Bool {
        let written = writeVideo(older.frame, start: older.present,
                                 duration: lastDuration, decode: older.decode,
                                 description: description)
        if written { lastPresent = older.present + lastDuration }
        return written
    }

    func writeAudio(_ frame: PESFrame,
                    start: Int64,
                    duration: Int64,
                    description: CMFormatDescription) -> Bool {
        write(bytes: frame.bytes, start: start, duration: duration,
              decode: start, description: description, isKey: false,
              flagged: false, video: false)
    }

    /// Drains what the two queues still hold once the stream is exhausted, so
    /// a sample that was waiting on a full input still reaches the file.
    ///
    /// The writer holds a track's last samples until the interleaving point
    /// ahead of them arrives from the other track, and after the stream ends
    /// that point never does: a 40 MB clip stalls with three video frames left,
    /// the audio queue empty, and both inputs healthy. So an exhausted track is
    /// closed here, which is what releases the other one.
    func flush() {
        let deadline = Date().addingTimeInterval(waitLimit)
        while !pendingVideo.isEmpty || !pendingAudio.isEmpty {
            pump()
            if aborted { return }
            if pendingVideo.isEmpty && pendingAudio.isEmpty { return }
            if pendingAudio.isEmpty { close(video: false) }
            if pendingVideo.isEmpty { close(video: true) }
            if Date() > deadline {
                stallReport()
                return
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    /// Tells one input that no further sample is coming, once per input: the
    /// caller that owns the writer finishes up without having to know which
    /// track ran out first.
    func close(video isVideo: Bool) {
        let input = isVideo ? video : audio
        if isVideo {
            guard !videoClosed else { return }
            videoClosed = true
        } else {
            guard !audioClosed else { return }
            audioClosed = true
        }
        input?.markAsFinished()
    }

    // MARK: - Feeding the writer

    private struct Pending {
        let buffer: CMSampleBuffer
        let bytes: Int
        let start: Int64
    }

    private var pendingVideo: [Pending] = []
    private var pendingAudio: [Pending] = []
    private var queuedBytes = 0

    /// The writer interleaves the two tracks, so it stops taking video until
    /// the audio has come up to the same point on the timeline — and the walk
    /// only reads on if the writer takes video. Blocking inside one input
    /// therefore starves the other, and the file wedges with the writer
    /// healthy and no sample rejected. Each track has a queue, and both are
    /// drained together; only a queue over this limit holds the walk up.
    private static let queueLimit = 16 << 20
    private let waitLimit = 60.0

    private func write(bytes: [UInt8],
                       start: Int64,
                       duration: Int64,
                       decode: Int64,
                       description: CMFormatDescription,
                       isKey: Bool,
                       flagged: Bool,
                       video: Bool) -> Bool {
        guard !aborted else { return false }
        guard let buffer = TsToMp4.sampleBuffer(bytes: bytes,
                                                start: start,
                                                duration: duration,
                                                decode: decode,
                                                description: description,
                                                isKey: isKey,
                                                flagged: flagged) else {
            fail("\(video ? "视频" : "音频")样本构造失败（\(bytes.count)B "
                 + "start=\(start) dur=\(duration) decode=\(decode)）")
            return false
        }
        let sample = Pending(buffer: buffer, bytes: bytes.count, start: start)
        if video {
            pendingVideo.append(sample)
        } else {
            pendingAudio.append(sample)
        }
        queuedBytes += bytes.count
        pump()
        guard queuedBytes > Self.queueLimit else { return true }
        // The writer has been given everything the file offered up to here, so
        // the only move left is a bounded wait — reported rather than waited
        // through for three hundred megabytes.
        let deadline = Date().addingTimeInterval(waitLimit)
        while queuedBytes > Self.queueLimit {
            pump()
            if aborted { return false }
            if let writer, writer.status == .failed {
                fail("\(video ? "视频" : "音频")样本写入失败（"
                     + "\(TsToMp4.describe(writer.error))）")
                return false
            }
            if Date() > deadline {
                stallReport()
                return false
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return true
    }

    /// Appends everything either input will take, video first so the track that
    /// costs the writer most gets moving again.
    private func pump() {
        drain(into: video, queue: &pendingVideo, video: true)
        if !aborted { drain(into: audio, queue: &pendingAudio, video: false) }
    }

    private func drain(into input: AVAssetWriterInput?,
                       queue: inout [Pending], video: Bool) {
        guard let input else {
            queuedBytes -= queue.reduce(0) { $0 + $1.bytes }
            queue.removeAll()
            return
        }
        while input.isReadyForMoreMediaData, let next = queue.first {
            if ProcessInfo.processInfo.environment["TSMUX_TRACE"] != nil {
                let line = "\(video ? "视频" : "音频") \(next.start) "
                    + "\(next.bytes)B 已排队 \(queuedBytes)B\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            queue.removeFirst()
            queuedBytes -= next.bytes
            guard input.append(next.buffer) else {
                fail("\(video ? "视频" : "音频")样本写入失败（"
                     + "\(TsToMp4.describe(writer?.error))）："
                     + "\(next.bytes)B start=\(next.start)")
                return
            }
            if video { videoSamples += 1 } else { audioSamples += 1 }
        }
    }

    /// Both tracks are named, because which one has room says whether the
    /// writer is waiting for the second stream or has stopped altogether.
    private func stallReport() {
        error = "写入队列卡住（视频还差 \(pendingVideo.count) 帧、音频还差 "
            + "\(pendingAudio.count) 帧，视频轨\(video?.isReadyForMoreMediaData == true ? "空着" : "满")"
            + "、音频轨\(audio?.isReadyForMoreMediaData == true ? "空着" : "满")，"
            + "写入器状态 \(writer?.status.rawValue ?? -1) "
            + "\(TsToMp4.describe(writer?.error))）"
        aborted = true
    }

    private func fail(_ message: String) {
        error = message
        aborted = true
    }
}

/// Copies the parameter sets into one stable block and hands over the two C
/// arrays the format-description calls want: byte pointers, and their sizes.
/// Nothing escapes the call, so neither array can move under the C function
/// that is reading it.
func withParameterSetArrays<R>(
    _ sets: [[UInt8]],
    _ body: (UnsafePointer<UnsafePointer<UInt8>>,
             UnsafePointer<Int>,
             Int) -> R) -> R {
    let capacity = max(sets.count, 1)
    let total = sets.reduce(0) { $0 + $1.count }
    let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: max(total, 1))
    defer { storage.deallocate() }
    let pointers = UnsafeMutablePointer<UnsafePointer<UInt8>>
        .allocate(capacity: capacity)
    defer { pointers.deallocate() }
    let sizes = UnsafeMutablePointer<Int>.allocate(capacity: capacity)
    defer { sizes.deallocate() }
    var offset = 0
    for (index, set) in sets.enumerated() {
        set.withUnsafeBytes { source in
            if let base = source.baseAddress, !set.isEmpty {
                memcpy(storage.advanced(by: offset), base, set.count)
            }
        }
        pointers[index] = UnsafePointer(storage.advanced(by: offset))
        sizes[index] = set.count
        offset += set.count
    }
    return body(UnsafePointer(pointers), UnsafePointer(sizes), sets.count)
}

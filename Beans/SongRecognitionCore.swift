//
//  SongRecognitionCore.swift
//  Beans
//
//  听歌识曲核心（偏好 / 录音 / 采样缓冲 / 指纹 / 识别状态机），移植自 MeloX
//  （https://github.com/youshen2/MeloX，GPL-3.0）。
//  原文件：MeloX/Features/SongRecognition/SongRecognitionStore.swift、
//          SongRecognitionAudioRecorder.swift、SongRecognitionSampleBuffer.swift、
//          SongRecognitionCapturedAudioBuffer.swift、SongRecognitionAppAudioCapture.swift、
//          SongRecognitionResult.swift、NeteaseAudioFingerprintGenerator.swift、
//          Core/Settings/Recognition/SongRecognitionPreferences.swift、
//          SongRecognitionAudioSource.swift、
//          Core/Networking/NeteaseAPI.swift 的 audioMatches（源自
//          @neteaseapireborn/api 的 audio_match.js，是网易云官方公开匹配接口，
//          不是代理路由：GET interface.music.163.com/api/music/audio/match，
//          algorithmCode=shazam_v2，指纹由网易 AFP WASM 运行时在本地生成）。
//  改动：Observation 改为 Beans 通用的 ObservableObject；接口走
//  NetEaseAPI.shared；候选歌曲以字典解析复用 Beans 的 Song(json:)；
//  停止录音时音频会话交还给 Beans 播放器自行配置（MeloX 走自己的
//  AudioPlaybackSessionConfigurator）。
//  简化：系统音频捕获（MeloX 用 ScreenCaptureKit 且要求 iOS 27）在
//  iOS 18 目标下不可用，未移植；音频来源只保留麦克风与应用音频（ReplayKit）。
//

import AVFoundation
import Foundation
import ReplayKit
import UIKit
@preconcurrency import WebKit

// MARK: - 偏好

enum SongRecognitionAudioSource: String, CaseIterable, Identifiable {
    case microphone
    case appAudio
    case systemAudio

    var id: String { rawValue }

    /// iOS 18 下系统音频（ScreenCaptureKit）不可用，只开放麦克风与应用音频。
    static var availableCases: [SongRecognitionAudioSource] {
        [.microphone, .appAudio]
    }

    var title: String {
        switch self {
        case .microphone: return "麦克风"
        case .appAudio: return "应用音频"
        case .systemAudio: return "系统音频"
        }
    }

    var detail: String {
        switch self {
        case .microphone: return "聆听周围环境中的音乐"
        case .appAudio: return "识别本机其他应用正在播放的音乐"
        case .systemAudio: return "识别系统音频"
        }
    }

    var systemImage: String {
        switch self {
        case .microphone: return "mic.fill"
        case .appAudio: return "music.note"
        case .systemAudio: return "speaker.wave.2.fill"
        }
    }

    var preparationTitle: String {
        self == .microphone ? "正在准备麦克风" : "正在准备音频捕获"
    }

    var permissionMessage: String {
        self == .microphone
            ? "需要麦克风权限来聆听周围的音乐"
            : "需要屏幕录制权限来捕获应用音频"
    }
}

enum SongRecognitionDuration: Int, CaseIterable, Identifiable {
    case quick = 3
    case balanced = 6
    case extended = 9
    case continuous = 0

    var id: Int { rawValue }

    var maximumDuration: Int? {
        isContinuous ? nil : rawValue
    }

    var isContinuous: Bool {
        self == .continuous
    }

    var title: String {
        switch self {
        case .quick, .balanced, .extended: return "\(rawValue) 秒"
        case .continuous: return "持续识别"
        }
    }

    var detail: String {
        switch self {
        case .quick: return "最快出结果"
        case .balanced: return "推荐"
        case .extended: return "适合安静或片段较短的环境"
        case .continuous: return "持续聆听并累积结果"
        }
    }
}

@MainActor
final class SongRecognitionPreferences: ObservableObject {
    private enum Key {
        static let duration = "beans.recognition.duration"
        static let audioSource = "beans.recognition.audioSource"
    }

    @Published var duration: SongRecognitionDuration {
        didSet { defaults.set(duration.rawValue, forKey: Key.duration) }
    }

    @Published var audioSource: SongRecognitionAudioSource {
        didSet { defaults.set(audioSource.rawValue, forKey: Key.audioSource) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedSource = defaults.string(forKey: Key.audioSource)
            .flatMap(SongRecognitionAudioSource.init(rawValue:)) ?? .microphone
        audioSource = SongRecognitionAudioSource.availableCases.contains(savedSource)
            ? savedSource : .microphone
        if defaults.object(forKey: Key.duration) != nil {
            duration = SongRecognitionDuration(rawValue: defaults.integer(forKey: Key.duration)) ?? .balanced
        } else {
            duration = .balanced
        }
    }
}

// MARK: - 结果

struct SongRecognitionResult: Identifiable {
    var id: Int { song.id }

    var song: Song
    let startTimeMilliseconds: Int?

    var playbackPosition: TimeInterval {
        TimeInterval(max(startTimeMilliseconds ?? 0, 0)) / 1_000
    }
}

// MARK: - 识别接口（网易云官方 audio/match）

struct AudioMatchCandidate {
    let song: Song
    let startTime: Int?
}

extension NetEaseAPI {
    /// 指纹匹配：公开 GET 接口，无 weapi/eapi 加密，参数口径同 MeloX audioMatches。
    func audioMatches(fingerprint: String, duration: Int) async throws -> [AudioMatchCandidate] {
        guard !fingerprint.isEmpty, (1...15).contains(duration) else {
            throw NetEaseError.unknown("识别参数无效")
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = fingerprint.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw NetEaseError.unknown("指纹编码失败")
        }
        var components = URLComponents(string: "https://interface.music.163.com/api/music/audio/match")
        components?.percentEncodedQuery = [
            "sessionId=0123456789abcdef",
            "algorithmCode=shazam_v2",
            "duration=\(duration)",
            "rawdata=\(encoded)",
            "times=1",
            "decrypt=1",
        ].joined(separator: "&")
        guard let url = components?.url else { throw NetEaseError.unknown("识别地址无效") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NetEaseError.network
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw NetEaseError.decoding("识别结果解析失败")
        }
        let code = json["code"] as? Int ?? 200
        guard code == 200 else { throw NetEaseError.unknown("识别请求失败（\(code)）") }
        let results = (json["data"] as? [String: Any])?["result"] as? [[String: Any]] ?? []
        return results.compactMap { item in
            guard let songDict = item["song"] as? [String: Any], let song = Song(json: songDict) else { return nil }
            return AudioMatchCandidate(song: song, startTime: item["startTime"] as? Int)
        }
    }
}

// MARK: - 录音错误

enum SongRecognitionRecordingError: LocalizedError {
    case microphonePermissionDenied
    case microphoneUnavailable
    case recordingFailed(String)
    case recordingTimedOut
    case conversionFailed
    case captureUnavailable
    case captureTimedOut

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "麦克风权限被拒绝，请在系统设置中允许 Beans 使用麦克风"
        case .microphoneUnavailable:
            return "麦克风当前不可用"
        case .recordingFailed(let message):
            return "录音失败：\(message)"
        case .recordingTimedOut:
            return "录音超时，请重试"
        case .conversionFailed:
            return "音频转换失败"
        case .captureUnavailable:
            return "当前音频捕获方式不可用"
        case .captureTimedOut:
            return "音频捕获超时，请重试"
        }
    }

    var opensSystemSettings: Bool {
        if case .microphonePermissionDenied = self { return true }
        return false
    }
}

// MARK: - 采样缓冲（同 MeloX SongRecognitionSampleBuffer）

struct SongRecognitionRawAudioSnapshot: Sendable {
    let samples: [Float]
    let totalFrameCount: Int64
    let reachedLimit: Bool
}

final class SongRecognitionSampleBuffer: @unchecked Sendable {
    private let retainedFrameCount: Int
    private let stoppingFrameCount: Int64?
    private let lock = NSLock()
    private var storage: [Float]
    private var writeIndex = 0
    private var storedFrameCount = 0
    private var totalFrameCount: Int64 = 0
    private var didSignalLimit = false

    init(retainedFrameCount: Int, stoppingFrameCount: Int?) {
        self.retainedFrameCount = retainedFrameCount
        self.stoppingFrameCount = stoppingFrameCount.map(Int64.init)
        storage = Array(repeating: 0, count: retainedFrameCount)
    }

    /// 返回 true 仅一次：达到设定的录音时长上限时。
    func append(_ buffer: AVAudioPCMBuffer) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard retainedFrameCount > 0, let channelData = buffer.floatChannelData else { return false }

        let availableFrameCount = Int(buffer.frameLength)
        let framesToCopy: Int
        if let stoppingFrameCount {
            let remainingFrameCount = max(stoppingFrameCount - totalFrameCount, 0)
            framesToCopy = min(availableFrameCount, Int(remainingFrameCount))
        } else {
            framesToCopy = availableFrameCount
        }
        guard framesToCopy > 0 else { return false }

        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 0 else { return false }

        for frame in 0..<framesToCopy {
            let sample: Float
            if channelCount == 1 {
                sample = channelData[0][frame]
            } else {
                var mixedSample: Float = 0
                for channel in 0..<channelCount {
                    mixedSample += buffer.format.isInterleaved
                        ? channelData[0][frame * channelCount + channel]
                        : channelData[channel][frame]
                }
                sample = mixedSample / Float(channelCount)
            }

            storage[writeIndex] = sample
            writeIndex += 1
            if writeIndex == retainedFrameCount {
                writeIndex = 0
            }
            storedFrameCount = min(storedFrameCount + 1, retainedFrameCount)
        }
        totalFrameCount += Int64(framesToCopy)

        guard let stoppingFrameCount,
              totalFrameCount == stoppingFrameCount,
              !didSignalLimit else {
            return false
        }
        didSignalLimit = true
        return true
    }

    func snapshot() -> SongRecognitionRawAudioSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let samples: [Float]
        if storedFrameCount < retainedFrameCount {
            samples = Array(storage.prefix(storedFrameCount))
        } else {
            samples = Array(storage[writeIndex...]) + Array(storage[..<writeIndex])
        }
        return SongRecognitionRawAudioSnapshot(
            samples: samples,
            totalFrameCount: totalFrameCount,
            reachedLimit: stoppingFrameCount == totalFrameCount
        )
    }
}

// MARK: - 捕获音频缓冲（ReplayKit CMSampleBuffer -> PCM，同 MeloX）

@MainActor
protocol SongRecognitionAudioCapture: AnyObject {
    var failure: (any Error)? { get }
    func start() async throws
    func stop()
}

final class SongRecognitionCapturedAudioBuffer: @unchecked Sendable {
    static let sampleRate = 48_000.0
    private let recordingBuffer: SongRecognitionSampleBuffer
    private let lock = NSLock()
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    )!
    private var converter: AVAudioConverter?

    init(recordingBuffer: SongRecognitionSampleBuffer) {
        self.recordingBuffer = recordingBuffer
    }

    func append(_ sample: CMSampleBuffer) throws -> Bool {
        guard sample.isValid, sample.numSamples > 0 else { return false }
        return try sample.withAudioBufferList { buffers, _ in
            guard let description = sample.formatDescription else {
                throw SongRecognitionRecordingError.conversionFailed
            }
            let format = AVAudioFormat(cmAudioFormatDescription: description)
            guard format.sampleRate > 0, format.channelCount > 0,
                  let input = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: buffers.unsafePointer) else {
                throw SongRecognitionRecordingError.conversionFailed
            }
            if format.commonFormat == .pcmFormatFloat32, format.sampleRate == Self.sampleRate {
                return recordingBuffer.append(input)
            }

            lock.lock()
            defer { lock.unlock() }
            if converter?.inputFormat != format {
                converter = AVAudioConverter(from: format, to: outputFormat)
                converter?.primeMethod = .none
            }
            let capacity = AVAudioFrameCount(
                (Double(input.frameLength) * Self.sampleRate / format.sampleRate).rounded(.up)
            ) + 32
            guard let converter,
                  let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw SongRecognitionRecordingError.conversionFailed
            }
            var suppliedInput = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if suppliedInput {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedInput = true
                inputStatus.pointee = .haveData
                return input
            }
            guard status != .error, error == nil else {
                throw SongRecognitionRecordingError.conversionFailed
            }
            return recordingBuffer.append(output)
        }
    }
}

// MARK: - 应用音频捕获（ReplayKit，同 MeloX SongRecognitionAppAudioCapture）

@MainActor
final class SongRecognitionAppAudioCapture: SongRecognitionAudioCapture {
    private let buffer: SongRecognitionCapturedAudioBuffer
    private let recorder = RPScreenRecorder.shared()
    private var ownsRecording = false
    private(set) var failure: (any Error)?

    init(buffer: SongRecognitionCapturedAudioBuffer) {
        self.buffer = buffer
    }

    func start() async throws {
        guard recorder.isAvailable, !recorder.isRecording else {
            throw SongRecognitionRecordingError.captureUnavailable
        }
        ownsRecording = true
        recorder.isMicrophoneEnabled = false
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                recorder.startCapture { [weak self, buffer] sample, type, error in
                    if let error {
                        Task { @MainActor [weak self] in
                            self?.failure = error
                            self?.stop()
                        }
                        return
                    }
                    guard type == .audioApp else { return }
                    do {
                        if try buffer.append(sample) {
                            Task { @MainActor [weak self] in self?.stop() }
                        }
                    } catch {
                        Task { @MainActor [weak self] in
                            self?.failure = error
                            self?.stop()
                        }
                    }
                } completionHandler: { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            try Task.checkCancellation()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        guard ownsRecording, recorder.isRecording else { return }
        ownsRecording = false
        recorder.stopCapture { _ in }
    }
}

// MARK: - 录音器（同 MeloX SongRecognitionAudioRecorder 的麦克风 + 捕获两路）

struct SongRecognitionAudioSnapshot {
    let samples: [Float]
    let duration: Int
    let totalDuration: Int
    let reachedLimit: Bool
}

@MainActor
final class SongRecognitionAudioRecorder {
    static let fingerprintSampleRate = 8_000.0
    private static let continuousWindowDuration = 9

    private var engine: AVAudioEngine?
    private var sampleBuffer: SongRecognitionSampleBuffer?
    private var sourceSampleRate = 0.0
    private var isTapInstalled = false
    private var isSessionActive = false
    private var shouldPreservePlaybackSession = false
    private var audioCapture: (any SongRecognitionAudioCapture)?

    func start(maximumDuration: Int?, source: SongRecognitionAudioSource) async throws {
        stop()
        resetCapture()
        shouldPreservePlaybackSession = false

        if let maximumDuration, maximumDuration <= 0 {
            throw SongRecognitionRecordingError.conversionFailed
        }

        if source != .microphone {
            let recordingBuffer = makeSampleBuffer(
                sampleRate: SongRecognitionCapturedAudioBuffer.sampleRate,
                maximumDuration: maximumDuration
            )
            let buffer = SongRecognitionCapturedAudioBuffer(recordingBuffer: recordingBuffer)
            let capture = try makeAudioCapture(source: source, buffer: buffer)
            audioCapture = capture
            do { try await capture.start() }
            catch {
                stop()
                resetCapture()
                throw error
            }
            return
        }

        try await ensureMicrophonePermission()
        try Task.checkCancellation()

        let session = AVAudioSession.sharedInstance()
        do {
            let category: AVAudioSession.Category =
                maximumDuration == nil ? .playAndRecord : .record
            let options: AVAudioSession.CategoryOptions =
                maximumDuration == nil
                ? [.allowBluetoothHFP, .defaultToSpeaker]
                : [.allowBluetoothHFP]
            try session.setCategory(category, mode: .measurement, options: options)
            try session.setActive(true)
            isSessionActive = true
        } catch {
            throw SongRecognitionRecordingError.recordingFailed(error.localizedDescription)
        }

        let recordingEngine = AVAudioEngine()
        let inputNode = recordingEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              inputFormat.commonFormat == .pcmFormatFloat32 else {
            stopAudioSession()
            throw SongRecognitionRecordingError.microphoneUnavailable
        }

        let recordingBuffer = makeSampleBuffer(
            sampleRate: inputFormat.sampleRate,
            maximumDuration: maximumDuration
        )

        engine = recordingEngine

        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: inputFormat) { [weak self] buffer, _ in
            guard recordingBuffer.append(buffer) else { return }
            Task { @MainActor [weak self] in
                guard let self, sampleBuffer === recordingBuffer else { return }
                stopEngine()
                stopAudioSession()
            }
        }
        isTapInstalled = true

        do {
            recordingEngine.prepare()
            try recordingEngine.start()
        } catch {
            stop()
            resetCapture()
            throw SongRecognitionRecordingError.recordingFailed(error.localizedDescription)
        }
    }

    func snapshot() throws -> SongRecognitionAudioSnapshot? {
        if let failure = audioCapture?.failure { throw failure }
        guard let sampleBuffer, sourceSampleRate > 0 else { return nil }

        let rawSnapshot = sampleBuffer.snapshot()
        let availableDuration = Int(Double(rawSnapshot.samples.count) / sourceSampleRate)
        let totalDuration = Int(Double(rawSnapshot.totalFrameCount) / sourceSampleRate)
        guard availableDuration > 0 else { return nil }

        let sourceFrameCount = min(
            rawSnapshot.samples.count,
            Int((Double(availableDuration) * sourceSampleRate).rounded(.down))
        )
        let sourceSamples = Array(rawSnapshot.samples.suffix(sourceFrameCount))
        let targetFrameCount = availableDuration * Int(Self.fingerprintSampleRate)

        return SongRecognitionAudioSnapshot(
            samples: try resample(
                sourceSamples,
                sourceSampleRate: sourceSampleRate,
                targetFrameCount: targetFrameCount
            ),
            duration: availableDuration,
            totalDuration: totalDuration,
            reachedLimit: rawSnapshot.reachedLimit
        )
    }

    func cancel() {
        stop()
    }

    func prepareForConcurrentPlayback() {
        shouldPreservePlaybackSession = true
    }

    func stop() {
        stopEngine()
        stopAudioSession()
    }

    private func stopEngine() {
        audioCapture?.stop()
        audioCapture = nil
        guard let engine else { return }
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        engine.stop()
        self.engine = nil
    }

    private func stopAudioSession() {
        guard isSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        if shouldPreservePlaybackSession {
            // 交还给 Beans 播放器：恢复为播放类别，PlayerManager 在起播时还会自行配置。
            try? session.setCategory(.playback, mode: .default)
            try? session.setActive(true)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        isSessionActive = false
    }

    private func resetCapture() {
        sampleBuffer = nil
        sourceSampleRate = 0
    }

    private func makeSampleBuffer(sampleRate: Double, maximumDuration: Int?) -> SongRecognitionSampleBuffer {
        let duration = maximumDuration ?? Self.continuousWindowDuration
        let buffer = SongRecognitionSampleBuffer(
            retainedFrameCount: Int((Double(duration) * sampleRate).rounded(.up)),
            stoppingFrameCount: maximumDuration.map { Int((Double($0) * sampleRate).rounded(.up)) }
        )
        sourceSampleRate = sampleRate
        sampleBuffer = buffer
        return buffer
    }

    private func makeAudioCapture(
        source: SongRecognitionAudioSource,
        buffer: SongRecognitionCapturedAudioBuffer
    ) throws -> any SongRecognitionAudioCapture {
        // 系统音频捕获在 MeloX 中依赖 ScreenCaptureKit（iOS 27），iOS 18 不可用。
        guard source == .appAudio else { throw SongRecognitionRecordingError.captureUnavailable }
        return SongRecognitionAppAudioCapture(buffer: buffer)
    }

    private func ensureMicrophonePermission() async throws {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return
        case .denied:
            throw SongRecognitionRecordingError.microphonePermissionDenied
        case .undetermined:
            let granted = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { isGranted in
                    continuation.resume(returning: isGranted)
                }
            }
            guard granted else {
                throw SongRecognitionRecordingError.microphonePermissionDenied
            }
        @unknown default:
            throw SongRecognitionRecordingError.microphonePermissionDenied
        }
    }

    private func resample(
        _ samples: [Float],
        sourceSampleRate: Double,
        targetFrameCount: Int
    ) throws -> [Float] {
        guard !samples.isEmpty, targetFrameCount > 0 else {
            throw SongRecognitionRecordingError.conversionFailed
        }

        if sourceSampleRate == Self.fingerprintSampleRate {
            return normalizedFrameCount(samples, targetFrameCount: targetFrameCount)
        }

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: 1,
            interleaved: false
        ),
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.fingerprintSampleRate,
            channels: 1,
            interleaved: false
        ),
        let inputBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ),
        let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(targetFrameCount + 32)
        ),
        let inputChannel = inputBuffer.floatChannelData?[0],
        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw SongRecognitionRecordingError.conversionFailed
        }

        samples.withUnsafeBufferPointer { source in
            guard let baseAddress = source.baseAddress else { return }
            inputChannel.update(from: baseAddress, count: samples.count)
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        converter.primeMethod = .none

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error,
              conversionError == nil,
              let outputChannel = outputBuffer.floatChannelData?[0] else {
            throw SongRecognitionRecordingError.conversionFailed
        }

        let output = Array(
            UnsafeBufferPointer(start: outputChannel, count: Int(outputBuffer.frameLength))
        )
        return normalizedFrameCount(output, targetFrameCount: targetFrameCount)
    }

    private func normalizedFrameCount(_ samples: [Float], targetFrameCount: Int) -> [Float] {
        if samples.count >= targetFrameCount {
            return Array(samples.prefix(targetFrameCount))
        }
        return samples + Array(repeating: 0, count: targetFrameCount - samples.count)
    }
}

// MARK: - 指纹生成（网易 AFP WASM 运行时，同 MeloX NeteaseAudioFingerprintGenerator）

enum NeteaseAudioFingerprintError: LocalizedError {
    case resourcesMissing
    case runtimeFailed(String)
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .resourcesMissing:
            return "听歌识曲指纹资源缺失"
        case .runtimeFailed(let message):
            return "指纹生成失败：\(message)"
        case .invalidResult:
            return "指纹结果无效"
        }
    }
}

@MainActor
final class NeteaseAudioFingerprintGenerator: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var preparationContinuation: CheckedContinuation<Void, Error>?
    private var isPrepared = false

    func generate(from samples: [Float]) async throws -> String {
        guard !samples.isEmpty else {
            throw NeteaseAudioFingerprintError.invalidResult
        }

        try await prepare()
        try Task.checkCancellation()
        guard let webView else {
            throw NeteaseAudioFingerprintError.invalidResult
        }

        let pcmData = samples.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Float>.size)
        }

        let script = """
        const bytes = Uint8Array.from(
            atob(pcm),
            character => character.charCodeAt(0)
        );
        const sampleCount = Math.floor(bytes.byteLength / 4);
        const floatSamples = new Float32Array(
            bytes.buffer,
            bytes.byteOffset,
            sampleCount
        );
        return await GenerateFP(floatSamples);
        """

        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(
                script,
                arguments: ["pcm": pcmData.base64EncodedString()],
                in: nil,
                contentWorld: .page
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw NeteaseAudioFingerprintError.runtimeFailed(error.localizedDescription)
        }

        try Task.checkCancellation()
        guard let fingerprint = result as? String,
              let decoded = Data(base64Encoded: fingerprint),
              !decoded.isEmpty else {
            throw NeteaseAudioFingerprintError.invalidResult
        }
        return fingerprint
    }

    private func prepare() async throws {
        if isPrepared { return }
        guard preparationContinuation == nil else {
            throw NeteaseAudioFingerprintError.runtimeFailed("指纹运行时正在初始化")
        }

        guard let wasmSource = bundledText(named: "afp.wasm", extension: "js"),
              let fingerprintSource = bundledText(named: "afp", extension: "js") else {
            throw NeteaseAudioFingerprintError.resourcesMissing
        }

        let prelude = """
        globalThis.require = function(path) {
            if (path.includes('logger')) {
                return {
                    info: function() {},
                    warn: function() {},
                    error: function() {}
                };
            }
            if (path.includes('afp.wasm')) {
                return { WASM_BINARY: WASM_BINARY };
            }
            throw new Error('Unsupported local module: ' + path);
        };
        """

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: [prelude, wasmSource, fingerprintSource].joined(separator: "\n"),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let runtimeWebView = WKWebView(frame: .zero, configuration: configuration)
        runtimeWebView.navigationDelegate = self
        webView = runtimeWebView

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                preparationContinuation = continuation
                runtimeWebView.loadHTMLString(
                    "<!doctype html><html><body></body></html>",
                    baseURL: nil
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPreparation()
            }
        }
    }

    private func bundledText(named name: String, extension fileExtension: String) -> String? {
        let candidateURLs = [
            Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "AudioFingerprint"),
            Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "Resources/AudioFingerprint"),
            Bundle.main.url(forResource: name, withExtension: fileExtension),
        ]
        guard let url = candidateURLs.compactMap({ $0 }).first else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func cancelPreparation() {
        webView?.stopLoading()
        webView = nil
        finishPreparation(.failure(CancellationError()))
    }

    private func finishPreparation(_ result: Result<Void, Error>) {
        guard let continuation = preparationContinuation else { return }
        preparationContinuation = nil

        switch result {
        case .success:
            isPrepared = true
            continuation.resume()
        case .failure(let error):
            isPrepared = false
            webView = nil
            continuation.resume(throwing: error)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishPreparation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishPreparation(.failure(NeteaseAudioFingerprintError.runtimeFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishPreparation(.failure(NeteaseAudioFingerprintError.runtimeFailed(error.localizedDescription)))
    }
}

// MARK: - 识别状态机（同 MeloX SongRecognitionStore）

enum SongRecognitionPhase: Equatable {
    case ready
    case requestingPermission
    case listening
    case matching
    case results
    case noMatch
    case failed(SongRecognitionFailure)

    var isWorking: Bool {
        switch self {
        case .requestingPermission, .listening, .matching: return true
        case .ready, .results, .noMatch, .failed: return false
        }
    }
}

struct SongRecognitionFailure: Equatable {
    let message: String
    let opensSystemSettings: Bool
}

@MainActor
final class SongRecognitionStore: ObservableObject {
    private static let queryInterval = 3
    private static let maximumStoredResults = 100

    @Published private(set) var phase: SongRecognitionPhase = .ready
    @Published private(set) var results: [SongRecognitionResult] = []
    @Published private(set) var isContinuous = false
    @Published private(set) var audioSource: SongRecognitionAudioSource = .microphone

    private let recorder = SongRecognitionAudioRecorder()
    private let fingerprintGenerator = NeteaseAudioFingerprintGenerator()
    private var recognitionTask: Task<Void, Never>?
    private var generation = 0

    func start(duration: SongRecognitionDuration, source: SongRecognitionAudioSource) {
        guard !phase.isWorking else { return }

        let previousTask = recognitionTask
        previousTask?.cancel()
        recorder.cancel()
        generation &+= 1
        let currentGeneration = generation
        results = []
        isContinuous = duration.isContinuous
        audioSource = source
        phase = .requestingPermission

        recognitionTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard let self else { return }
            guard !Task.isCancelled, generation == currentGeneration else { return }
            await recognize(duration: duration, source: source, generation: currentGeneration)
        }
    }

    func stopContinuousRecognition() {
        guard isContinuous, phase.isWorking else { return }
        generation &+= 1
        recognitionTask?.cancel()
        recorder.cancel()
        phase = results.isEmpty ? .noMatch : .results
    }

    func prepareForResultPlayback() {
        guard isContinuous, phase.isWorking else { return }
        recorder.prepareForConcurrentPlayback()
    }

    func cancel() {
        let wasWorking = phase.isWorking
        generation &+= 1
        recognitionTask?.cancel()
        recorder.cancel()
        if wasWorking {
            phase = .ready
        }
    }

    private func recognize(
        duration: SongRecognitionDuration,
        source: SongRecognitionAudioSource,
        generation currentGeneration: Int
    ) async {
        defer {
            if generation == currentGeneration {
                recognitionTask = nil
            }
        }

        do {
            try await recorder.start(maximumDuration: duration.maximumDuration, source: source)
            defer {
                if generation == currentGeneration { recorder.stop() }
            }
            try Task.checkCancellation()
            guard generation == currentGeneration else { return }

            phase = .listening
            var nextQueryDuration = min(Self.queryInterval, duration.maximumDuration ?? Self.queryInterval)

            while true {
                var snapshot = try await waitForSnapshot(minimumTotalDuration: nextQueryDuration)

                try Task.checkCancellation()
                guard generation == currentGeneration else { return }

                if source != .microphone {
                    // 其他应用音频捕获时保持捕获，WebKit 指纹运行时需要在前台执行。
                    while UIApplication.shared.applicationState != .active {
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    try Task.checkCancellation()
                    if let latest = try recorder.snapshot() { snapshot = latest }
                }

                if snapshot.reachedLimit {
                    recorder.stop()
                    phase = .matching
                }

                let fingerprint = try await fingerprintGenerator.generate(from: snapshot.samples)
                let candidates = try await NetEaseAPI.shared.audioMatches(
                    fingerprint: fingerprint,
                    duration: snapshot.duration
                )

                try Task.checkCancellation()
                guard generation == currentGeneration else { return }

                let immediateResults = candidateResults(from: candidates)
                if !immediateResults.isEmpty {
                    if duration.isContinuous {
                        mergeContinuousResults(immediateResults)
                        phase = .listening
                    } else {
                        recorder.stop()
                        results = immediateResults
                        phase = .results
                    }

                    let detailedResults = await resolvedResults(from: immediateResults)
                    guard generation == currentGeneration else { return }
                    if duration.isContinuous {
                        mergeContinuousResults(detailedResults)
                    } else {
                        results = detailedResults
                        return
                    }
                }

                if snapshot.reachedLimit {
                    phase = .noMatch
                    return
                }

                phase = .listening
                let nextDuration = snapshot.totalDuration + Self.queryInterval
                nextQueryDuration = min(duration.maximumDuration ?? nextDuration, nextDuration)
            }
        } catch is CancellationError {
            guard generation == currentGeneration else { return }
            phase = .ready
        } catch {
            guard generation == currentGeneration else { return }
            let recordingError = error as? SongRecognitionRecordingError
            phase = .failed(
                SongRecognitionFailure(
                    message: error.localizedDescription,
                    opensSystemSettings: recordingError?.opensSystemSettings ?? false
                )
            )
        }
    }

    private func waitForSnapshot(minimumTotalDuration: Int) async throws -> SongRecognitionAudioSnapshot {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(Self.queryInterval + 4))

        while true {
            try Task.checkCancellation()
            if let snapshot = try recorder.snapshot(),
               snapshot.totalDuration >= minimumTotalDuration || snapshot.reachedLimit {
                return snapshot
            }
            guard clock.now < deadline else {
                throw audioSource != .microphone
                    ? SongRecognitionRecordingError.captureTimedOut
                    : SongRecognitionRecordingError.recordingTimedOut
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func candidateResults(from candidates: [AudioMatchCandidate]) -> [SongRecognitionResult] {
        var results: [SongRecognitionResult] = []
        var seenIDs = Set<Int>()

        for candidate in candidates
        where candidate.song.id > 0 && seenIDs.insert(candidate.song.id).inserted {
            results.append(
                SongRecognitionResult(song: candidate.song, startTimeMilliseconds: candidate.startTime)
            )
        }
        return results
    }

    private func resolvedResults(from results: [SongRecognitionResult]) async -> [SongRecognitionResult] {
        let orderedIDs = results.map(\.id)
        guard !orderedIDs.isEmpty else { return [] }

        let detailedSongs = try? await NetEaseAPI.shared.songDetails(ids: orderedIDs)
        var detailByID: [Int: Song] = [:]
        for song in detailedSongs ?? [] {
            detailByID[song.id] = song
        }

        return results.map { result in
            var resolvedResult = result
            if let detailedSong = detailByID[result.id] {
                resolvedResult.song = detailedSong
            }
            return resolvedResult
        }
    }

    private func mergeContinuousResults(_ newResults: [SongRecognitionResult]) {
        for newResult in newResults.reversed() {
            if let index = results.firstIndex(where: { $0.id == newResult.id }) {
                results[index] = newResult
            } else {
                results.insert(newResult, at: 0)
            }
        }

        if results.count > Self.maximumStoredResults {
            results.removeLast(results.count - Self.maximumStoredResults)
        }
    }
}

import AVFoundation
import Darwin
import Foundation
import UIKit
import os

/// Feeds the iPad microphone to the guest's PulseAudio source `ipad_mic`.
///
/// The guest runs `module-pipe-source` on the FIFO `/tmp/ishaudio/mic` (see
/// `themes/guest/audio/ishaudio.pa`), which, like the output FIFO, is a host FIFO under
/// `<guest root>/data`. PulseAudio reads it only while a client records, and that is
/// what drives the microphone:
///
/// * Idle, one 10 ms probe chunk of silence sits in the FIFO. Once it has been read
///   (FIONREAD on our read-only fd drops to 0), a Linux app is recording: the microphone
///   starts, asking for permission the first time.
/// * While capturing, 10 ms chunks of s16le mono 48 kHz go into the FIFO. When more than
///   50 ms stays unread for a second, recording has stopped: the FIFO is drained, the
///   microphone stops and the probe goes back in.
///
/// Until the microphone delivers (permission prompt, denied, interrupted, app in the
/// background) the guest gets silence at real time, so its clients never stall.
/// `tests/av/fake_mic_host.py` implements the same protocol with a sine wave.
final class ISHMicBridge: @unchecked Sendable {
    static let shared = ISHMicBridge()

    static let sampleRate = 48_000.0
    static let guestFIFOPath = "tmp/ishaudio/mic"

    private static let chunkFrames = 480
    private static let bytesPerFrame = MemoryLayout<Int16>.size
    // A Darwin pipe holds 8 KB (~85 ms of s16 mono), so the threshold stays below that.
    private static let backlogStopBytes = Int(sampleRate * 0.05) * bytesPerFrame
    private static let backlogGrace: TimeInterval = 1
    private static let idlePoll: TimeInterval = 0.05
    private static let writePoll: TimeInterval = 0.005
    // FIONREAD, _IOR('f', 127, int); Swift cannot import the macro.
    private static let fionread: UInt = 0x4004_667F

    var isCapturing: Bool { lock.withLockUnchecked { capturing } }

    private let lock = OSAllocatedUnfairLock()
    // Guarded by `lock`: shared with the audio I/O thread.
    private var capturing = false
    private var captured = [Float](repeating: 0, count: Int(sampleRate))
    private var capturedCount = 0
    private var capturedRate = 0.0
    private var micRunning = false

    private let log = Logger(subsystem: "app.ish.desktop", category: "mic")
    private let engineQueue = DispatchQueue(label: "ishmic.engine")
    // Owned by engineQueue.
    private var engine: AVAudioEngine?
    private var interrupted = false
    private var deniedNoticeShown = false
    // Owned by the FIFO thread.
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var thread: Thread?

    private init() {}

    /// Starts watching the guest for the microphone FIFO. Idempotent; nothing touches the
    /// microphone, the audio session or the permission prompt until a Linux app records.
    func start(guestRoot: URL?) {
        guard thread == nil, let guestRoot else { return }
        let fifo = guestRoot.appendingPathComponent(Self.guestFIFOPath).path
        observeSession()
        let thread = Thread { [weak self] in self?.fifoLoop(path: fifo) }
        thread.name = "ishmic.fifo"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// The category the shared audio session needs: recording adds input to playback.
    static func configureSession(_ session: AVAudioSession, recording: Bool) throws {
        if recording {
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP])
        } else {
            try session.setCategory(.playback, mode: .default, options: [])
        }
    }

    // MARK: - FIFO protocol

    private func fifoLoop(path: String) {
        var readFD: Int32 = -1
        var writeFD: Int32 = -1
        var inode: ino_t = 0
        var active = false
        var backlogSince: TimeInterval?
        var nextSilence: TimeInterval = 0
        var pendingByte: UInt8?

        func closeFIFO() {
            if readFD >= 0 { close(readFD) }
            if writeFD >= 0 { close(writeFD) }
            readFD = -1
            writeFD = -1
            pendingByte = nil
        }

        while true {
            var info = stat()
            let exists = stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO
            if readFD >= 0 && (!exists || info.st_ino != inode) {
                closeFIFO()
                if active {
                    active = false
                    endCapture()
                }
            }
            if readFD < 0 {
                guard exists else {
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                // Darwin answers FIONREAD only on a read-only FIFO fd, so occupancy is
                // measured through one, and audio goes in through a write-only one.
                readFD = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
                writeFD = readFD >= 0 ? open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC) : -1
                guard writeFD >= 0 else {
                    closeFIFO()
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                inode = info.st_ino
                writeSilence(writeFD, frames: Self.chunkFrames, pendingByte: &pendingByte)
                log.info("connected to \(path, privacy: .public)")
            }

            var pending: Int32 = 0
            _ = withUnsafeMutablePointer(to: &pending) { ioctl(readFD, Self.fionread, $0) }
            let now = ProcessInfo.processInfo.systemUptime
            if !active {
                guard pending == 0 else {
                    Thread.sleep(forTimeInterval: Self.idlePoll)
                    continue
                }
                active = true
                backlogSince = nil
                nextSilence = now
                beginCapture()
            }

            if Int(pending) > Self.backlogStopBytes {
                let since = backlogSince ?? now
                backlogSince = since
                if now - since > Self.backlogGrace {
                    drain(readFD)
                    pendingByte = nil
                    active = false
                    endCapture()
                    writeSilence(writeFD, frames: Self.chunkFrames, pendingByte: &pendingByte)
                    continue
                }
            } else {
                backlogSince = nil
            }

            if lock.withLockUnchecked({ micRunning }) {
                writeCaptured(writeFD, pendingByte: &pendingByte)
                nextSilence = now
            } else {
                while nextSilence <= now {
                    writeSilence(writeFD, frames: Self.chunkFrames, pendingByte: &pendingByte)
                    nextSilence += Double(Self.chunkFrames) / Self.sampleRate
                }
            }
            Thread.sleep(forTimeInterval: Self.writePoll)
        }
    }

    private func drain(_ fd: Int32) {
        var scratch = [UInt8](repeating: 0, count: 16 * 1024)
        while scratch.withUnsafeMutableBytes({ read(fd, $0.baseAddress, $0.count) }) > 0 {}
    }

    /// Writes without blocking. A full pipe drops the rest, except that a sample already
    /// half written is finished on the next write so the stream stays aligned.
    private func write(_ fd: Int32, _ bytes: UnsafeRawBufferPointer, pendingByte: inout UInt8?) {
        if var byte = pendingByte {
            guard Darwin.write(fd, &byte, 1) == 1 else { return }
            pendingByte = nil
        }
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        let written = Darwin.write(fd, base, bytes.count)
        if written > 0 && written % Self.bytesPerFrame != 0 {
            pendingByte = bytes[written]
        }
    }

    private func writeSilence(_ fd: Int32, frames: Int, pendingByte: inout UInt8?) {
        let zeros = [UInt8](repeating: 0, count: frames * Self.bytesPerFrame)
        zeros.withUnsafeBytes { write(fd, $0, pendingByte: &pendingByte) }
    }

    /// Converts what the microphone delivered since the last call to s16 mono 48 kHz.
    private func writeCaptured(_ fd: Int32, pendingByte: inout UInt8?) {
        let (samples, rate) = lock.withLockUnchecked { () -> ([Float], Double) in
            let taken = Array(captured[0..<capturedCount])
            capturedCount = 0
            return (taken, capturedRate)
        }
        guard !samples.isEmpty, rate > 0,
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1,
                                              interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.sampleRate,
                                               channels: 1, interleaved: true) else { return }
        if converter == nil || converterInput != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            converterInput = inputFormat
        }
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                            frameCapacity: AVAudioFrameCount(Double(samples.count) * Self.sampleRate / rate) + 64)
        else { return }
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        input.frameLength = AVAudioFrameCount(samples.count)
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, output.frameLength > 0, let data = output.int16ChannelData else { return }
        let bytes = UnsafeRawBufferPointer(start: data[0], count: Int(output.frameLength) * Self.bytesPerFrame)
        write(fd, bytes, pendingByte: &pendingByte)
    }

    // MARK: - Microphone

    /// LinPad is in front again: an interruption whose end iPadOS never reported must not
    /// leave a recording Linux app with silence.
    func resumeAfterBackground() {
        engineQueue.async {
            guard self.interrupted else { return }
            self.interrupted = false
            self.startMicIfAllowed()
        }
    }

    private func beginCapture() {
        lock.withLockUnchecked { capturing = true }
        log.info("a Linux app is recording")
        engineQueue.async { self.startMicIfAllowed() }
    }

    private func endCapture() {
        lock.withLockUnchecked { capturing = false }
        log.info("recording ended")
        engineQueue.async { self.stopMic() }
    }

    private func startMicIfAllowed() {
        guard isCapturing, engine == nil, !interrupted else { return }
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            startMic()
        case .undetermined:
            AVAudioApplication.requestRecordPermission { granted in
                self.engineQueue.async {
                    if granted {
                        self.startMic()
                    } else {
                        self.showDeniedNotice()
                    }
                }
            }
        default:
            showDeniedNotice()
        }
    }

    private func startMic() {
        guard isCapturing, engine == nil, !interrupted else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try Self.configureSession(session, recording: true)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        } catch {
            log.error("audio session: \(error.localizedDescription, privacy: .public)")
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            log.error("no microphone input")
            return
        }
        // A sink node gets each I/O cycle (~10 ms); an input tap would batch ~100 ms.
        let sink = AVAudioSinkNode { [unowned self] _, frameCount, bufferList in
            self.receive(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList)),
                         frames: Int(frameCount))
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        engine.prepare()
        lock.withLockUnchecked {
            capturedRate = format.sampleRate
            capturedCount = 0
        }
        do {
            try engine.start()
        } catch {
            log.error("microphone start: \(error.localizedDescription, privacy: .public)")
            return
        }
        self.engine = engine
        lock.withLockUnchecked { micRunning = true }
        log.info("microphone on at \(format.sampleRate) Hz")
    }

    private func stopMic() {
        lock.withLockUnchecked {
            micRunning = false
            capturedCount = 0
        }
        guard let engine else { return }
        self.engine = nil
        engine.stop()
        let session = AVAudioSession.sharedInstance()
        if ISHAudioBridge.shared.stats.isPlaying {
            try? Self.configureSession(session, recording: false)
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        log.info("microphone off")
    }

    /// Audio I/O thread: copies the first channel, nothing else.
    private func receive(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard let first = buffers.first, let data = first.mData?.assumingMemoryBound(to: Float.self) else { return }
        lock.withLockUnchecked {
            let room = captured.count - capturedCount
            let n = min(frames, room)
            captured.withUnsafeMutableBufferPointer { dest in
                (dest.baseAddress! + capturedCount).update(from: data, count: n)
            }
            capturedCount += n
        }
    }

    private func showDeniedNotice() {
        guard !deniedNoticeShown else { return }
        deniedNoticeShown = true
        log.info("microphone permission denied; sending silence")
        ISHPrivacyNotice.show(title: "Microphone Access Is Off",
                              message: "A Linux app wants to record audio, but LinPad isn't allowed to use the "
                                  + "microphone, so the app hears silence. You can allow it in Settings.")
    }

    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                           queue: nil) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            engineQueue.async {
                switch type {
                case .began:
                    self.interrupted = true
                    self.stopMic()
                case .ended:
                    self.interrupted = false
                    self.startMicIfAllowed()
                @unknown default:
                    break
                }
            }
        }
        center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session,
                           queue: nil) { [weak self] _ in
            guard let self else { return }
            engineQueue.async {
                self.interrupted = false
                self.stopMic()
                self.startMicIfAllowed()
            }
        }
        // Route or format changes (headset plugged in) stop the engine; rebuild it.
        center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
            guard let self else { return }
            engineQueue.async {
                guard let engine = self.engine, note.object as AnyObject? === engine else { return }
                self.stopMic()
                self.startMicIfAllowed()
            }
        }
    }
}

/// One alert per denied permission per launch, telling the user why a Linux app gets
/// silence or black frames and where to change it.
enum ISHPrivacyNotice {
    static func show(title: String, message: String) {
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes
                    .compactMap({ $0 as? UIWindowScene })
                    .first(where: { $0.activationState == .foregroundActive }),
                  var top = scene.keyWindow?.rootViewController else { return }
            while let presented = top.presentedViewController { top = presented }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            })
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            top.present(alert, animated: true)
        }
    }
}

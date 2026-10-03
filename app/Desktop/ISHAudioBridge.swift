import AVFoundation
import Darwin
import Foundation
import os

/// Plays the guest's PulseAudio output on the iPad.
///
/// The guest runs PulseAudio with a `module-pipe-sink` that writes raw PCM
/// (s16le, 48 kHz, stereo) into the FIFO `/tmp/ishaudio/pcm` (see
/// `themes/audio/ishaudio-session`). In iSH a guest FIFO is a host FIFO under
/// `<guest root>/data`, so this process reads it directly: a reader thread moves
/// bytes into a ring buffer, and an `AVAudioSourceNode` drains it through a small
/// jitter buffer.
///
/// The guest owns the FIFO: files the host creates have no fakefs metadata and would be
/// invisible to the guest, so the bridge only ever opens what PulseAudio created.
final class ISHAudioBridge: @unchecked Sendable {
    static let shared = ISHAudioBridge()

    static let sampleRate = 48_000.0
    static let channels = 2
    static let guestFIFOPath = "tmp/ishaudio/pcm"

    struct Stats: Sendable {
        var framesReceived: UInt64 = 0
        var framesPlayed: UInt64 = 0
        var framesDropped: UInt64 = 0
        var underruns: UInt64 = 0
        var bufferedMilliseconds = 0.0
        var targetMilliseconds = 0.0
        var isPlaying = false
    }

    /// 0...1, applied on the host after the guest's own mixer.
    var volume: Float {
        get { lock.withLockUnchecked { volumeValue } }
        set { lock.withLockUnchecked { volumeValue = max(0, min(1, newValue)) } }
    }

    var isMuted: Bool {
        get { lock.withLockUnchecked { mutedValue } }
        set { lock.withLockUnchecked { mutedValue = newValue } }
    }

    var stats: Stats {
        lock.withLockUnchecked {
            var snapshot = statsValue
            snapshot.bufferedMilliseconds = Double(ring.count) / Self.sampleRate * 1000
            snapshot.targetMilliseconds = Double(targetFrames) / Self.sampleRate * 1000
            snapshot.isPlaying = !priming
            return snapshot
        }
    }

    // Jitter buffer: playback starts once `targetFrames` are queued. Each underrun adds
    // 20 ms (up to 200 ms) because the emulated guest's scheduling jitter varies per device;
    // anything beyond `maxFrames` is dropped so latency cannot creep up.
    private static let initialTargetFrames = Int(sampleRate * 0.06)
    private static let targetStepFrames = Int(sampleRate * 0.02)
    private static let maxTargetFrames = Int(sampleRate * 0.2)
    private static let idleStopInterval: TimeInterval = 3

    private let lock = OSAllocatedUnfairLock()
    private var ring = FrameRing(capacityFrames: Int(sampleRate), channels: channels)
    private var targetFrames = initialTargetFrames
    private var priming = true
    private var statsValue = Stats()
    private var volumeValue: Float = 1
    private var mutedValue = false
    private var lastDataTime: TimeInterval = 0

    private let log = Logger(subsystem: "app.ish.desktop", category: "audio")
    private let engineQueue = DispatchQueue(label: "ishaudio.engine")
    private var engine: AVAudioEngine?
    private var interrupted = false
    /// Settings › Background is "Off" and LinPad is not in front: no audio session, so
    /// iPadOS suspends LinPad as for any other app. Read and written on `engineQueue`.
    private var heldForBackground = false
    private var observers: [NSObjectProtocol] = []
    private var readerThread: Thread?
    private var statsURL: URL?

    private init() {}

    /// Starts watching the guest for the PulseAudio FIFO. Idempotent; the audio session is
    /// only activated while sound is actually arriving, so an idle Linux session never
    /// interrupts other apps' audio.
    func start(guestRoot: URL?) {
        guard readerThread == nil, let guestRoot else { return }
        let fifo = guestRoot.appendingPathComponent(Self.guestFIFOPath).path
        statsURL = FileManager.default.temporaryDirectory.appendingPathComponent("ishaudio-stats.txt")
        observeSession()
        let thread = Thread { [weak self] in self?.readLoop(fifoPath: fifo) }
        thread.name = "ishaudio.reader"
        thread.qualityOfService = .userInteractive
        readerThread = thread
        thread.start()
    }

    // MARK: - FIFO reader

    private func readLoop(fifoPath: String) {
        var fd: Int32 = -1
        var inode: ino_t = 0
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var carry = 0
        var lastStatsWrite: TimeInterval = 0
        let bytesPerFrame = Self.channels * MemoryLayout<Int16>.size

        while true {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastStatsWrite >= 1 {
                lastStatsWrite = now
                writeStats()
                stopIfIdle(now: now)
            }

            // PulseAudio recreates the FIFO when it restarts; follow the path, not the old inode.
            var info = stat()
            let exists = stat(fifoPath, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO
            if fd >= 0 && (!exists || info.st_ino != inode) {
                close(fd)
                fd = -1
                carry = 0
            }
            if fd < 0 {
                guard exists else {
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                // O_RDWR: never EOF while the guest has no writer, and opening never blocks.
                fd = open(fifoPath, O_RDWR | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else {
                    Thread.sleep(forTimeInterval: 0.5)
                    continue
                }
                inode = info.st_ino
                log.info("connected to \(fifoPath, privacy: .public)")
            }

            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 250) > 0 else { continue }
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress! + carry, raw.count - carry)
            }
            guard count > 0 else {
                if count < 0 && errno != EAGAIN && errno != EINTR {
                    close(fd)
                    fd = -1
                    carry = 0
                }
                continue
            }
            let available = carry + count
            let frames = available / bytesPerFrame
            if frames > 0 {
                buffer.withUnsafeBytes { raw in
                    enqueue(raw.baseAddress!.assumingMemoryBound(to: Int16.self), frames: frames, now: now)
                }
            }
            // A read can end mid-frame; keep the partial frame for the next one.
            carry = available - frames * bytesPerFrame
            if carry > 0 {
                buffer.withUnsafeMutableBytes { raw in
                    let base = raw.baseAddress!
                    memmove(base, base + frames * bytesPerFrame, carry)
                }
            }
        }
    }

    private func enqueue(_ samples: UnsafePointer<Int16>, frames: Int, now: TimeInterval) {
        let wasIdle = lock.withLockUnchecked { () -> Bool in
            let idle = engine == nil || lastDataTime == 0
            lastDataTime = now
            statsValue.framesReceived += UInt64(frames)
            ring.write(samples, frames: frames)
            if ring.count > Self.maxTargetFrames + targetFrames {
                let excess = ring.count - targetFrames
                ring.discard(frames: excess)
                statsValue.framesDropped += UInt64(excess)
            }
            return idle
        }
        if wasIdle {
            engineQueue.async { self.startEngine() }
        }
    }

    // MARK: - Render

    /// Runs on the audio I/O thread: no allocation, one short unfair-lock section.
    private func render(frameCount: Int, buffers: UnsafeMutableAudioBufferListPointer) {
        guard buffers.count >= Self.channels,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        lock.withLockUnchecked {
            let gain = mutedValue ? 0 : volumeValue / Float(Int16.max)
            var produced = 0
            if priming {
                priming = ring.count < targetFrames
            }
            if !priming {
                produced = ring.read(into: left, right, frames: frameCount, gain: gain)
                statsValue.framesPlayed += UInt64(produced)
                if produced < frameCount {
                    statsValue.underruns += 1
                    priming = true
                    targetFrames = min(targetFrames + Self.targetStepFrames, Self.maxTargetFrames)
                }
            }
            if produced < frameCount {
                (left + produced).update(repeating: 0, count: frameCount - produced)
                (right + produced).update(repeating: 0, count: frameCount - produced)
            }
        }
    }

    // MARK: - Engine and session

    // MARK: - App lifecycle

    /// Settings › Background. With background playback not allowed, leaving the screen
    /// stops sound and gives the session back; coming back lets the next chunk restart it.
    func setBackgroundPlaybackAllowed(_ allowed: Bool, inBackground: Bool) {
        engineQueue.async {
            let hold = inBackground && !allowed
            guard hold != self.heldForBackground else { return }
            self.heldForBackground = hold
            if hold { self.stopEngine(deactivate: true) }
        }
    }

    /// LinPad is in front again. iPadOS does not promise an end to every interruption
    /// (a call taken while LinPad was suspended, another app's audio), so one that never
    /// ended must not keep Linux silent until the next launch.
    func resumeAfterBackground() {
        engineQueue.async {
            self.heldForBackground = false
            self.interrupted = false
        }
    }

    private func startEngine() {
        guard engine == nil, !interrupted, !heldForBackground else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback without .mixWithOthers: Linux media (VLC) behaves like a media app
            // and keeps playing with the ringer switch on silent. While a Linux app records,
            // the microphone bridge needs .playAndRecord instead.
            try ISHMicBridge.configureSession(session, recording: ISHMicBridge.shared.isCapturing)
            try session.setPreferredIOBufferDuration(0.01)
            try session.setActive(true)
        } catch {
            log.error("audio session: \(error.localizedDescription, privacy: .public)")
        }

        let engine = AVAudioEngine()
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate,
                                         channels: AVAudioChannelCount(Self.channels)) else { return }
        let source = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            self.render(frameCount: Int(frameCount), buffers: UnsafeMutableAudioBufferListPointer(bufferList))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            log.error("engine start: \(error.localizedDescription, privacy: .public)")
            return
        }
        lock.withLockUnchecked {
            self.engine = engine
            priming = true
        }
        log.info("playing")
    }

    private func stopEngine(deactivate: Bool) {
        let engine = lock.withLockUnchecked { () -> AVAudioEngine? in
            let current = self.engine
            self.engine = nil
            lastDataTime = 0
            ring.discard(frames: ring.count)
            priming = true
            return current
        }
        guard let engine else { return }
        engine.stop()
        // A Linux app still recording keeps the session (and the microphone) alive.
        if deactivate && !ISHMicBridge.shared.isCapturing {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        log.info("stopped")
    }

    /// PulseAudio suspends an idle sink after a few seconds, so the FIFO goes quiet when
    /// nothing plays; give the audio session back to other apps then.
    private func stopIfIdle(now: TimeInterval) {
        let idle = lock.withLockUnchecked { engine != nil && lastDataTime > 0 && now - lastDataTime > Self.idleStopInterval }
        if idle {
            engineQueue.async { self.stopEngine(deactivate: true) }
        }
    }

    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session,
                                            queue: nil) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            engineQueue.async {
                switch type {
                case .began:
                    self.interrupted = true
                    self.stopEngine(deactivate: false)
                case .ended:
                    self.interrupted = false
                    // The next chunk from the guest restarts the engine.
                @unknown default:
                    break
                }
            }
        })
        // Headphones unplugged (or a Bluetooth speaker gone): iPadOS media convention is to
        // pause rather than continue out of the speaker. The desktop pauses Linux players.
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session,
                                            queue: nil) { note in
            guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                  AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .linuxAudioOutputLost, object: nil)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            engineQueue.async {
                self.interrupted = false
                self.stopEngine(deactivate: false)
            }
        })
        // A route or sample-rate change stops the engine; rebuild it on the next chunk.
        // The microphone bridge's engine posts this too; that one is not ours.
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil,
                                            queue: nil) { [weak self] note in
            guard let self else { return }
            engineQueue.async {
                guard let engine = self.lock.withLockUnchecked({ self.engine }),
                      note.object as AnyObject? === engine else { return }
                self.stopEngine(deactivate: false)
            }
        })
    }

    private func writeStats() {
        guard let statsURL else { return }
        let s = stats
        let text = """
            frames_received \(s.framesReceived)
            frames_played \(s.framesPlayed)
            frames_dropped \(s.framesDropped)
            underruns \(s.underruns)
            buffered_ms \(String(format: "%.1f", s.bufferedMilliseconds))
            target_ms \(String(format: "%.1f", s.targetMilliseconds))
            playing \(s.isPlaying ? 1 : 0)

            """
        try? text.write(to: statsURL, atomically: true, encoding: .utf8)
    }
}

/// Interleaved s16 frames in a fixed ring. Callers hold `ISHAudioBridge.lock`.
private struct FrameRing {
    private var storage: [Int16]
    private let capacity: Int
    private let channels: Int
    private var head = 0
    private(set) var count = 0

    init(capacityFrames: Int, channels: Int) {
        capacity = capacityFrames
        self.channels = channels
        storage = [Int16](repeating: 0, count: capacityFrames * channels)
    }

    mutating func write(_ samples: UnsafePointer<Int16>, frames: Int) {
        var frames = frames
        var source = samples
        if frames > capacity {
            source += (frames - capacity) * channels
            frames = capacity
        }
        let overflow = count + frames - capacity
        if overflow > 0 { discard(frames: overflow) }
        var tail = (head + count) % capacity
        var remaining = frames
        storage.withUnsafeMutableBufferPointer { dest in
            while remaining > 0 {
                let chunk = min(remaining, capacity - tail)
                (dest.baseAddress! + tail * channels).update(from: source, count: chunk * channels)
                source += chunk * channels
                remaining -= chunk
                tail = (tail + chunk) % capacity
            }
        }
        count += frames
    }

    mutating func read(into left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>,
                       frames: Int, gain: Float) -> Int {
        let n = min(frames, count)
        storage.withUnsafeBufferPointer { src in
            var index = head
            for i in 0..<n {
                left[i] = Float(src[index * channels]) * gain
                right[i] = Float(src[index * channels + 1]) * gain
                index += 1
                if index == capacity { index = 0 }
            }
        }
        discard(frames: n)
        return n
    }

    mutating func discard(frames: Int) {
        let n = min(frames, count)
        head = (head + n) % capacity
        count -= n
    }
}

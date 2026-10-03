import AVFoundation
import Foundation
import os

/// The iPad cameras as the guest's V4L2 devices (`fs/dev_video.c`): /dev/video0 is the
/// back camera, /dev/video1 the front one.
///
/// The kernel calls `start` on VIDIOC_STREAMON and `stop` on STREAMOFF or close. Only then
/// does a capture session run, so the camera indicator and the permission prompt appear
/// only while a Linux app is actually capturing. Frames are 420v (NV12, video range) and
/// are copied into the guest's queued buffer inside `video_host_frame`; the kernel crops
/// to the guest's aspect ratio and scales. While the camera delivers nothing (permission
/// prompt or denied, camera taken by another app in Split View or Slide Over, app in the
/// background) the kernel feeds the guest black frames.
@objc(ISHCameraBridge)
final class ISHCameraBridge: NSObject, @unchecked Sendable {
    static let shared = ISHCameraBridge()

    private let log = Logger(subsystem: "app.ish.desktop", category: "camera")
    private let sessionQueue = DispatchQueue(label: "ishcamera.session")
    private var positions: [AVCaptureDevice.Position] = []
    // Owned by sessionQueue.
    private var captures: [Int: Capture] = [:]
    private var wanted: [Int: Request] = [:]
    private var deniedNoticeShown = false

    private struct Request {
        let width: UInt32
        let height: UInt32
        let fps: UInt32
    }

    /// Registers the cameras with the kernel. AppDelegate calls this (by name, as it is
    /// also built into targets without Swift) before the first process starts, so the
    /// device nodes get created. Looking the cameras up needs no permission.
    @objc static func install() {
        shared.register()
    }

    private func register() {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                         mediaType: .video, position: .unspecified)
        var names: [String] = []
        for position in [AVCaptureDevice.Position.back, .front]
        where discovery.devices.contains(where: { $0.position == position }) {
            positions.append(position)
            names.append(position == .back ? "iPad Camera (Back)" : "iPad Camera (Front)")
        }
        guard !positions.isEmpty else {
            log.info("no cameras")
            return
        }
        let ops = UnsafeMutablePointer<video_host_ops>.allocate(capacity: 1)
        ops.initialize(to: video_host_ops(
            start: { _, index, width, height, fps in
                ISHCameraBridge.shared.start(index: Int(index), request: Request(width: width, height: height, fps: fps))
            },
            stop: { _, index in
                ISHCameraBridge.shared.stop(index: Int(index))
            }))
        // The kernel keeps both for its lifetime.
        let cNames = UnsafeMutablePointer<UnsafePointer<CChar>?>.allocate(capacity: names.count)
        for (i, name) in names.enumerated() {
            cNames[i] = UnsafePointer(strdup(name))
        }
        video_set_host(ops, nil, Int32(names.count), cNames)
        observeInterruptions()
        log.info("registered \(names.count) cameras")
    }

    private func start(index: Int, request: Request) {
        sessionQueue.async {
            self.wanted[index] = request
            self.startIfAllowed(index: index)
        }
    }

    private func stop(index: Int) {
        sessionQueue.async {
            self.wanted[index] = nil
            if let capture = self.captures.removeValue(forKey: index) {
                capture.session.stopRunning()
                self.log.info("camera \(index) off")
            }
        }
    }

    private func startIfAllowed(index: Int) {
        guard wanted[index] != nil, captures[index] == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCapture(index: index)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                self.sessionQueue.async {
                    if granted {
                        self.startIfAllowed(index: index)
                    } else {
                        self.showDeniedNotice()
                    }
                }
            }
        default:
            showDeniedNotice()
        }
    }

    private func startCapture(index: Int) {
        guard let request = wanted[index], index < positions.count,
              let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                                   position: positions[index]) else { return }
        let session = AVCaptureSession()
        session.beginConfiguration()
        // Keeps the camera running next to other apps in Split View and Stage Manager.
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }
        let preset: AVCaptureSession.Preset = request.width <= 640 ? .vga640x480 : .hd1280x720
        if session.canSetSessionPreset(preset) {
            session.sessionPreset = preset
        }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        let capture = Capture(index: index)
        output.setSampleBufferDelegate(capture, queue: capture.queue)
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(output) else {
                log.error("camera \(index): cannot configure session")
                session.commitConfiguration()
                return
            }
            session.addInput(input)
            session.addOutput(output)
        } catch {
            log.error("camera \(index): \(error.localizedDescription, privacy: .public)")
            session.commitConfiguration()
            return
        }
        setFrameRate(device, fps: request.fps)
        session.commitConfiguration()
        capture.session = session
        capture.rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        capture.output = output
        capture.applyRotation()
        captures[index] = capture
        session.startRunning()
        log.info("camera \(index) on (\(request.width)x\(request.height) @ \(request.fps) fps)")
    }

    private func setFrameRate(_ device: AVCaptureDevice, fps: UInt32) {
        guard fps > 0, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameDuration <= duration && duration <= $0.maxFrameDuration
        }
        if supported {
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        }
    }

    private func showDeniedNotice() {
        guard !deniedNoticeShown else { return }
        deniedNoticeShown = true
        log.info("camera permission denied; the guest gets black frames")
        ISHPrivacyNotice.show(title: "Camera Access Is Off",
                              message: "A Linux app wants to use the camera, but LinPad isn't allowed to, "
                                  + "so the app sees a black picture. You can allow it in Settings.")
    }

    private func observeInterruptions() {
        let center = NotificationCenter.default
        // The kernel covers the gap with black frames; this is only for the log, and to
        // restart a session that died rather than paused.
        center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: nil,
                           queue: nil) { [weak self] note in
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
            self?.log.info("camera interrupted (reason \(reason))")
        }
        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: nil,
                           queue: nil) { [weak self] note in
            guard let self, let session = note.object as? AVCaptureSession else { return }
            log.error("camera runtime error: \(String(describing: note.userInfo), privacy: .public)")
            sessionQueue.async {
                guard let (index, _) = self.captures.first(where: { $0.value.session === session }) else { return }
                self.captures[index] = nil
                session.stopRunning()
                self.startIfAllowed(index: index)
            }
        }
    }
}

/// One running capture session; delivers each frame straight to the kernel.
private final class Capture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let index: Int
    let queue: DispatchQueue
    var session = AVCaptureSession()
    var output: AVCaptureVideoDataOutput?
    var rotation: AVCaptureDevice.RotationCoordinator?
    private var observation: NSKeyValueObservation?

    init(index: Int) {
        self.index = index
        queue = DispatchQueue(label: "ishcamera.frames.\(index)")
    }

    /// Upright frames for the way the iPad is held; the kernel crops portrait frames to
    /// the guest's landscape sizes.
    func applyRotation() {
        guard let rotation else { return }
        let apply = { [weak self] in
            guard let connection = self?.output?.connection(with: .video) else { return }
            let angle = rotation.videoRotationAngleForHorizonLevelCapture
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
        apply()
        observation = rotation.observe(\.videoRotationAngleForHorizonLevelCapture) { _, _ in apply() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetPlaneCount(pixels) == 2 else { return }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(pixels, 0),
              let uv = CVPixelBufferGetBaseAddressOfPlane(pixels, 1) else { return }
        var frame = video_host_frame()
        frame.format = VIDEO_HOST_NV12
        frame.width = UInt32(CVPixelBufferGetWidth(pixels))
        frame.height = UInt32(CVPixelBufferGetHeight(pixels))
        frame.planes = (UnsafePointer(y.assumingMemoryBound(to: UInt8.self)),
                        UnsafePointer(uv.assumingMemoryBound(to: UInt8.self)))
        frame.strides = (CVPixelBufferGetBytesPerRowOfPlane(pixels, 0), CVPixelBufferGetBytesPerRowOfPlane(pixels, 1))
        video_host_frame(Int32(index), &frame)
    }
}

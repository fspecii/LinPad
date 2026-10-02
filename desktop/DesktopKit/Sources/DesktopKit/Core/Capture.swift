import ReplayKit
import SwiftUI
import UIKit

/// Screenshots and screen recordings of the desktop.
enum DesktopCapture {
    enum Mode: Equatable {
        case full
        case window
        case region(CGRect)
    }

    static let riceModeKey = "desktop.capture.rice"
    static let microphoneKey = "desktop.capture.microphone"

    static var riceMode: Bool { UserDefaults.standard.bool(forKey: riceModeKey) }

    /// "Screenshot 2026-10-02 at 22.41.07.png", the way desktops name them.
    static func fileName(_ prefix: String, date: Date = Date(), extension ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "\(prefix) \(formatter.string(from: date)).\(ext)"
    }

    /// Rice mode: the capture sits on its wallpaper with a margin, rounded corners and a soft
    /// shadow, ready to share.
    static func riced(_ image: UIImage, backdrop: UIImage?, fallback: UIColor) -> UIImage {
        let margin = max(image.size.width, image.size.height) * 0.06
        let canvas = CGSize(width: image.size.width + margin * 2, height: image.size.height + margin * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: canvas, format: format).image { context in
            if let backdrop {
                let scale = max(canvas.width / backdrop.size.width, canvas.height / backdrop.size.height)
                let size = CGSize(width: backdrop.size.width * scale, height: backdrop.size.height * scale)
                backdrop.draw(in: CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                                         width: size.width, height: size.height))
            } else {
                fallback.setFill()
                context.fill(CGRect(origin: .zero, size: canvas))
            }
            let frame = CGRect(x: margin, y: margin, width: image.size.width, height: image.size.height)
            let radius = min(image.size.width, image.size.height) * 0.02
            let path = UIBezierPath(roundedRect: frame, cornerRadius: radius)
            context.cgContext.saveGState()
            context.cgContext.setShadow(offset: CGSize(width: 0, height: margin * 0.15), blur: margin * 0.5,
                                        color: UIColor.black.withAlphaComponent(0.45).cgColor)
            UIColor.black.setFill()
            path.fill()
            context.cgContext.restoreGState()
            path.addClip()
            image.draw(in: frame)
        }
    }
}

extension DesktopController {
    /// ⌃⌥S, ⌃⌥⇧W and the region picker's result.
    func takeScreenshot(_ mode: DesktopCapture.Mode) {
        guard let reference = input.referenceView, let window = reference.window else { return }
        let desktopInWindow = reference.convert(reference.bounds, to: window)
        let rice = DesktopCapture.riceMode
        var rect: CGRect
        switch mode {
        case .full:
            // Rice mode leaves the panels out: just the desktop and its windows.
            rect = rice ? desktopInWindow : window.bounds
        case .window:
            guard let focused = windowManager.focusedWindow else {
                notify("No window has focus.")
                return
            }
            rect = reference.convert(windowManager.displayFrame(for: focused), to: window)
        case .region(let region):
            rect = reference.convert(region, to: window)
        }
        rect = rect.intersection(window.bounds).integral
        guard rect.width > 4, rect.height > 4 else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        let shot = UIGraphicsImageRenderer(size: rect.size, format: format).image { _ in
            window.drawHierarchy(in: CGRect(origin: CGPoint(x: -rect.minX, y: -rect.minY), size: window.bounds.size),
                                 afterScreenUpdates: false)
        }
        var image = shot
        if rice {
            let backdrop: UIImage? = if case .image(let id) = wallpaperSource() { wallpapers.decoded[id] } else { nil }
            image = DesktopCapture.riced(shot, backdrop: backdrop, fallback: .darkGray)
        }
        UIPasteboard.general.image = image
        guard let data = image.pngData() else { return }
        let name = DesktopCapture.fileName("Screenshot", extension: "png")
        Task { await saveCapture(data, name: name, folder: "Pictures/Screenshots", kind: "Screenshot") }
    }

    /// Writes a capture to the guest home and offers Share; also kept on the iPad for sharing.
    func saveCapture(_ data: Data, name: String, folder: String, kind: String) async {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try? data.write(to: local)
        let directory = AppPath.join(AppPath.normalize(host.homeDirectory), folder)
        let made = await host.run("mkdir -p -- \(directory.shellQuoted)", cwd: nil, stdin: nil)
        var saved = false
        if made.succeeded {
            saved = (try? await host.writeFile(AppPath.join(directory, name), data: data)) != nil
        }
        let place = saved ? "~/\(folder)" : "the clipboard"
        _ = notify("\(kind) saved to \(place).", action: DesktopToast.Action(title: "Share") {
            HostPresenter.share([local])
        })
    }

    // MARK: Region

    func beginRegionCapture() {
        dismissTransientOverlays()
        isRegionCapturePresented = true
    }

    func finishRegionCapture(_ region: CGRect?) {
        isRegionCapturePresented = false
        guard let region else { return }
        // Capture after the selection overlay has gone from the screen.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            takeScreenshot(.region(region))
        }
    }

    // MARK: Recording

    /// ⌃⌥⇧R: starts or stops recording the app's screen (ReplayKit, in-app).
    func toggleScreenRecording() {
        let recorder = RPScreenRecorder.shared()
        if recorder.isRecording {
            stopScreenRecording()
            return
        }
        guard recorder.isAvailable else {
            notify("Screen recording is not available right now.")
            return
        }
        recorder.isMicrophoneEnabled = UserDefaults.standard.bool(forKey: DesktopCapture.microphoneKey)
        recorder.startRecording { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.notify("Couldn't start recording: \(error.localizedDescription)")
                } else {
                    self.isRecordingScreen = true
                    self.notify("Recording the screen. ⌃⌥⇧R or the red button stops it.")
                }
            }
        }
    }

    func stopScreenRecording() {
        let name = DesktopCapture.fileName("Screen Recording", extension: "mp4")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        RPScreenRecorder.shared().stopRecording(withOutput: url) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.isRecordingScreen = false
                if let error {
                    self.notify("Recording stopped without a video: \(error.localizedDescription)")
                    return
                }
                guard let data = try? Data(contentsOf: url) else { return }
                await self.saveCapture(data, name: name, folder: "Videos/Recordings", kind: "Recording")
            }
        }
    }
}

/// ⌃⌥⇧S: drag a rectangle over the desktop; Esc or a tap without dragging cancels.
struct RegionCaptureView: View {
    let controller: DesktopController
    @State private var start: CGPoint?
    @State private var current: CGPoint?
    @Environment(\.desktopTheme) private var theme

    private var selection: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.25)
                if let selection {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .overlay(Rectangle().strokeBorder(theme.accent, lineWidth: 2))
                        .frame(width: selection.width, height: selection.height)
                        .offset(x: selection.minX, y: selection.minY)
                    Text("\(Int(selection.width)) × \(Int(selection.height))")
                        .font(.caption.monospaced())
                        .padding(4)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .foregroundStyle(.white)
                        .offset(x: selection.minX, y: max(selection.minY - 26, 0))
                } else {
                    Text("Drag to capture an area · Esc cancels")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    start = start ?? value.startLocation
                    current = value.location
                }
                .onEnded { _ in
                    let region = selection.flatMap { $0.width > 8 && $0.height > 8 ? $0 : nil }
                    start = nil
                    current = nil
                    controller.finishRegionCapture(region)
                })
        }
        .accessibilityIdentifier("desktop.regionCapture")
    }
}

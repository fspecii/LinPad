import Foundation

/// Downloads a release's rootfs tarball in a background URLSession, so it continues while
/// the app is suspended, and keeps resume data when it fails so it can continue later
/// instead of starting over. The manifest rides along in the task's description, which
/// survives the app being relaunched by the system.
final class SystemUpdateDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    enum Event: Sendable {
        case progress(received: Int64, total: Int64)
        case finished(file: URL, manifest: RootfsManifest)
        case failed(message: String, resumable: Bool)
        case cancelled
        case backgroundEventsDelivered
    }

    private struct Pending: Codable {
        let manifest: RootfsManifest
        let url: URL
    }

    let directory: URL
    private let identifier: String
    private let onEvent: @Sendable (Event) -> Void
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        // The user asked for this download, so it may use cellular and Low Data Mode.
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private var resumeDataURL: URL { directory.appendingPathComponent("rootfs.resume") }
    private var pendingURL: URL { directory.appendingPathComponent("rootfs.pending.json") }

    init(identifier: String, directory: URL, onEvent: @escaping @Sendable (Event) -> Void) {
        self.identifier = identifier
        self.directory = directory
        self.onEvent = onEvent
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Reconnects to a download that kept running while the app was not; true if one is.
    func reattach() async -> Bool {
        let tasks = await session.allTasks
        return tasks.contains { $0.state == .running || $0.state == .suspended }
    }

    /// The manifest of a download that stopped with resume data.
    var resumableManifest: RootfsManifest? {
        guard FileManager.default.fileExists(atPath: resumeDataURL.path),
              let data = try? Data(contentsOf: pendingURL) else { return nil }
        return (try? JSONDecoder().decode(Pending.self, from: data))?.manifest
    }

    func start(manifest: RootfsManifest, url: URL) {
        discardResumeData()
        let pending = Pending(manifest: manifest, url: url)
        try? JSONEncoder().encode(pending).write(to: pendingURL, options: .atomic)
        let task = session.downloadTask(with: url)
        task.taskDescription = Self.describe(pending)
        task.countOfBytesClientExpectsToReceive = manifest.size
        task.resume()
    }

    /// Continues from the resume data; false if there is none (start again instead).
    func resume() -> Bool {
        guard let data = try? Data(contentsOf: resumeDataURL),
              let pendingData = try? Data(contentsOf: pendingURL),
              let pending = try? JSONDecoder().decode(Pending.self, from: pendingData) else { return false }
        try? FileManager.default.removeItem(at: resumeDataURL)
        let task = session.downloadTask(withResumeData: data)
        task.taskDescription = Self.describe(pending)
        task.resume()
        return true
    }

    func cancel() {
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
        discardResumeData()
        try? FileManager.default.removeItem(at: pendingURL)
    }

    private func discardResumeData() {
        try? FileManager.default.removeItem(at: resumeDataURL)
    }

    private static func describe(_ pending: Pending) -> String? {
        (try? JSONEncoder().encode(pending)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func pending(of task: URLSessionTask) -> Pending? {
        task.taskDescription.flatMap { try? JSONDecoder().decode(Pending.self, from: Data($0.utf8)) }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Self.pending(of: downloadTask)?.manifest.size ?? 0
        onEvent(.progress(received: totalBytesWritten, total: expected))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let pending = Self.pending(of: downloadTask) else { return }
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            onEvent(.failed(message: "The download failed (HTTP \(http.statusCode)).", resumable: false))
            return
        }
        // `location` is deleted when this method returns.
        let destination = directory.appendingPathComponent("linpad-rootfs-\(pending.manifest.version).tar.gz")
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            try? FileManager.default.removeItem(at: pendingURL)
            onEvent(.finished(file: destination, manifest: pending.manifest))
        } catch {
            onEvent(.failed(message: "Could not keep the download: \(error.localizedDescription)", resumable: false))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error as NSError? else { return }
        if let data = error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? data.write(to: resumeDataURL, options: .atomic)
            onEvent(.failed(message: error.localizedDescription, resumable: true))
        } else if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            onEvent(.cancelled)
        } else {
            onEvent(.failed(message: error.localizedDescription, resumable: false))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onEvent(.backgroundEventsDelivered)
    }
}

import Foundation
import FBModels

/// Background-URLSession wrapper for large artifact downloads (chart MBTiles,
/// plate bundles). Downloads keep running while the app is suspended; iOS
/// relaunches us for `handleEventsForBackgroundURLSession` when they finish
/// (see AppDelegate in FlightBagApp.swift).
///
/// Identity: each `URLSessionDownloadTask.taskDescription` carries the
/// `DownloadProduct.id`, so tasks re-adopted after relaunch map back to
/// products without any local bookkeeping. Resume data survives failures and
/// pauses on disk under `downloads/resume/`.
///
/// This class only moves bytes; verification, installation, and state live in
/// `DownloadCenter`, which consumes the `Events` callbacks (all delivered on
/// the main actor).
final class DownloadService: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    struct Events: Sendable {
        /// productId, fraction 0-1, bytes written so far.
        var progress: @MainActor @Sendable (String, Double, Int64) -> Void
        /// productId, staged file URL (already moved out of URLSession's temp dir).
        var finished: @MainActor @Sendable (String, URL) -> Void
        /// productId, message. Resume data (if any) is already persisted.
        var failed: @MainActor @Sendable (String, String) -> Void
    }

    /// Stored by the AppDelegate when iOS relaunches the app for background
    /// session events; called once the session drains its queue.
    @MainActor static var backgroundCompletionHandler: (() -> Void)?

    private let events: Events
    private let stagingDirectory: URL
    private let resumeDirectory: URL
    private var session: URLSession!
    /// Serialized on the delegate queue (maxConcurrentOperationCount 1).
    private var tasksByProduct: [String: URLSessionDownloadTask] = [:]
    private var lastProgressReport: [String: Date] = [:]

    init(identifier: String = "Me.FlightBag.downloads", events: Events) {
        self.events = events
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        stagingDirectory = support.appendingPathComponent("FlightBag/downloads/staging", isDirectory: true)
        resumeDirectory = support.appendingPathComponent("FlightBag/downloads/resume", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: resumeDirectory, withIntermediateDirectories: true)

        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// Re-adopt tasks that survived an app relaunch. Returns the product ids
    /// still in flight so DownloadCenter can restore their phases.
    func reattach() async -> [String] {
        let tasks = await session.allTasks
        return await withCheckedContinuation { continuation in
            session.delegateQueue.addOperation { [self] in
                var ids: [String] = []
                for task in tasks {
                    guard let download = task as? URLSessionDownloadTask,
                          let productId = download.taskDescription else { continue }
                    tasksByProduct[productId] = download
                    ids.append(productId)
                }
                continuation.resume(returning: ids)
            }
        }
    }

    func start(_ product: DownloadProduct) {
        session.delegateQueue.addOperation { [self] in
            guard tasksByProduct[product.id] == nil else { return }
            let task: URLSessionDownloadTask
            if let resumeData = try? Data(contentsOf: resumeFile(for: product.id)) {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                task = session.downloadTask(with: product.url)
            }
            try? FileManager.default.removeItem(at: resumeFile(for: product.id))
            task.taskDescription = product.id
            tasksByProduct[product.id] = task
            task.resume()
        }
    }

    /// Cancel but keep resume data so `start` can pick the transfer back up.
    func pause(productId: String) {
        session.delegateQueue.addOperation { [self] in
            guard let task = tasksByProduct[productId] else { return }
            task.cancel { [self] resumeData in
                if let resumeData {
                    try? resumeData.write(to: resumeFile(for: productId), options: .atomic)
                }
            }
        }
    }

    /// Cancel and discard any partial transfer.
    func cancel(productId: String) {
        session.delegateQueue.addOperation { [self] in
            tasksByProduct[productId]?.cancel()
            try? FileManager.default.removeItem(at: resumeFile(for: productId))
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard let productId = downloadTask.taskDescription else { return }
        // ~4 Hz cap so SwiftUI isn't re-rendered per network buffer.
        let now = Date()
        if let last = lastProgressReport[productId], now.timeIntervalSince(last) < 0.25 { return }
        lastProgressReport[productId] = now
        let fraction = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : 0
        let progress = events.progress
        Task { @MainActor in progress(productId, fraction, totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let productId = downloadTask.taskDescription else { return }
        // The temp file dies when this callback returns — move synchronously.
        let staged = stagingDirectory.appendingPathComponent(Self.fileSafe(productId))
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200,
               // Resumed transfers legitimately complete with 206.
               http.statusCode != 206 {
                throw URLError(.badServerResponse)
            }
            try? FileManager.default.removeItem(at: staged)
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            let failed = events.failed
            Task { @MainActor in failed(productId, "Download failed: \(error.localizedDescription)") }
            return
        }
        let finished = events.finished
        Task { @MainActor in finished(productId, staged) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let productId = task.taskDescription else { return }
        tasksByProduct[productId] = nil
        lastProgressReport[productId] = nil
        guard let error else { return }  // Success already went through didFinishDownloadingTo.

        let nsError = error as NSError
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? resumeData.write(to: resumeFile(for: productId), options: .atomic)
        }
        if nsError.code == NSURLErrorCancelled { return }  // pause/cancel, not a failure
        let failed = events.failed
        let message = error.localizedDescription
        Task { @MainActor in failed(productId, message) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            Self.backgroundCompletionHandler?()
            Self.backgroundCompletionHandler = nil
        }
    }

    // MARK: Helpers

    private func resumeFile(for productId: String) -> URL {
        resumeDirectory.appendingPathComponent(Self.fileSafe(productId) + ".resume")
    }

    /// Product ids are artifact paths ("2607/tiles/x.mbtiles"); flatten for
    /// use as a single filename.
    static func fileSafe(_ productId: String) -> String {
        productId.replacingOccurrences(of: "/", with: "_")
    }
}

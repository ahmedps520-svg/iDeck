import Foundation

/// Resumable HTTPS downloads for runtime artifacts. Resume data is kept on
/// disk, so a download interrupted by the app being closed continues later.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    struct Progress {
        var file: String
        var received: Int64
        var expected: Int64
        var bytesPerSecond: Double
    }

    private var session: URLSession!
    private var continuation: CheckedContinuation<URL, Error>?
    private var destination: URL?
    private var onProgress: ((Progress) -> Void)?
    private var task: URLSessionDownloadTask?
    private var lastSample = (time: Date(), bytes: Int64(0))
    private var speed: Double = 0
    private var fileName = ""

    override init() {
        super.init()
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 6 * 3600
        cfg.httpMaximumConnectionsPerHost = 2
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }

    private func resumeFile(for dest: URL) -> URL { dest.appendingPathExtension("resume") }

    /// Downloads `url` to `dest`. Uses saved resume data when present.
    func download(_ url: URL, to dest: URL, expectedSize: Int64, progress: @escaping (Progress) -> Void) async throws -> URL {
        guard url.scheme == "https" else { throw Core.CallError(message: "refusing non-HTTPS download") }
        if let size = (try? dest.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, Int64(size) == expectedSize {
            return dest
        }
        fileName = dest.lastPathComponent
        destination = dest
        onProgress = progress
        lastSample = (Date(), 0)
        return try await withCheckedThrowingContinuation { c in
            continuation = c
            if let data = try? Data(contentsOf: resumeFile(for: dest)) {
                task = session.downloadTask(withResumeData: data)
            } else {
                task = session.downloadTask(with: url)
            }
            task?.resume()
        }
    }

    /// Pauses, keeping resume data for later.
    func pause() {
        guard let dest = destination else { return }
        task?.cancel { data in
            if let data { try? data.write(to: self.resumeFile(for: dest)) }
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let now = Date()
        let dt = now.timeIntervalSince(lastSample.time)
        if dt >= 0.5 {
            let inst = Double(totalBytesWritten - lastSample.bytes) / dt
            speed = speed == 0 ? inst : speed * 0.7 + inst * 0.3
            lastSample = (now, totalBytesWritten)
            onProgress?(Progress(file: fileName, received: totalBytesWritten,
                                 expected: totalBytesExpectedToWrite, bytesPerSecond: speed))
        }
    }

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let dest = destination else { return }
        let fm = FileManager.default
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw Core.CallError(message: "HTTP \(http.statusCode) for \(dest.lastPathComponent)")
            }
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: location, to: dest)
            try? fm.removeItem(at: resumeFile(for: dest))
            finish(.success(dest))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let ns = error as NSError
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, let dest = destination {
            try? data.write(to: resumeFile(for: dest))
        }
        finish(.failure(error))
    }

    private func finish(_ r: Result<URL, Error>) {
        let c = continuation
        continuation = nil
        switch r {
        case .success(let u): c?.resume(returning: u)
        case .failure(let e): c?.resume(throwing: e)
        }
    }
}

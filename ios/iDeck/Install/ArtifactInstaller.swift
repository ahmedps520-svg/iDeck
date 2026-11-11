import Compression
import Foundation

/// Verifies and expands runtime artifacts.
enum ArtifactInstaller {
    struct VerifyError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Streaming SHA-256 using the core implementation.
    static func sha256(of url: URL, progress: ((Double) -> Void)? = nil) throws -> String {
        let h = ideck_sha256_new()
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        let total = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1)
        var done = 0.0
        while true {
            let chunk = try fh.read(upToCount: 4 << 20) ?? Data()
            if chunk.isEmpty { break }
            chunk.withUnsafeBytes { ideck_sha256_update(h, $0.baseAddress, $0.count) }
            done += Double(chunk.count)
            progress?(done / total)
        }
        var out = [CChar](repeating: 0, count: 65)
        ideck_sha256_finish(h, &out)
        return String(cString: out)
    }

    /// Decompresses an xz file into `dest`, skipping zero blocks so disk
    /// images stay sparse. Returns the SHA-256 of the decompressed data.
    static func expandXZ(_ src: URL, to dest: URL, expectedSize: UInt64,
                         progress: ((Double) -> Void)? = nil) throws -> String {
        guard let writer = ideck_sparse_open(dest.path) else {
            throw VerifyError(message: "cannot create \(dest.lastPathComponent)")
        }
        var writerOpen = true
        defer { if writerOpen { ideck_sparse_abort(writer) } }
        let hash = ideck_sha256_new()
        var digest = [CChar](repeating: 0, count: 65)
        var hashOpen = true
        defer { if hashOpen { ideck_sha256_finish(hash, &digest) } }

        let fh = try FileHandle(forReadingFrom: src)
        defer { try? fh.close() }

        let srcCap = 1 << 20
        let dstCap = 4 << 20
        let srcBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: srcCap)
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
        defer {
            srcBuf.deallocate()
            dstBuf.deallocate()
        }

        var stream = compression_stream(dst_ptr: dstBuf, dst_size: dstCap,
                                        src_ptr: UnsafePointer(srcBuf), src_size: 0, state: nil)
        // COMPRESSION_LZMA decodes the xz container format.
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_LZMA) == COMPRESSION_STATUS_OK else {
            throw VerifyError(message: "xz decoder unavailable")
        }
        defer { compression_stream_destroy(&stream) }

        var produced: UInt64 = 0
        var inputDone = false
        while true {
            if stream.src_size == 0 && !inputDone {
                let chunk = try fh.read(upToCount: srcCap) ?? Data()
                if chunk.isEmpty {
                    inputDone = true
                } else {
                    chunk.copyBytes(to: srcBuf, count: chunk.count)
                }
                stream.src_ptr = UnsafePointer(srcBuf)
                stream.src_size = chunk.count
            }
            stream.dst_ptr = dstBuf
            stream.dst_size = dstCap
            let flags = inputDone ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let status = compression_stream_process(&stream, flags)
            let n = dstCap - stream.dst_size
            if n > 0 {
                ideck_sha256_update(hash, dstBuf, n)
                guard ideck_sparse_write(writer, dstBuf, n) == 1 else {
                    throw VerifyError(message: "write failed for \(dest.lastPathComponent) (storage full?)")
                }
                produced += UInt64(n)
                if expectedSize > 0 { progress?(min(1, Double(produced) / Double(expectedSize))) }
            }
            if status == COMPRESSION_STATUS_END { break }
            if status == COMPRESSION_STATUS_ERROR {
                throw VerifyError(message: "\(src.lastPathComponent) is corrupt (xz error)")
            }
            if inputDone && stream.src_size == 0 && n == 0 {
                throw VerifyError(message: "\(src.lastPathComponent) ended before the xz stream did")
            }
        }

        var skipped: UInt64 = 0
        writerOpen = false
        guard ideck_sparse_finish(writer, &skipped) == 1 else {
            throw VerifyError(message: "could not finish \(dest.lastPathComponent)")
        }
        if expectedSize > 0 && produced != expectedSize {
            throw VerifyError(message: "\(dest.lastPathComponent): \(produced) bytes, expected \(expectedSize)")
        }
        hashOpen = false
        ideck_sha256_finish(hash, &digest)
        return String(cString: digest)
    }
}

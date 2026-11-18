import Foundation
import MyvuAI

/// Incremental WAV output; memory use does not grow with a meeting. The header
/// is rewritten on close. The caller owns the file and decides whether to keep it.
public final class WaveFileWriter {
    public let url: URL
    private let handle: FileHandle
    private let maximumBytes: Int
    private var bytesWritten = 0
    private var isClosed = false

    public init(url: URL, maximumBytes: Int = 16_000 * 2 * 60 * 10) throws {
        self.url = url
        self.maximumBytes = maximumBytes
        try Wav.encode(pcm: Data()).write(to: url, options: .atomic)
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    public func append(_ pcm: Data) throws {
        guard !isClosed, bytesWritten + pcm.count <= maximumBytes else {
            throw AudioCaptureError.recordingTooLarge
        }
        try handle.write(contentsOf: pcm)
        bytesWritten += pcm.count
    }

    public func finish() throws {
        guard !isClosed else { return }
        defer { isClosed = true; try? handle.close() }
        var header = Wav.encode(pcm: Data())
        for (offset, value) in [(4, bytesWritten + 36), (40, bytesWritten)] {
            for byte in 0 ..< 4 { header[offset + byte] = UInt8((value >> (byte * 8)) & 255) }
        }
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
        try handle.synchronize()
    }

    deinit { try? finish() }
}

import Foundation
import zlib

/// A persistent zlib inflate stream (ZRLE uses one per connection, Tight four).
///
/// RFB servers sync-flush each rectangle and never end the stream, so every rectangle's compressed
/// bytes must inflate to exactly that rectangle's data. The `z_stream` lives at a fixed heap address:
/// zlib keeps a back pointer to it and rejects a moved copy. The output buffer is owned here and
/// reused, so decoding a rectangle allocates nothing once it has grown.
final class Inflater {
    private let stream: UnsafeMutablePointer<z_stream>
    private var initialized = false
    private var output = UnsafeMutableRawBufferPointer.allocate(byteCount: 4096, alignment: 16)
    private var scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)

    init() {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
    }

    deinit {
        if initialized { inflateEnd(stream) }
        stream.deinitialize(count: 1)
        stream.deallocate()
        output.deallocate()
        scratch.deallocate()
    }

    /// Drops the dictionary and state (Tight reset bits); the next call starts a new zlib stream.
    func reset() {
        if initialized { inflateReset(stream) }
    }

    /// Inflates all of `input`, producing at most `maxOutput` bytes. Throws if the data is corrupt,
    /// if it would produce more, or if some input cannot be consumed. The result stays valid until
    /// the next call.
    func inflate(_ input: UnsafeRawBufferPointer, maxOutput: Int,
                 _ what: StaticString) throws(RFBError) -> UnsafeRawBufferPointer {
        if !initialized {
            guard inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
                throw .protocolViolation("\(what): zlib initialisation failed")
            }
            initialized = true
        }
        // Grows on demand up to the limit; most rectangles compress at least 2:1.
        var capacity = min(maxOutput, max(4 * input.count, 4096))
        reserve(capacity, keeping: 0)
        var consumed = 0
        var produced = 0
        defer {
            stream.pointee.next_in = nil
            stream.pointee.next_out = nil
        }
        while true {
            if produced == capacity, capacity < maxOutput {
                capacity = min(maxOutput, max(capacity * 2, capacity + 4096))
                reserve(capacity, keeping: produced)
            }
            // At the limit, keep inflating into a 1-byte scratch buffer: the remaining input may be only
            // the empty sync-flush block, which yields nothing; any real output is an overflow.
            let atLimit = produced == capacity
            stream.pointee.next_in = input.baseAddress.map {
                UnsafeMutablePointer(mutating: ($0 + consumed).assumingMemoryBound(to: Bytef.self))
            }
            stream.pointee.avail_in = uInt(input.count - consumed)
            let target = atLimit ? scratch : UnsafeMutableRawBufferPointer(rebasing: output[produced..<capacity])
            stream.pointee.next_out = target.baseAddress?.assumingMemoryBound(to: Bytef.self)
            stream.pointee.avail_out = uInt(target.count)
            let status = zlib.inflate(stream, Z_SYNC_FLUSH)
            consumed = input.count - Int(stream.pointee.avail_in)
            let written = target.count - Int(stream.pointee.avail_out)
            guard !atLimit || written == 0 else {
                throw .protocolViolation("\(what): zlib output exceeds the expected size")
            }
            produced += written
            switch status {
            case Z_OK, Z_BUF_ERROR:
                // Done once all input is consumed and the output buffer still has room (nothing pending).
                if consumed == input.count, produced < capacity || atLimit {
                    return UnsafeRawBufferPointer(rebasing: output[0..<produced])
                }
                // No progress although input remains and there is room: the data is truncated or bogus.
                if status == Z_BUF_ERROR, produced < capacity || atLimit {
                    throw .protocolViolation("\(what): truncated zlib data")
                }
            case Z_STREAM_END:
                guard consumed == input.count else {
                    throw .protocolViolation("\(what): data after the end of the zlib stream")
                }
                return UnsafeRawBufferPointer(rebasing: output[0..<produced])
            default:
                throw .protocolViolation("\(what): corrupt zlib data (status \(status))")
            }
        }
    }

    /// Makes `output` at least `capacity` bytes, keeping its first `kept` bytes.
    private func reserve(_ capacity: Int, keeping kept: Int) {
        guard capacity > output.count else { return }
        let grown = UnsafeMutableRawBufferPointer.allocate(byteCount: max(capacity, 2 * output.count), alignment: 16)
        if kept > 0 { grown.baseAddress!.copyMemory(from: output.baseAddress!, byteCount: kept) }
        output.deallocate()
        output = grown
    }
}

import Foundation

/// A real bump allocator over aligned slabs.
/// - allocate<T>(count) returns UnsafeMutableBufferPointer<T>
/// - reset() reuses slabs without freeing (fast)
/// - deinit frees all slabs
final class Arena: @unchecked Sendable {
    final class Slab {
        let ptr: UnsafeMutableRawPointer
        let size: Int
        var offset: Int = 0

        init(size: Int, alignment: Int) {
            self.size = size
            // aligned allocation
            self.ptr = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: alignment)
        }

        deinit { ptr.deallocate() }
    }

    private let alignment: Int
    private let slabSize: Int
    private var slabs: [Slab] = []
    private var current: Slab?

    private(set) var bytesInUse: Int = 0
    private(set) var bytesPeak: Int = 0

    init(slabSize: Int = 1 << 20, alignment: Int = 64) { // default 1MB slabs, 64B align
        self.slabSize = slabSize
        self.alignment = alignment
    }

    func reset() {
        for s in slabs { s.offset = 0 }
        current = slabs.first
        bytesInUse = 0
        // keep peak as historical high-water mark
    }

    private func ensureSlab(minBytes: Int) {
        if current == nil {
            let s = Slab(size: max(slabSize, minBytes), alignment: alignment)
            slabs.append(s)
            current = s
            return
        }
        if let c = current, c.offset + minBytes <= c.size { return }
        // try reuse an existing slab with offset=0 beyond current
        if let idx = slabs.firstIndex(where: { $0.offset == 0 && $0 !== current }) {
            current = slabs[idx]
            return
        }
        let s = Slab(size: max(slabSize, minBytes), alignment: alignment)
        slabs.append(s)
        current = s
    }

    func allocateRaw(byteCount: Int, alignment: Int) -> UnsafeMutableRawPointer {
        let align = max(self.alignment, alignment)
        let padMask = align - 1
        let needed = byteCount + padMask

        ensureSlab(minBytes: needed)
        let c = current!

        let base = c.ptr.advanced(by: c.offset)
        let mis = Int(bitPattern: base) & padMask
        let pad = (mis == 0) ? 0 : (align - mis)
        let start = c.offset + pad

        if start + byteCount > c.size {
            // allocate new slab big enough
            let s = Slab(size: max(slabSize, byteCount + padMask), alignment: self.alignment)
            slabs.append(s)
            current = s
            return allocateRaw(byteCount: byteCount, alignment: alignment)
        }

        c.offset = start + byteCount
        bytesInUse += byteCount
        bytesPeak = max(bytesPeak, bytesInUse)
        return c.ptr.advanced(by: start)
    }

    func allocate<T>(_ type: T.Type = T.self, count: Int) -> UnsafeMutableBufferPointer<T> {
        precondition(count >= 0)
        let bytes = count * MemoryLayout<T>.stride
        let p = allocateRaw(byteCount: max(bytes, 1), alignment: MemoryLayout<T>.alignment)
        let tp = p.bindMemory(to: T.self, capacity: max(count, 1))
        return UnsafeMutableBufferPointer(start: tp, count: count)
    }
}

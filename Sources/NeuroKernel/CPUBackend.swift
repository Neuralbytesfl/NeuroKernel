import Foundation
import Accelerate

enum CPUBackend {
    static func dense(input: UnsafeBufferPointer<Float>, params: DenseParams, arena: Arena) -> UnsafeMutableBufferPointer<Float> {
        precondition(input.count == params.inSize)
        let out = arena.allocate(Float.self, count: params.outSize)

        // y = W * x + b ; W is out x in (row-major)
        // Use vDSP_mmul for matrix-vector: out(1xout) = x(1xin) * W^T? easiest do manual for now,
        // but we keep it safe/fast: vDSP_mmul expects matrices; overhead for small dims.
        // We'll do optimized scalar loop + vDSP dot could be used later.
        for j in 0..<params.outSize {
            var acc = params.b[j]
            let base = j * params.inSize
            // dot
            var dot: Float = 0
            params.w.withUnsafeBufferPointer { wbuf in
                vDSP_dotpr(input.baseAddress!, 1, wbuf.baseAddress!.advanced(by: base), 1, &dot, vDSP_Length(params.inSize))
            }
            acc += dot
            out[j] = acc
        }
        return out
    }

    static func relu(_ x: UnsafeBufferPointer<Float>, arena: Arena) -> UnsafeMutableBufferPointer<Float> {
        let out = arena.allocate(Float.self, count: x.count)
        _ = out.initialize(from: x)
        var zero: Float = 0
        vDSP_vthr(out.baseAddress!, 1, &zero, out.baseAddress!, 1, vDSP_Length(out.count))
        return out
    }

    static func softmax(_ x: UnsafeBufferPointer<Float>, arena: Arena) -> UnsafeMutableBufferPointer<Float> {
        let out = arena.allocate(Float.self, count: x.count)
        _ = out.initialize(from: x)

        var maxv: Float = 0
        vDSP_maxv(out.baseAddress!, 1, &maxv, vDSP_Length(out.count))
        var negMax = -maxv
        vDSP_vsadd(out.baseAddress!, 1, &negMax, out.baseAddress!, 1, vDSP_Length(out.count))

        var n = Int32(out.count)
        vvexpf(out.baseAddress!, out.baseAddress!, &n)

        var sum: Float = 0
        vDSP_sve(out.baseAddress!, 1, &sum, vDSP_Length(out.count))
        var inv: Float = 1.0 / max(sum, 1e-20)
        vDSP_vsmul(out.baseAddress!, 1, &inv, out.baseAddress!, 1, vDSP_Length(out.count))
        return out
    }

    // AUTO-IMPROVEMENT: training path uses array-based ops for forward/backward passes.
    static func denseArray(input: [Float], params: DenseParams) -> [Float] {
        precondition(input.count == params.inSize)
        var out = [Float](repeating: 0, count: params.outSize)
        for j in 0..<params.outSize {
            var acc = params.b[j]
            let base = j * params.inSize
            for i in 0..<params.inSize {
                acc += params.w[base + i] * input[i]
            }
            out[j] = acc
        }
        return out
    }

    static func reluArray(_ x: [Float]) -> [Float] {
        x.map { max(0, $0) }
    }

    static func softmaxArray(_ x: [Float]) -> [Float] {
        guard let mx = x.max() else { return [] }
        let ex = x.map { expf($0 - mx) }
        let sum = max(ex.reduce(0, +), 1e-20)
        let inv: Float = 1.0 / sum
        return ex.map { $0 * inv }
    }
}

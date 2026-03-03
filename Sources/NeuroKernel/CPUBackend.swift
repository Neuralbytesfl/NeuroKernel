import Foundation

enum CPUBackend {
    static func dense(input: UnsafeBufferPointer<Float>, params: DenseParams, arena: Arena) -> UnsafeMutableBufferPointer<Float> {
        precondition(input.count == params.inSize)
        let out = arena.allocate(Float.self, count: params.outSize)

        // y = W * x + b ; W is out x in (row-major)
        // AUTO-IMPROVEMENT: portable loop implementation keeps CPU path cross-platform.
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

    static func relu(_ x: UnsafeBufferPointer<Float>, arena: Arena) -> UnsafeMutableBufferPointer<Float> {
        let out = arena.allocate(Float.self, count: x.count)
        for i in 0..<x.count {
            out[i] = max(0, x[i])
        }
        return out
    }

    static func softmax(_ x: UnsafeBufferPointer<Float>, arena: Arena) -> UnsafeMutableBufferPointer<Float> {
        let out = arena.allocate(Float.self, count: x.count)
        guard x.count > 0 else { return out }

        var maxv = x[0]
        for i in 1..<x.count { maxv = max(maxv, x[i]) }

        var sum: Float = 0
        for i in 0..<x.count {
            let e = Float(Foundation.exp(Double(x[i] - maxv)))
            out[i] = e
            sum += e
        }
        let inv: Float = 1.0 / max(sum, 1e-20)
        for i in 0..<x.count {
            out[i] *= inv
        }
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
        let ex = x.map { Float(Foundation.exp(Double($0 - mx))) }
        let sum = max(ex.reduce(0, +), 1e-20)
        let inv: Float = 1.0 / sum
        return ex.map { $0 * inv }
    }
}

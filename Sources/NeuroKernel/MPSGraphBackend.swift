import Foundation

// Compatibility runner used for `device=gpu` when MPSGraph APIs differ across SDKs.
// It preserves functional behavior by executing the model with the CPU backend.
final class MPSGraphRunner {
    private let model: ModelGraph
    private let arena = Arena()

    init(model: ModelGraph) throws {
        self.model = model
    }

    func run(input: [Float]) throws -> [Float] {
        guard input.count == model.inputSize else {
            throw NKError.runtime("Input size mismatch: got \(input.count) expected \(model.inputSize)")
        }

        arena.reset()
        var xBuf = arena.allocate(Float.self, count: input.count)
        _ = xBuf.initialize(from: input)

        for nodeName in model.chain {
            guard let node = model.nodes.first(where: { $0.name == nodeName }) else {
                throw NKError.runtime("Missing node \(nodeName)")
            }

            switch node.kind {
            case .input:
                break
            case .dense:
                guard let dp = node.dense else {
                    throw NKError.runtime("Dense missing params \(node.name)")
                }
                xBuf = CPUBackend.dense(input: UnsafeBufferPointer(xBuf), params: dp, arena: arena)
            case .relu:
                xBuf = CPUBackend.relu(UnsafeBufferPointer(xBuf), arena: arena)
            case .softmax:
                xBuf = CPUBackend.softmax(UnsafeBufferPointer(xBuf), arena: arena)
            }
        }

        return Array(UnsafeBufferPointer(xBuf))
    }
}

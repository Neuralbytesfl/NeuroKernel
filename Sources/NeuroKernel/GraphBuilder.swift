import Foundation
import Darwin

final class GraphBuilder {
    private let kernel: Kernel

    init(kernel: Kernel) { self.kernel = kernel }

    // Graph block format:
    // model create <name> graph begin
    //   input <n>
    //   dense <name> in <n> out <m>
    //   relu <name>
    //   softmax <name>
    //   chain <node1> <node2> ...
    // graph end
    func buildModelFromBlock(modelName: String, lines: [Cmd]) throws {
        var inputSize: Int? = nil
        var nodes: [Node] = []
        var chain: [String] = []

        func requireInput(_ n: Int) throws {
            if let i = inputSize, i != n { throw NKError.runtime("input already set to \(i), got \(n)") }
            inputSize = n
        }

        for cmd in lines {
            switch cmd.op {
            case "input":
                guard cmd.args.count >= 1, let n = Int(cmd.args[0]) else { throw NKError.parse("input <n>") }
                try requireInput(n)
                nodes.append(Node(name: "input", kind: .input, dense: nil))

            case "dense":
                // dense d1 in 4 out 16
                guard cmd.args.count >= 5 else { throw NKError.parse("dense <name> in <n> out <m>") }
                let name = cmd.args[0]
                guard cmd.args[1].lowercased() == "in", let inN = Int(cmd.args[2]),
                      cmd.args[3].lowercased() == "out", let outN = Int(cmd.args[4]) else {
                    throw NKError.parse("dense <name> in <n> out <m>")
                }
                // AUTO-IMPROVEMENT: He/Kaiming-style fan-in scaling improves deep ReLU training stability.
                let fanIn = max(1, inN)
                let heScale = Float(sqrt(6.0 / Double(fanIn)))
                let w = try kernel.randFloats(count: outN * inN, scale: heScale)
                // AUTO-IMPROVEMENT: non-zero bias init helps break symmetry for small training datasets.
                let b = try kernel.randFloats(count: outN, scale: 0.01)
                let dp = DenseParams(inSize: inN, outSize: outN, w: w, b: b)
                nodes.append(Node(name: name, kind: .dense, dense: dp))

            case "relu":
                guard let name = cmd.args.first else { throw NKError.parse("relu <name>") }
                nodes.append(Node(name: name, kind: .relu, dense: nil))

            case "softmax":
                guard let name = cmd.args.first else { throw NKError.parse("softmax <name>") }
                nodes.append(Node(name: name, kind: .softmax, dense: nil))

            case "chain":
                chain = cmd.args
                if chain.isEmpty { throw NKError.parse("chain <node1> <node2> ...") }

            default:
                throw NKError.parse("Unknown graph directive: \(cmd.op)")
            }
        }

        guard let inSz = inputSize else { throw NKError.runtime("graph missing input <n>") }
        guard !chain.isEmpty else { throw NKError.runtime("graph missing chain ...") }

        try kernel.modelCreateGraph(name: modelName, inputSize: inSz, nodes: nodes, chain: chain)
    }
}

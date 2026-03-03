import Foundation

enum DeviceKind: String, Codable {
    case cpu
    case gpu
}

enum NodeKind: String, Codable {
    case input
    case dense
    case relu
    case softmax
}

struct DenseParams: Codable {
    var inSize: Int
    var outSize: Int
    var w: [Float]   // row-major out x in
    var b: [Float]   // out
}

struct Node: Codable {
    var name: String
    var kind: NodeKind
    var dense: DenseParams? = nil
}

struct ModelGraph: Codable {
    var name: String
    var inputSize: Int
    var nodes: [Node]
    var chain: [String] // ordered execution chain by node names
}

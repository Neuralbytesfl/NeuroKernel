import Foundation

struct CtxState: Codable {
    var lastInput: [Float] = []
    var lastOutput: [Float] = []
    var step: UInt64 = 0
    var kv: [String: String] = [:]
}

final class Context: Codable {
    let name: String
    let modelName: String
    var device: DeviceKind

    // persistent state
    var state: CtxState

    // arenas are runtime-only; on decode, new arena is created
    var arena: Arena = Arena()

    // GPU runner cached runtime-only
    var gpuRunner: MPSGraphRunner? = nil

    private enum CodingKeys: String, CodingKey {
        case name, modelName, device, state
    }

    init(name: String, modelName: String, device: DeviceKind) {
        self.name = name
        self.modelName = modelName
        self.device = device
        self.state = CtxState()
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        modelName = try c.decode(String.self, forKey: .modelName)
        device = try c.decode(DeviceKind.self, forKey: .device)
        state = try c.decode(CtxState.self, forKey: .state)
        arena = Arena()
        gpuRunner = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(modelName, forKey: .modelName)
        try c.encode(device, forKey: .device)
        try c.encode(state, forKey: .state)
    }
}

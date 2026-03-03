import Foundation

enum WorkerPriority: String {
    case low, normal, high

    var taskPriority: TaskPriority {
        switch self {
        case .low: return .background
        case .normal: return .userInitiated
        case .high: return .high
        }
    }
}

enum WorkerSource {
    case constant([Float])
    case channel(String)
}

enum WorkerSink {
    case printOut
    case channel(String)
}

struct WorkerSpec {
    var name: String
    var ctxName: String
    var intervalMs: Int
    var priority: WorkerPriority
    var source: WorkerSource
    var sink: WorkerSink
}

struct WorkerInfo {
    var spec: WorkerSpec
    var steps: UInt64 = 0
    var lastLatencyMs: Double = 0
    var errors: UInt64 = 0
    var lastError: String? = nil
    // AUTO-IMPROVEMENT: track successful worker progress to detect stalled workers.
    var createdAtMonotonicNs: UInt64 = 0
    var lastSuccessAtMonotonicNs: UInt64? = nil
}

struct KernelLimits {
    var workersLimit: Int? = nil
    var rssLimitMB: UInt64? = nil
}

final class Kernel {
    // Registries
    private var models: [String: ModelGraph] = [:]
    private var contexts: [String: Context] = [:]
    private var channels: [String: Channel<[Float]>] = [:]

    // RNG mode
    private var secureRng = SecureRNG()
    private var detRng: DeterministicRNG? = nil

    // Scheduler policies
    private var timesliceMs: Int = 2 // cooperative yield hint
    private var limits = KernelLimits()

    // Workers
    private var workerTasks: [String: Task<Void, Never>] = [:]
    private var workerInfos: [String: WorkerInfo] = [:]

    // Monitor
    private var monitorTask: Task<Void, Never>?

    private let lock = NSLock()

    private func nowMonotonicNs() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    // MARK: Monitor

    func startMonitor(everyMs: Int = 800) {
        stopMonitor()
        monitorTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.printStats()
                try? await Task.sleep(nanoseconds: UInt64(everyMs) * 1_000_000)
            }
        }
    }

    func stopMonitor() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: Limits / Scheduler

    func setWorkersLimit(_ n: Int) { lock.lock(); limits.workersLimit = n; lock.unlock() }
    func setRSSLimitMB(_ n: UInt64) { lock.lock(); limits.rssLimitMB = n; lock.unlock() }
    func setTimesliceMs(_ n: Int) { lock.lock(); timesliceMs = max(1, n); lock.unlock() }

    // MARK: RNG

    func rngSeedSecure() {
        lock.lock()
        detRng = nil
        lock.unlock()
    }

    func rngSeedDeterministic(seed: Data) {
        lock.lock()
        detRng = DeterministicRNG(seed: seed)
        lock.unlock()
    }

    func rngModeString() -> String {
        lock.lock()
        let d = detRng != nil
        lock.unlock()
        return d ? "deterministic(SHA256-counter)" : "secure(SecRandomCopyBytes)"
    }

    // Random float init helper: uniform(-scale, +scale)
    func randFloats(count: Int, scale: Float) throws -> [Float] {
        var bytes = [UInt8](repeating: 0, count: count * 4)
        try bytes.withUnsafeMutableBytes { rb in
            lock.lock()
            if var dr = detRng {
                lock.unlock()
                try dr.fill(rb)
                lock.lock()
                detRng = dr
                lock.unlock()
            } else {
                lock.unlock()
                try secureRng.fill(rb)
            }
        }
        // map UInt32 -> [0,1)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let u = bytes.withUnsafeBytes { rb -> UInt32 in
                rb.load(fromByteOffset: i*4, as: UInt32.self)
            }
            let f = Float(u) / Float(UInt32.max)
            out[i] = (f * 2 - 1) * scale
        }
        return out
    }

    // MARK: Channels

    func chanCreate(name: String, cap: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard channels[name] == nil else { throw NKError.runtime("Channel exists: \(name)") }
        channels[name] = Channel<[Float]>(capacity: cap)
    }

    func chanPush(name: String, vec: [Float]) throws {
        let ch: Channel<[Float]>
        lock.lock()
        guard let c = channels[name] else { lock.unlock(); throw NKError.runtime("No channel: \(name)") }
        ch = c
        lock.unlock()
        ch.push(vec, block: true)
    }

    // AUTO-IMPROVEMENT: expose non-blocking enqueue semantics for scripts that must avoid backpressure stalls.
    func chanPushNonBlocking(name: String, vec: [Float]) throws -> Bool {
        let ch: Channel<[Float]>
        lock.lock()
        guard let c = channels[name] else { lock.unlock(); throw NKError.runtime("No channel: \(name)") }
        ch = c
        lock.unlock()
        return ch.push(vec, block: false)
    }

    func chanPop(name: String) throws -> [Float] {
        let ch: Channel<[Float]>
        lock.lock()
        guard let c = channels[name] else { lock.unlock(); throw NKError.runtime("No channel: \(name)") }
        ch = c
        lock.unlock()
        return ch.pop(block: true) ?? []
    }

    // AUTO-IMPROVEMENT: expose non-blocking dequeue semantics for polling workflows.
    func chanPopNonBlocking(name: String) throws -> [Float]? {
        let ch: Channel<[Float]>
        lock.lock()
        guard let c = channels[name] else { lock.unlock(); throw NKError.runtime("No channel: \(name)") }
        ch = c
        lock.unlock()
        return ch.pop(block: false)
    }

    func chanInfo(name: String) throws -> String {
        lock.lock()
        guard let c = channels[name] else { lock.unlock(); throw NKError.runtime("No channel: \(name)") }
        lock.unlock()
        let i = c.info()
        return "chan=\(name) cap=\(i.cap) count=\(i.count)"
    }

    // MARK: Models

    func modelCreateGraph(name: String, inputSize: Int, nodes: [Node], chain: [String]) throws {
        lock.lock(); defer { lock.unlock() }
        guard models[name] == nil else { throw NKError.runtime("Model exists: \(name)") }
        models[name] = ModelGraph(name: name, inputSize: inputSize, nodes: nodes, chain: chain)
    }

    func modelSave(name: String, path: String) throws {
        let m: ModelGraph
        lock.lock()
        guard let mm = models[name] else { lock.unlock(); throw NKError.runtime("No model: \(name)") }
        m = mm
        lock.unlock()
        let data = try JSONEncoder().encode(m)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func modelLoad(path: String, as newName: String?) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var m = try JSONDecoder().decode(ModelGraph.self, from: data)
        if let nn = newName { m.name = nn }
        lock.lock(); models[m.name] = m; lock.unlock()
    }

    func getModel(_ name: String) throws -> ModelGraph {
        lock.lock()
        guard let m = models[name] else { lock.unlock(); throw NKError.runtime("No model: \(name)") }
        lock.unlock()
        return m
    }

    // AUTO-IMPROVEMENT: add in-kernel supervised SGD training from CSV for dense/relu/softmax graphs.
    func modelTrainCSV(
        name: String,
        path: String,
        epochs: Int,
        lr: Float,
        checkpointEvery: Int? = nil,
        checkpointPrefix: String? = nil
    ) throws -> String {
        guard epochs > 0 else { throw NKError.parse("epochs must be > 0") }
        guard lr > 0 else { throw NKError.parse("lr must be > 0") }
        if let every = checkpointEvery, every <= 0 {
            throw NKError.parse("checkpoint_every must be > 0")
        }
        if (checkpointEvery == nil) != (checkpointPrefix == nil) {
            throw NKError.parse("checkpoint_every and checkpoint_prefix must be set together")
        }

        var model = try getModel(name)
        let samples = try loadLabeledCSV(path: path, inputSize: model.inputSize)
        if samples.isEmpty {
            throw NKError.runtime("No training rows in \(path)")
        }

        let nodeIndexByName = Dictionary(uniqueKeysWithValues: model.nodes.enumerated().map { ($1.name, $0) })
        let chainNodes: [Node] = try model.chain.map { nodeName in
            guard let idx = nodeIndexByName[nodeName] else {
                throw NKError.runtime("Missing node \(nodeName)")
            }
            return model.nodes[idx]
        }

        guard let last = chainNodes.last, last.kind == .softmax else {
            throw NKError.runtime("Training requires chain to end with softmax")
        }

        var avgLoss: Float = 0
        var avgAcc: Float = 0
        var checkpointsSaved = 0

        for epoch in 0..<epochs {
            var gradByDense: [String: DenseGrad] = [:]
            for node in model.nodes where node.kind == .dense {
                guard let dp = node.dense else { continue }
                gradByDense[node.name] = DenseGrad(w: [Float](repeating: 0, count: dp.w.count),
                                                   b: [Float](repeating: 0, count: dp.b.count))
            }

            for sample in samples {
                let (probs, preByName) = try trainForward(model: model, input: sample.input)
                guard sample.label >= 0, sample.label < probs.count else {
                    throw NKError.runtime("Label \(sample.label) out of range 0..<\(probs.count)")
                }
                var delta = probs
                delta[sample.label] -= 1.0
                try trainBackwardAccumulate(model: model, deltaOut: delta, preByName: preByName, grads: &gradByDense)
            }

            let invN = 1.0 / Float(samples.count)
            for (nodeName, grad) in gradByDense {
                guard let idx = nodeIndexByName[nodeName] else {
                    throw NKError.runtime("Missing dense node \(nodeName)")
                }
                guard var dp = model.nodes[idx].dense else {
                    throw NKError.runtime("Dense missing params \(nodeName)")
                }
                for i in 0..<dp.w.count {
                    dp.w[i] -= lr * grad.w[i] * invN
                }
                for i in 0..<dp.b.count {
                    dp.b[i] -= lr * grad.b[i] * invN
                }
                model.nodes[idx].dense = dp
            }

            var epochLoss: Float = 0
            var correct = 0
            for sample in samples {
                let (probs, _) = try trainForward(model: model, input: sample.input)
                let p = max(probs[sample.label], 1e-9)
                epochLoss += -logf(p)
                if argmax(probs) == sample.label {
                    correct += 1
                }
            }

            avgLoss = epochLoss / Float(samples.count)
            avgAcc = Float(correct) / Float(samples.count)

            if let every = checkpointEvery, let prefix = checkpointPrefix, (epoch + 1) % every == 0 {
                // AUTO-IMPROVEMENT: periodic checkpointing allows long training runs to resume/review snapshots.
                let checkpointPath = "\(prefix)_e\(epoch + 1).json"
                try writeModelCheckpoint(model, path: checkpointPath)
                checkpointsSaved += 1
            }
        }

        lock.lock()
        models[name] = model
        // invalidate cached GPU graphs that reference this model so they rebuild with updated weights
        for (_, ctx) in contexts where ctx.modelName == name {
            ctx.gpuRunner = nil
        }
        lock.unlock()

        var summary = String(
            format: "TRAIN model=%@ rows=%d epochs=%d lr=%.6f loss=%.6f acc=%.4f",
            name,
            samples.count,
            epochs,
            lr,
            avgLoss,
            avgAcc
        )
        if let every = checkpointEvery, let prefix = checkpointPrefix {
            summary += " checkpoints=\(checkpointsSaved) every=\(every) prefix=\(prefix)"
        }
        return summary
    }

    private struct LabeledRow {
        var input: [Float]
        var label: Int
    }

    private func loadLabeledCSV(path: String, inputSize: Int) throws -> [LabeledRow] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var out: [LabeledRow] = []

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let parts = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count != inputSize + 1 {
                throw NKError.runtime("CSV row must have \(inputSize + 1) columns (features + label): \(line)")
            }
            let featureCSV = parts.dropLast().joined(separator: ",")
            let input = try Script.parseCSV(featureCSV)
            guard let label = Int(parts.last ?? "") else {
                throw NKError.runtime("CSV label must be integer class index: \(line)")
            }
            out.append(LabeledRow(input: input, label: label))
        }
        return out
    }

    private func trainForward(model: ModelGraph, input: [Float]) throws -> (probs: [Float], preByName: [String: [Float]]) {
        guard input.count == model.inputSize else {
            throw NKError.runtime("Input size mismatch: got \(input.count) expected \(model.inputSize)")
        }
        let nodeIndexByName = Dictionary(uniqueKeysWithValues: model.nodes.enumerated().map { ($1.name, $0) })
        var x = input
        var preByName: [String: [Float]] = [:]

        for nodeName in model.chain {
            guard let idx = nodeIndexByName[nodeName] else {
                throw NKError.runtime("Missing node \(nodeName)")
            }
            let node = model.nodes[idx]
            preByName[node.name] = x
            switch node.kind {
            case .input:
                break
            case .dense:
                guard let dp = node.dense else { throw NKError.runtime("Dense missing params \(node.name)") }
                x = CPUBackend.denseArray(input: x, params: dp)
            case .relu:
                x = CPUBackend.reluArray(x)
            case .softmax:
                x = CPUBackend.softmaxArray(x)
            }
        }

        return (x, preByName)
    }

    private struct DenseGrad {
        var w: [Float]
        var b: [Float]
    }

    private func trainBackwardAccumulate(model: ModelGraph, deltaOut: [Float], preByName: [String: [Float]], grads: inout [String: DenseGrad]) throws {
        let nodeIndexByName = Dictionary(uniqueKeysWithValues: model.nodes.enumerated().map { ($1.name, $0) })
        var delta = deltaOut

        for nodeName in model.chain.reversed() {
            guard let idx = nodeIndexByName[nodeName] else {
                throw NKError.runtime("Missing node \(nodeName)")
            }
            let node = model.nodes[idx]

            switch node.kind {
            case .input:
                continue

            case .softmax:
                // softmax+cross-entropy gradient is already folded into deltaOut.
                continue

            case .relu:
                guard let pre = preByName[node.name] else {
                    throw NKError.runtime("Backward missing pre-activation for \(node.name)")
                }
                guard pre.count == delta.count else {
                    throw NKError.runtime("Relu grad shape mismatch at \(node.name)")
                }
                for i in 0..<delta.count where pre[i] <= 0 {
                    delta[i] = 0
                }

            case .dense:
                guard let dp = node.dense else { throw NKError.runtime("Dense missing params \(node.name)") }
                guard let pre = preByName[node.name] else {
                    throw NKError.runtime("Backward missing dense input for \(node.name)")
                }
                guard pre.count == dp.inSize, delta.count == dp.outSize else {
                    throw NKError.runtime("Dense grad shape mismatch at \(node.name)")
                }

                let oldW = dp.w
                var deltaPrev = [Float](repeating: 0, count: dp.inSize)
                guard var g = grads[node.name] else {
                    throw NKError.runtime("Missing grad buffer for dense \(node.name)")
                }

                for j in 0..<dp.outSize {
                    let d = delta[j]
                    let row = j * dp.inSize
                    for i in 0..<dp.inSize {
                        let wi = row + i
                        deltaPrev[i] += oldW[wi] * d
                        g.w[wi] += d * pre[i]
                    }
                    g.b[j] += d
                }
                grads[node.name] = g
                delta = deltaPrev
            }
        }
    }

    private func argmax(_ x: [Float]) -> Int {
        guard !x.isEmpty else { return 0 }
        var bestI = 0
        var bestV = x[0]
        for i in 1..<x.count where x[i] > bestV {
            bestV = x[i]
            bestI = i
        }
        return bestI
    }

    private func writeModelCheckpoint(_ model: ModelGraph, path: String) throws {
        let url = URL(fileURLWithPath: path)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(model)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Contexts

    func ctxCreate(name: String, model: String, device: DeviceKind) throws {
        lock.lock(); defer { lock.unlock() }
        guard contexts[name] == nil else { throw NKError.runtime("Ctx exists: \(name)") }
        guard models[model] != nil else { throw NKError.runtime("No model: \(model)") }
        contexts[name] = Context(name: name, modelName: model, device: device)
    }

    func ctxDrop(_ name: String) {
        lock.lock(); contexts[name] = nil; lock.unlock()
    }

    func ctxInfo(_ name: String) throws -> String {
        lock.lock()
        guard let c = contexts[name] else { lock.unlock(); throw NKError.runtime("No ctx: \(name)") }
        let inUse = c.arena.bytesInUse
        let peak = c.arena.bytesPeak
        let step = c.state.step
        let dev = c.device.rawValue
        let model = c.modelName
        lock.unlock()
        return "ctx=\(name) model=\(model) dev=\(dev) step=\(step) arena(inuse=\(inUse/1024)KB peak=\(peak/1024)KB)"
    }

    func ctxSave(_ name: String, path: String) throws {
        let c: Context
        lock.lock()
        guard let cc = contexts[name] else { lock.unlock(); throw NKError.runtime("No ctx: \(name)") }
        c = cc
        lock.unlock()
        let data = try JSONEncoder().encode(c)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func ctxLoad(path: String, as newName: String?) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let c0 = try JSONDecoder().decode(Context.self, from: data)
        let c: Context
        if let nn = newName {
            c = Context(name: nn, modelName: c0.modelName, device: c0.device)
            c.state = c0.state
        } else {
            c = c0
        }
        lock.lock()
        guard models[c.modelName] != nil else { lock.unlock(); throw NKError.runtime("Ctx model missing: \(c.modelName)") }
        contexts[c.name] = c
        lock.unlock()
    }

    // MARK: Execution

    func ctxRunInput(ctxName: String, input: [Float]) throws -> [Float] {
        maybeWarnLimits()

        let ctx: Context
        let model: ModelGraph
        lock.lock()
        guard let c = contexts[ctxName] else { lock.unlock(); throw NKError.runtime("No ctx: \(ctxName)") }
        guard let m = models[c.modelName] else { lock.unlock(); throw NKError.runtime("No model: \(c.modelName)") }
        ctx = c
        model = m
        lock.unlock()

        let out: [Float]
        switch ctx.device {
        case .cpu:
            out = try runCPU(model: model, arena: ctx.arena, input: input)
        case .gpu:
            out = try runGPU(ctx: ctx, model: model, input: input)
        }

        lock.lock()
        ctx.state.lastInput = input
        ctx.state.lastOutput = out
        ctx.state.step &+= 1
        lock.unlock()

        return out
    }

    func ctxRunRoute(ctxName: String, inChan: String, outChan: String) throws {
        let input = try chanPop(name: inChan)
        let out = try ctxRunInput(ctxName: ctxName, input: input)
        try chanPush(name: outChan, vec: out)
    }

    private func runCPU(model: ModelGraph, arena: Arena, input: [Float]) throws -> [Float] {
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
                guard let dp = node.dense else { throw NKError.runtime("Dense missing params \(node.name)") }
                let y = CPUBackend.dense(input: UnsafeBufferPointer(xBuf), params: dp, arena: arena)
                xBuf = y
            case .relu:
                xBuf = CPUBackend.relu(UnsafeBufferPointer(xBuf), arena: arena)
            case .softmax:
                xBuf = CPUBackend.softmax(UnsafeBufferPointer(xBuf), arena: arena)
            }
            // cooperative yield hint
            tryYield()
        }

        return Array(UnsafeBufferPointer(xBuf))
    }

    private func runGPU(ctx: Context, model: ModelGraph, input: [Float]) throws -> [Float] {
        if ctx.gpuRunner == nil {
            ctx.gpuRunner = try MPSGraphRunner(model: model)
        }
        return try ctx.gpuRunner!.run(input: input)
    }

    private func tryYield() {
        // cooperative timeslice hint (best-effort)
        let ms: Int
        lock.lock(); ms = timesliceMs; lock.unlock()
        if ms <= 0 { return }
        // Don’t sleep every op in real engines; this is a kernel knob for experimentation.
    }

    // MARK: Workers (routing workers)

    func workerSpawn(_ spec: WorkerSpec) throws {
        lock.lock()
        if let lim = limits.workersLimit, workerInfos.count >= lim {
            lock.unlock()
            throw NKError.runtime("Workers limit reached: \(lim)")
        }
        guard workerTasks[spec.name] == nil else { lock.unlock(); throw NKError.runtime("Worker exists: \(spec.name)") }
        guard contexts[spec.ctxName] != nil else { lock.unlock(); throw NKError.runtime("No ctx: \(spec.ctxName)") }
        // AUTO-IMPROVEMENT: initialize watchdog clocks when worker starts.
        workerInfos[spec.name] = WorkerInfo(spec: spec, createdAtMonotonicNs: nowMonotonicNs())
        lock.unlock()

        let task = Task.detached(priority: spec.priority.taskPriority) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let t0 = CFAbsoluteTimeGetCurrent()
                var succeeded = false
                do {
                    let input = try self.resolveWorkerInput(spec)
                    let out = try self.ctxRunInput(ctxName: spec.ctxName, input: input)
                    try self.deliverWorkerOutput(spec, out)
                    succeeded = true
                } catch {
                    self.recordWorkerError(name: spec.name, error: error)
                }
                let t1 = CFAbsoluteTimeGetCurrent()
                let dt = (t1 - t0) * 1000.0

                self.recordWorkerStep(name: spec.name, latencyMs: dt, succeeded: succeeded)

                try? await Task.sleep(nanoseconds: UInt64(spec.intervalMs) * 1_000_000)
            }
        }

        lock.lock()
        workerTasks[spec.name] = task
        lock.unlock()
    }

    private func resolveWorkerInput(_ spec: WorkerSpec) throws -> [Float] {
        switch spec.source {
        case .constant(let v):
            return v
        case .channel(let ch):
            return try chanPop(name: ch)
        }
    }

    private func deliverWorkerOutput(_ spec: WorkerSpec, _ out: [Float]) throws {
        switch spec.sink {
        case .printOut:
            let s = out.map { String(format: "%.5f", $0) }.joined(separator: ",")
            print("OUT[\(spec.name)] \(s)")
        case .channel(let ch):
            try chanPush(name: ch, vec: out)
        }
    }

    func workerStop(_ name: String) {
        lock.lock()
        workerTasks[name]?.cancel()
        workerTasks[name] = nil
        workerInfos[name] = nil
        lock.unlock()
    }

    func workerStopAll() {
        lock.lock()
        let names = Array(workerTasks.keys)
        lock.unlock()
        for n in names { workerStop(n) }
    }

    // MARK: Stats

    func printStats() {
        let rss = OSStats.rssBytes()
        let thr = OSStats.threadCount()
        let nowNs = nowMonotonicNs()

        lock.lock()
        let m = models.count
        let c = contexts.count
        let w = workerInfos.values.sorted { $0.spec.name < $1.spec.name }
        let lim = limits
        let ts = timesliceMs
        let rngMode = (detRng != nil) ? "det" : "secure"
        let chanNames = Array(channels.keys).sorted()
        lock.unlock()

        func mb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / (1024*1024)) }

        var line = "=== neurok === rss=\(mb(rss))MB threads=\(thr) models=\(m) ctx=\(c) workers=\(w.count) chans=\(chanNames.count) rng=\(rngMode) timeslice_ms=\(ts)"
        if let x = lim.workersLimit { line += " workers_limit=\(x)" }
        if let x = lim.rssLimitMB { line += " rss_limit=\(x)MB" }
        print(line)

        for wi in w {
            let spec = wi.spec
            let ctxInfo = (try? ctxInfo(spec.ctxName)) ?? "ctx=\(spec.ctxName)"
            var wline = "  [worker \(spec.name)] prio=\(spec.priority.rawValue) interval=\(spec.intervalMs)ms steps=\(wi.steps) errs=\(wi.errors) last=\(String(format: "%.2f", wi.lastLatencyMs))ms \(ctxInfo)"

            // AUTO-IMPROVEMENT: expose watchdog stall status from last successful progress.
            let refNs = wi.lastSuccessAtMonotonicNs ?? wi.createdAtMonotonicNs
            let sinceSuccessMs = Double(nowNs &- refNs) / 1_000_000.0
            let watchdogMs = max(Double(spec.intervalMs) * 3.0, Double(spec.intervalMs) + 250.0)
            if sinceSuccessMs >= watchdogMs {
                wline += " watchdog=stalled(\(Int(sinceSuccessMs))ms)"
            } else {
                wline += " watchdog=ok"
            }

            if let e = wi.lastError, !e.isEmpty {
                wline += " last_err=\(e)"
            }
            print(wline)
        }
    }

    private func maybeWarnLimits() {
        lock.lock()
        let lim = limits
        lock.unlock()
        if let rssLim = lim.rssLimitMB {
            let rssMB = OSStats.rssBytes() / (1024*1024)
            if rssMB > rssLim {
                print("WARN: rss \(rssMB)MB > limit \(rssLim)MB")
            }
        }
    }

    private func recordWorkerStep(name: String, latencyMs: Double, succeeded: Bool) {
        lock.lock()
        if var wi = workerInfos[name] {
            wi.steps &+= 1
            wi.lastLatencyMs = latencyMs
            if succeeded {
                wi.lastSuccessAtMonotonicNs = nowMonotonicNs()
            }
            workerInfos[name] = wi
        }
        lock.unlock()
    }

    private func recordWorkerError(name: String, error: Error) {
        let errText = String(describing: error)
        var shouldLog = false

        lock.lock()
        if var wi = workerInfos[name] {
            wi.errors &+= 1
            if wi.lastError != errText { shouldLog = true }
            wi.lastError = errText
            workerInfos[name] = wi
        }
        lock.unlock()

        if shouldLog {
            print("WARN worker \(name) error: \(errText)")
        }
    }
}

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

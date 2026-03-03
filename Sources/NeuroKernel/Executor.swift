import Foundation

enum Executor {
    static func run(kernel: Kernel, cmds: [Cmd]) throws -> Bool {
        var i = 0
        while i < cmds.count {
            let cmd = cmds[i]
            let cont = try runOne(kernel: kernel, cmd: cmd, cmds: cmds, index: &i)
            if !cont { return false }
            i += 1
        }
        return true
    }

    private static func runOne(kernel: Kernel, cmd: Cmd, cmds: [Cmd], index i: inout Int) throws -> Bool {
        switch cmd.op {
        case "help":
            // Print MANUAL.md if present in cwd
            if let s = try? String(contentsOfFile: "Sources/NeuroKernel/MANUAL.md", encoding: .utf8) {
                print(s)
            } else {
                print("See Sources/NeuroKernel/MANUAL.md")
            }

        case "stats":
            kernel.printStats()

        case "sleep", "wait":
            guard cmd.args.count >= 1, let ms = UInt64(cmd.args[0]) else {
                throw NKError.parse("sleep <ms>")
            }
            Thread.sleep(forTimeInterval: Double(ms) / 1000.0)
            print("OK sleep \(ms)ms")

        case "quit", "exit":
            kernel.workerStopAll()
            kernel.stopMonitor()
            return false

        case "sched":
            guard cmd.args.count >= 2 else { throw NKError.parse("sched timeslice_ms <n>") }
            if cmd.args[0].lowercased() == "timeslice_ms" {
                guard let n = Int(cmd.args[1]) else { throw NKError.parse("bad timeslice") }
                kernel.setTimesliceMs(n)
                print("OK sched timeslice_ms \(n)")
            } else {
                throw NKError.parse("sched timeslice_ms <n>")
            }

        case "limit":
            guard cmd.args.count >= 2 else { throw NKError.parse("limit workers <n> | limit rss_mb <n>") }
            let which = cmd.args[0].lowercased()
            if which == "workers" {
                guard let n = Int(cmd.args[1]) else { throw NKError.parse("bad workers") }
                kernel.setWorkersLimit(n)
                print("OK limit workers \(n)")
            } else if which == "rss_mb" {
                guard let n = UInt64(cmd.args[1]) else { throw NKError.parse("bad rss_mb") }
                kernel.setRSSLimitMB(n)
                print("OK limit rss_mb \(n)")
            } else {
                throw NKError.parse("limit workers <n> | limit rss_mb <n>")
            }

        case "rng":
            guard cmd.args.count >= 1 else { throw NKError.parse("rng seed_secure | rng seed_deterministic hex <64-hex> | rng show") }
            let sub = cmd.args[0].lowercased()
            if sub == "seed_secure" {
                kernel.rngSeedSecure()
                print("OK rng secure")
            } else if sub == "seed_deterministic" {
                guard cmd.args.count >= 3, cmd.args[1].lowercased() == "hex" else {
                    throw NKError.parse("rng seed_deterministic hex <hex>")
                }
                let seed = try RNGUtil.hexToData(cmd.args[2])
                kernel.rngSeedDeterministic(seed: seed)
                print("OK rng deterministic")
            } else if sub == "show" {
                print("rng: \(kernel.rngModeString())")
            } else {
                throw NKError.parse("rng seed_secure | rng seed_deterministic hex <hex> | rng show")
            }

        case "chan":
            guard cmd.args.count >= 1 else { throw NKError.parse("chan create|push|push_nb|pop|pop_nb|info ...") }
            let sub = cmd.args[0].lowercased()
            if sub == "create" {
                guard cmd.args.count >= 4, cmd.args[2].lowercased() == "cap", let n = Int(cmd.args[3]) else {
                    throw NKError.parse("chan create <name> cap <n>")
                }
                try kernel.chanCreate(name: cmd.args[1], cap: n)
                print("OK chan create \(cmd.args[1]) cap=\(n)")
            } else if sub == "push" {
                guard cmd.args.count >= 3 else { throw NKError.parse("chan push <name> <csv>") }
                let v = try Script.parseCSV(cmd.args[2])
                try kernel.chanPush(name: cmd.args[1], vec: v)
                print("OK chan push \(cmd.args[1]) len=\(v.count)")
            } else if sub == "push_nb" {
                guard cmd.args.count >= 3 else { throw NKError.parse("chan push_nb <name> <csv>") }
                let v = try Script.parseCSV(cmd.args[2])
                // AUTO-IMPROVEMENT: expose non-blocking channel writes to avoid script stalls on full buffers.
                let enqueued = try kernel.chanPushNonBlocking(name: cmd.args[1], vec: v)
                print(enqueued ? "OK chan push_nb \(cmd.args[1]) len=\(v.count)" : "FULL chan \(cmd.args[1])")
            } else if sub == "pop" {
                guard cmd.args.count >= 2 else { throw NKError.parse("chan pop <name>") }
                let v = try kernel.chanPop(name: cmd.args[1])
                print("CHAN " + v.map { String(format: "%.5f", $0) }.joined(separator: ","))
            } else if sub == "pop_nb" {
                guard cmd.args.count >= 2 else { throw NKError.parse("chan pop_nb <name>") }
                // AUTO-IMPROVEMENT: expose polling reads for reactive scripts and diagnostics.
                if let v = try kernel.chanPopNonBlocking(name: cmd.args[1]) {
                    print("CHAN " + v.map { String(format: "%.5f", $0) }.joined(separator: ","))
                } else {
                    print("EMPTY chan \(cmd.args[1])")
                }
            } else if sub == "info" {
                guard cmd.args.count >= 2 else { throw NKError.parse("chan info <name>") }
                print(try kernel.chanInfo(name: cmd.args[1]))
            } else {
                throw NKError.parse("chan create|push|push_nb|pop|pop_nb|info ...")
            }

        case "model":
            guard cmd.args.count >= 1 else { throw NKError.parse("model create|save|load|train ...") }
            let sub = cmd.args[0].lowercased()

            if sub == "create" {
                // model create <name> graph begin
                guard cmd.args.count >= 4 else { throw NKError.parse("model create <name> graph begin") }
                let name = cmd.args[1]
                guard cmd.args[2].lowercased() == "graph", cmd.args[3].lowercased() == "begin" else {
                    throw NKError.parse("model create <name> graph begin")
                }

                // collect until "graph end"
                var block: [Cmd] = []
                var j = i + 1
                while j < cmds.count {
                    let c = cmds[j]
                    if c.op.lowercased() == "graph", c.args.first?.lowercased() == "end" {
                        break
                    }
                    block.append(c)
                    j += 1
                }
                if j >= cmds.count { throw NKError.parse("missing 'graph end'") }

                // advance i to the 'graph end' line (executor will increment after return)
                i = j

                let gb = GraphBuilder(kernel: kernel)
                try gb.buildModelFromBlock(modelName: name, lines: block)
                print("OK model created \(name)")

            } else if sub == "save" {
                guard cmd.args.count >= 4, cmd.args[2].lowercased() == "path" else {
                    throw NKError.parse("model save <name> path \"file\"")
                }
                try kernel.modelSave(name: cmd.args[1], path: cmd.args[3])
                print("OK model saved \(cmd.args[1]) -> \(cmd.args[3])")

            } else if sub == "load" {
                guard cmd.args.count >= 3, cmd.args[1].lowercased() == "path" else {
                    throw NKError.parse("model load path \"file\" [as name]")
                }
                var asName: String? = nil
                if cmd.args.count >= 5, cmd.args[3].lowercased() == "as" { asName = cmd.args[4] }
                try kernel.modelLoad(path: cmd.args[2], as: asName)
                print("OK model loaded from \(cmd.args[2])")

            } else if sub == "train" {
                // model train <name> csv "<file>" epochs <n> lr <f>
                guard cmd.args.count >= 8 else {
                    throw NKError.parse("model train <name> csv \"file\" epochs <n> lr <f>")
                }
                let name = cmd.args[1]
                guard cmd.args[2].lowercased() == "csv" else {
                    throw NKError.parse("model train <name> csv \"file\" epochs <n> lr <f>")
                }
                let csvPath = cmd.args[3]
                guard cmd.args[4].lowercased() == "epochs", let epochs = Int(cmd.args[5]),
                      cmd.args[6].lowercased() == "lr", let lr = Float(cmd.args[7]) else {
                    throw NKError.parse("model train <name> csv \"file\" epochs <n> lr <f>")
                }
                let summary = try kernel.modelTrainCSV(name: name, path: csvPath, epochs: epochs, lr: lr)
                print("OK \(summary)")

            } else {
                throw NKError.parse("model create|save|load|train ...")
            }

        case "ctx":
            guard cmd.args.count >= 1 else { throw NKError.parse("ctx create|run|save|load|info|drop ...") }
            let sub = cmd.args[0].lowercased()

            if sub == "create" {
                // ctx create <ctx> model <model> device cpu|gpu
                guard cmd.args.count >= 6 else { throw NKError.parse("ctx create <ctx> model <m> device cpu|gpu") }
                let ctx = cmd.args[1]
                guard cmd.args[2].lowercased() == "model" else { throw NKError.parse("ctx create <ctx> model <m> device cpu|gpu") }
                let model = cmd.args[3]
                guard cmd.args[4].lowercased() == "device" else { throw NKError.parse("ctx create <ctx> model <m> device cpu|gpu") }
                guard let dev = DeviceKind(rawValue: cmd.args[5].lowercased()) else { throw NKError.parse("device cpu|gpu") }
                try kernel.ctxCreate(name: ctx, model: model, device: dev)
                print("OK ctx create \(ctx) model=\(model) dev=\(dev.rawValue)")

            } else if sub == "run" {
                // ctx run <ctx> input <csv>
                // ctx run <ctx> inchan <c1> outchan <c2>
                guard cmd.args.count >= 3 else { throw NKError.parse("ctx run <ctx> input <csv> | ctx run <ctx> inchan <c1> outchan <c2>") }
                let ctx = cmd.args[1]
                let mode = cmd.args[2].lowercased()
                if mode == "input" {
                    guard cmd.args.count >= 4 else { throw NKError.parse("ctx run <ctx> input <csv>") }
                    let v = try Script.parseCSV(cmd.args[3])
                    let out = try kernel.ctxRunInput(ctxName: ctx, input: v)
                    print("OUT " + out.map { String(format: "%.5f", $0) }.joined(separator: ","))
                } else if mode == "inchan" {
                    guard cmd.args.count >= 6, cmd.args[4].lowercased() == "outchan" else {
                        throw NKError.parse("ctx run <ctx> inchan <c1> outchan <c2>")
                    }
                    try kernel.ctxRunRoute(ctxName: ctx, inChan: cmd.args[3], outChan: cmd.args[5])
                    print("OK ctx routed \(ctx) \(cmd.args[3]) -> \(cmd.args[5])")
                } else {
                    throw NKError.parse("ctx run <ctx> input <csv> | ctx run <ctx> inchan <c1> outchan <c2>")
                }

            } else if sub == "save" {
                guard cmd.args.count >= 4, cmd.args[2].lowercased() == "path" else {
                    throw NKError.parse("ctx save <ctx> path \"file\"")
                }
                try kernel.ctxSave(cmd.args[1], path: cmd.args[3])
                print("OK ctx saved \(cmd.args[1]) -> \(cmd.args[3])")

            } else if sub == "load" {
                guard cmd.args.count >= 3, cmd.args[1].lowercased() == "path" else {
                    throw NKError.parse("ctx load path \"file\" [as name]")
                }
                var asName: String? = nil
                if cmd.args.count >= 5, cmd.args[3].lowercased() == "as" { asName = cmd.args[4] }
                try kernel.ctxLoad(path: cmd.args[2], as: asName)
                print("OK ctx loaded from \(cmd.args[2])")

            } else if sub == "info" {
                guard cmd.args.count >= 2 else { throw NKError.parse("ctx info <ctx>") }
                print(try kernel.ctxInfo(cmd.args[1]))

            } else if sub == "drop" {
                guard cmd.args.count >= 2 else { throw NKError.parse("ctx drop <ctx>") }
                kernel.ctxDrop(cmd.args[1])
                print("OK ctx dropped \(cmd.args[1])")

            } else {
                throw NKError.parse("ctx create|run|save|load|info|drop ...")
            }

        case "worker":
            guard cmd.args.count >= 1 else { throw NKError.parse("worker spawn|stop|stopall ...") }
            let sub = cmd.args[0].lowercased()

            if sub == "spawn" {
                // worker spawn <w> ctx <c> interval_ms <n> priority low|normal|high source input <csv> sink print
                // worker spawn <w> ctx <c> interval_ms <n> priority ... source chan <in> sink chan <out>
                guard cmd.args.count >= 2 else {
                    throw NKError.parse("worker spawn <w> ctx <c> interval_ms <n> priority <p> source input|chan ... sink print|chan ...")
                }
                let w = cmd.args[1]

                guard cmd.args.count >= 4, cmd.args[2].lowercased() == "ctx" else {
                    throw NKError.parse("worker spawn ... ctx <c> ...")
                }
                let ctx = cmd.args[3]

                guard cmd.args.count >= 6, cmd.args[4].lowercased() == "interval_ms", let ms = Int(cmd.args[5]) else {
                    throw NKError.parse("worker spawn ... interval_ms <n> ...")
                }

                guard cmd.args.count >= 8, cmd.args[6].lowercased() == "priority", let pr = WorkerPriority(rawValue: cmd.args[7].lowercased()) else {
                    throw NKError.parse("worker spawn ... priority low|normal|high ...")
                }

                guard cmd.args.count >= 9, cmd.args[8].lowercased() == "source" else {
                    throw NKError.parse("worker spawn ... source ...")
                }

                var idx = 9
                let srcType = cmd.args[idx].lowercased(); idx += 1
                let source: WorkerSource
                if srcType == "input" {
                    guard idx < cmd.args.count else { throw NKError.parse("source input <csv>") }
                    source = .constant(try Script.parseCSV(cmd.args[idx])); idx += 1
                } else if srcType == "chan" {
                    guard idx < cmd.args.count else { throw NKError.parse("source chan <name>") }
                    source = .channel(cmd.args[idx]); idx += 1
                } else { throw NKError.parse("source input|chan") }

                guard idx < cmd.args.count, cmd.args[idx].lowercased() == "sink" else { throw NKError.parse("... sink ...") }
                idx += 1

                guard idx < cmd.args.count else { throw NKError.parse("sink print|chan") }
                let sinkType = cmd.args[idx].lowercased(); idx += 1
                let sink: WorkerSink
                if sinkType == "print" {
                    sink = .printOut
                } else if sinkType == "chan" {
                    guard idx < cmd.args.count else { throw NKError.parse("sink chan <name>") }
                    sink = .channel(cmd.args[idx])
                } else { throw NKError.parse("sink print|chan") }

                try kernel.workerSpawn(WorkerSpec(name: w, ctxName: ctx, intervalMs: ms, priority: pr, source: source, sink: sink))
                print("OK worker spawn \(w) ctx=\(ctx)")

            } else if sub == "stop" {
                guard cmd.args.count >= 2 else { throw NKError.parse("worker stop <name>") }
                kernel.workerStop(cmd.args[1])
                print("OK worker stopped \(cmd.args[1])")

            } else if sub == "stopall" {
                kernel.workerStopAll()
                print("OK worker stopall")

            } else {
                throw NKError.parse("worker spawn|stop|stopall ...")
            }

        default:
            throw NKError.parse("Unknown op: \(cmd.op)")
        }

        return true
    }
}

import Foundation

let kernel = Kernel()

// AUTO-IMPROVEMENT: keep interactive REPL quiet by default; enable monitor explicitly via env.
if let msRaw = ProcessInfo.processInfo.environment["NEUROK_MONITOR_MS"],
   let ms = Int(msRaw),
   ms > 0 {
    kernel.startMonitor(everyMs: ms)
}

func runFile(_ path: String) -> Bool {
    do {
        let cmds = try Script.parseFile(path)
        return try Executor.run(kernel: kernel, cmds: cmds)
    } catch {
        print(error)
        return true
    }
}

func repl() {
    print("neurok — Narrow Neural Microkernel (Swift + MPSGraph). Type 'help'.")
    while true {
        print("> ", terminator: "")
        guard let line = readLine() else { break }
        do {
            let cmds = try Script.parseOneLine(line)
            let cont = try Executor.run(kernel: kernel, cmds: cmds)
            if !cont { return }
        } catch {
            print(error)
        }
    }
}

// CLI:
// neurok help
// neurok run file.ns
// neurok runonly file.ns
let args = CommandLine.arguments
if args.count >= 2 {
    let cmd = args[1].lowercased()
    if cmd == "help" {
        if let s = try? String(contentsOfFile: "Sources/NeuroKernel/MANUAL.md", encoding: .utf8) {
            print(s)
        } else {
            print("See Sources/NeuroKernel/MANUAL.md")
        }
        exit(0)
    }
    if cmd == "run" && args.count >= 3 {
        _ = runFile(args[2])
        repl()
        exit(0)
    }
    if cmd == "runonly" && args.count >= 3 {
        _ = runFile(args[2])
        kernel.workerStopAll()
        kernel.stopMonitor()
        exit(0)
    }
}

repl()

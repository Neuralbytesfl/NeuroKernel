import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

// AUTO-IMPROVEMENT: force unbuffered output so piped runners can stream logs in real time.
setbuf(stdout, nil)
setbuf(stderr, nil)

let kernel = Kernel()

#if os(Linux)
let buildPlatform = "linux"
#else
let buildPlatform = "macOS"
#endif

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
    func isGraphBlockBegin(_ line: String) -> Bool {
        guard let cmd = try? Script.parseOneLine(line).first else { return false }
        return cmd.op == "model"
            && cmd.args.count >= 4
            && cmd.args[0].lowercased() == "create"
            && cmd.args[2].lowercased() == "graph"
            && cmd.args[3].lowercased() == "begin"
    }

    func isGraphBlockEnd(_ line: String) -> Bool {
        guard let cmd = try? Script.parseOneLine(line).first else { return false }
        return cmd.op == "graph"
            && cmd.args.count >= 1
            && cmd.args[0].lowercased() == "end"
    }

    print("neurok — Narrow Neural Microkernel (Swift). platform=\(buildPlatform). Type 'help'.")
    var pendingGraphLines: [String]? = nil

    while true {
        print(pendingGraphLines == nil ? "> " : "graph> ", terminator: "")
        guard let line = readLine() else { break }
        do {
            if var block = pendingGraphLines {
                block.append(line)
                if isGraphBlockEnd(line) {
                    pendingGraphLines = nil
                    let cmds = try Script.parseText(block.joined(separator: "\n"))
                    let cont = try Executor.run(kernel: kernel, cmds: cmds)
                    if !cont { return }
                } else {
                    pendingGraphLines = block
                }
                continue
            }

            if isGraphBlockBegin(line) {
                // AUTO-IMPROVEMENT: allow multiline graph blocks to be pasted directly in REPL.
                pendingGraphLines = [line]
                continue
            }

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

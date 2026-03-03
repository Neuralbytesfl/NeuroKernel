import Foundation

struct Cmd {
    var op: String
    var args: [String]
}

enum Script {
    static func parseFile(_ path: String) throws -> [Cmd] {
        let s = try String(contentsOfFile: path, encoding: .utf8)
        return try parseText(s)
    }

    static func parseText(_ text: String) throws -> [Cmd] {
        var out: [Cmd] = []
        var pending = ""

        func appendLine(_ rawLine: String) throws {
            let cleaned = stripComment(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                if !pending.isEmpty {
                    let toks = try tokenize(pending)
                    if let op = toks.first {
                        out.append(Cmd(op: op.lowercased(), args: Array(toks.dropFirst())))
                    }
                    pending = ""
                }
                return
            }

            var line = cleaned
            if line.hasSuffix("\\") {
                line.removeLast()
                line = line.trimmingCharacters(in: .whitespacesAndNewlines)
                pending = pending.isEmpty ? line : "\(pending) \(line)"
                return
            }

            let merged = pending.isEmpty ? line : "\(pending) \(line)"
            pending = ""

            let toks = try tokenize(merged)
            if let op = toks.first {
                out.append(Cmd(op: op.lowercased(), args: Array(toks.dropFirst())))
            }
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            try appendLine(line)
        }

        if !pending.isEmpty {
            let toks = try tokenize(pending)
            if let op = toks.first {
                out.append(Cmd(op: op.lowercased(), args: Array(toks.dropFirst())))
            }
        }

        return out
    }

    static func parseOneLine(_ line: String) throws -> [Cmd] {
        try parseText(line)
    }

    static func parseCSV(_ s: String) throws -> [Float] {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.isEmpty { throw NKError.parse("empty vector") }
        var v: [Float] = []
        v.reserveCapacity(parts.count)
        for p in parts {
            guard let f = Float(p) else { throw NKError.parse("bad float: \(p)") }
            v.append(f)
        }
        return v
    }

    private static func stripComment(_ s: String) -> String {
        var inQuotes = false
        var out = ""
        for ch in s {
            if ch == "\"" { inQuotes.toggle(); out.append(ch); continue }
            if ch == "#", !inQuotes { break }
            out.append(ch)
        }
        return out
    }

    private static func tokenize(_ s: String) throws -> [String] {
        var toks: [String] = []
        var cur = ""
        var inQuotes = false

        func flush() { if !cur.isEmpty { toks.append(cur); cur = "" } }

        for ch in s {
            if inQuotes {
                if ch == "\"" { inQuotes = false; flush() }
                else { cur.append(ch) }
            } else {
                if ch == "\"" { inQuotes = true; flush() }
                else if ch == " " || ch == "\t" || ch == "\r" { flush() }
                else { cur.append(ch) }
            }
        }
        if inQuotes { throw NKError.parse("unclosed quote") }
        flush()
        return toks
    }
}

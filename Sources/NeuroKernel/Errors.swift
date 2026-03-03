import Foundation

enum NKError: Error, CustomStringConvertible {
    case parse(String)
    case runtime(String)
    case io(String)

    var description: String {
        switch self {
        case .parse(let s): return "Parse error: \(s)"
        case .runtime(let s): return "Runtime error: \(s)"
        case .io(let s): return "IO error: \(s)"
        }
    }
}

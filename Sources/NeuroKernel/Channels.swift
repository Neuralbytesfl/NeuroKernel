import Foundation

final class Channel<T>: @unchecked Sendable {
    private let cap: Int
    private var buf: [T?]
    private var head: Int = 0
    private var tail: Int = 0
    private var count: Int = 0

    private let cond = NSCondition()

    init(capacity: Int) {
        self.cap = max(1, capacity)
        self.buf = Array(repeating: nil, count: self.cap)
    }

    func info() -> (cap: Int, count: Int) {
        cond.lock(); defer { cond.unlock() }
        return (cap, count)
    }

    func push(_ x: T, block: Bool = true) {
        cond.lock()
        defer { cond.unlock() }

        if !block, count >= cap {
            return
        }

        while count >= cap {
            cond.wait()
        }

        buf[tail] = x
        tail = (tail + 1) % cap
        count += 1
        cond.signal()
    }

    func pop(block: Bool = true) -> T? {
        cond.lock()
        defer { cond.unlock() }

        if !block, count == 0 {
            return nil
        }

        while count == 0 {
            cond.wait()
        }

        let x = buf[head]
        buf[head] = nil
        head = (head + 1) % cap
        count -= 1
        cond.signal()

        return x
    }
}

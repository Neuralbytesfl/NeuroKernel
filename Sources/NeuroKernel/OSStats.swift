import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum OSStats {
    static func rssBytes() -> UInt64 {
        #if os(Linux)
        // /proc/self/statm second field is resident set size in pages.
        guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else {
            return 0
        }
        let parts = statm.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, let residentPages = UInt64(parts[1]) else {
            return 0
        }
        let pageSize = UInt64(max(1, sysconf(Int32(_SC_PAGESIZE))))
        return residentPages * pageSize
        #else
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { iptr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), iptr, &count)
            }
        }

        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
        #endif
    }

    static func threadCount() -> Int {
        #if os(Linux)
        guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else {
            return 0
        }
        for line in status.split(separator: "\n") where line.hasPrefix("Threads:") {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if let last = parts.last, let n = Int(last) {
                return n
            }
        }
        return 0
        #else
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        let kr = task_threads(mach_task_self_, &threads, &count)
        guard kr == KERN_SUCCESS, let threads else { return 0 }

        let threadCount = Int(count)
        let byteCount = vm_size_t(threadCount * MemoryLayout<thread_t>.stride)
        _ = vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), byteCount)
        return threadCount
        #endif
    }

    static func logicalCPUCount() -> Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    static func totalMemoryBytes() -> UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }
}

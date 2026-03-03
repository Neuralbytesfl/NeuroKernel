import Foundation
import Darwin

enum OSStats {
    static func rssBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4

        let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { iptr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), iptr, &count)
            }
        }

        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    static func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        let kr = task_threads(mach_task_self_, &threads, &count)
        guard kr == KERN_SUCCESS, let threads else { return 0 }

        let threadCount = Int(count)
        let byteCount = vm_size_t(threadCount * MemoryLayout<thread_t>.stride)
        _ = vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threads), byteCount)
        return threadCount
    }

    static func logicalCPUCount() -> Int {
        max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    static func totalMemoryBytes() -> UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }
}

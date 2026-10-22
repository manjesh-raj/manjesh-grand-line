// Grand Line - native macOS app.
//
// A self-test or tour process keeps every scratch store under one folder named
// for its pid (`main.swift`'s redirect block). Pids are reused, and nothing
// removed a folder when its process ended, so a new process could start on an
// earlier one's hosts, tasks, notes and vault. Measured on a working machine:
// 3,169 such folders in one temporary directory, and a tour that seeded no
// tasks rendered another run's task activity on the Fleet log. A suite could
// pass or fail on data it never wrote, depending only on which pid it drew.
//
// A live pid belongs to exactly one process, so whatever is already in this
// process's folder is stale, and emptying it at start is always safe.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum SelfTestScratchRoot {
    /// Empty `root` before this process puts anything in it.
    static func startEmpty(_ root: URL) {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path) else { return }
        do {
            try manager.removeItem(at: root)
        } catch {
            print("SelfTestScratchRoot: could not empty \(root.path) (\(error.localizedDescription)) - "
                  + "this run may read stores an earlier process left there")
        }
    }
}

#endif

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
// R2-PROC-08 of the second full review: emptying its own folder still left
// every other one behind, by a stated choice - sweeping by dead pid alone
// could race a new process that has just been given that pid. `sweepStale`
// adds the second condition that closes the race: a folder goes only when its
// pid is dead **and** it has not changed for an hour. A process that took the
// pid over writes into the folder within its first second, which makes it
// recent, so the sweep leaves it alone.
//
// GL-27: compiled into debug builds only.
#if FM_SELFTESTS

import Foundation

enum SelfTestScratchRoot {
    /// How long a dead process's folder must sit unchanged before it goes.
    static let staleAge: TimeInterval = 60 * 60

    /// Removes every `selftest-process-<pid>` folder in `parent` whose pid is
    /// not a running process and whose modification date is older than
    /// `staleAge`. Anything else in `parent` is left alone, as is this
    /// process's own folder. Returns what it removed.
    @discardableResult
    static func sweepStale(in parent: URL,
                           now: Date = Date(),
                           isAlive: (Int32) -> Bool = processIsAlive) -> [URL] {
        let manager = FileManager.default
        guard let children = try? manager.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]) else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        var removed: [URL] = []
        for child in children {
            let name = child.lastPathComponent
            guard name.hasPrefix(ProcessMode.scratchFolderPrefix),
                  let pid = Int32(name.dropFirst(ProcessMode.scratchFolderPrefix.count)), pid > 0, pid != own,
                  let values = try? child.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  now.timeIntervalSince(modified) > staleAge,
                  !isAlive(pid)
            else { continue }
            if (try? manager.removeItem(at: child)) != nil { removed.append(child) }
        }
        return removed
    }

    /// `kill(pid, 0)`: success, or a refusal because the process belongs to
    /// someone else, both mean the pid is in use.
    static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

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

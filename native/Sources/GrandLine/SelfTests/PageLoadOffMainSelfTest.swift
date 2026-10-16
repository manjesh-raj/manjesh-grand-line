// Grand Line - native macOS app.
//
// P11 of the Grand Line vs Automic Vault polish report: four pages read
// their whole store from disk on the main thread in `viewWillAppear`, so the
// page change waited on the read - Notebook (up to 2000 `.md` files), Commands
// (its YAML library), Sticky Board and Reading List.
//
// **What is asserted, and why it is not a timing.** "Fast enough" is a
// number that depends on the runner, and this repository's rule is to assert
// state, never time. What changed is *where* the read happens, so each case
// mounts the real page over a realistically sized scratch store and asserts,
// through the store's own `debugOnRead` hook, that a revisit's read ran off
// the main thread. Then that the read really landed (a change made behind the
// store shows up), and that an edit made while a read is in flight is not
// overwritten by it - GL-01's "a read must never quietly undo a write".
// `HelmBackgroundReload`'s ordering is checked on its own.
//
// The main-thread milliseconds of every revisit are printed as evidence, not
// asserted.
//
// Run with:
//   swift build && FM_RUN_PAGE_LOAD_OFF_MAIN_TESTS=1 .build/debug/GrandLine; echo $?
//
// Window-backed: real controllers in a real window, with their real
// `viewWillAppear`. Listed in `run-all-tests.sh`'s `NEEDS_SESSION`.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import AppKit
import Yaml

enum PageLoadOffMainSelfTest {

    static func run() -> Bool {
        NSApplication.shared.setActivationPolicy(.accessory)
        var ok = true
        checkTheReloadOrdering(&ok)
        checkNotebook(&ok)
        checkCommands(&ok)
        checkStickyBoard(&ok)
        checkReadingList(&ok)
        checkALongTaskListParsesOffMain(&ok)
        checkNotebookKeepsTheMinimumWindow(&ok)
        print(ok ? "PageLoadOffMainSelfTest: all checks passed" : "PageLoadOffMainSelfTest: FAILED")
        return ok
    }

    // MARK: The shared reload

    private static func checkTheReloadOrdering(_ ok: inout Bool) {
        print("\n-- P11: a newer reload supersedes an older one; a write drops a read in flight --")
        let reload = HelmBackgroundReload<Int>(label: "selftest")
        var applied: [Int] = []
        reload.run(read: { 1 }) { applied.append($0) }
        reload.run(read: { 2 }) { applied.append($0) }
        reload.debugDrainQueue()
        pump { !applied.isEmpty }
        pump(timeout: 0.2) { false }
        check(applied == [2], "two reloads applied \(applied) - only the newer may land", &ok)

        applied.removeAll()
        reload.run(read: { 3 }) { applied.append($0) }
        reload.invalidate()
        reload.debugDrainQueue()
        pump(timeout: 0.3) { false }
        check(applied.isEmpty, "a read invalidated by a write still landed (\(applied))", &ok)
        if ok { print("  OK   superseded and invalidated reads are dropped") }
    }

    // MARK: Notebook

    private static func checkNotebook(_ ok: inout Bool) {
        print("\n-- P11: Notebook --")
        let root = scratch("notebook")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotebookStore(root: root)
        // 1500 pages across 15 folders - the shape a notebook used for a year
        // has, and well inside the 2000 cap.
        for folder in 0..<15 {
            for n in 0..<100 {
                let body = (0..<20).map { "Line \($0) of note \(n) in area \(folder), see [[Note \((n + 1) % 100)]]." }
                    .joined(separator: "\n")
                _ = store.createPage(title: "Note \(n)", folder: "Area \(folder)", content: "# Note \(n)\n\n" + body)
            }
        }
        let controller = NotebookController(store: store)
        let window = mount(controller)
        defer { window.orderOut(nil) }
        controller.debugBackgroundReload.debugDrainQueue()
        pump(timeout: 0.3) { false }

        var reads: [Bool] = []
        NotebookStore.debugOnRead = { reads.append($0) }
        defer { NotebookStore.debugOnRead = nil }

        // A page that arrives behind the store's back, as a git pull would.
        let fresh = root.appendingPathComponent("Area 0").appendingPathComponent("Arrived from a pull.md")
        try? "# Arrived from a pull\n".write(to: fresh, atomically: true, encoding: .utf8)
        let ms = revisit(controller)
        check(!reads.contains(true), "a revisit read the notebook folder on the main thread", &ok)
        controller.debugBackgroundReload.debugDrainQueue()
        pump { controller.debugPages.contains { $0.title == "Arrived from a pull" } }
        check(reads.contains(false), "a revisit never read the folder at all", &ok)
        check(controller.debugPages.contains { $0.title == "Arrived from a pull" },
              "the page that arrived on disk never reached the notebook", &ok)

        // An edit while a read is in flight: the read must not undo it.
        controller.debugReloadInBackground()
        controller.debugNewPage()
        let created = controller.debugCurrentPageID
        controller.debugBackgroundReload.debugDrainQueue()
        pump(timeout: 0.3) { false }
        check(created != nil && controller.debugPages.contains { $0.id == created },
              "a page created while a read was in flight was undone by that read", &ok)
        printTime("Notebook (1500 pages)", ms)
    }

    // MARK: Commands

    private static func checkCommands(_ ok: inout Bool) {
        print("\n-- P11: Commands --")
        let root = scratch("commands")
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("FM_COMMAND_LIBRARY_DIR", root.path, 1)
        defer { unsetenv("FM_COMMAND_LIBRARY_DIR") }
        let store = CommandLibraryStore()
        _ = store.commands   // the first load seeds the starter library
        let copies = multiplyLibrary(root, times: 3)
        let controller = CommandLibraryController(store: store)
        let window = mount(controller)
        defer { window.orderOut(nil) }
        store.debugBackgroundReload.debugDrainQueue()
        pump(timeout: 0.3) { false }

        var reads: [Bool] = []
        CommandLibraryStore.debugOnRead = { reads.append($0) }
        defer { CommandLibraryStore.debugOnRead = nil }
        let before = store.commands.count
        guard let template = copies.first, let text = try? String(contentsOf: template, encoding: .utf8) else {
            return fail("the command library fixture has no file to copy", &ok)
        }
        let stem = template.deletingPathExtension().lastPathComponent
        try? text.replacingOccurrences(of: "id: \(stem)", with: "id: arrived-from-a-pull")
            .write(to: template.deletingLastPathComponent().appendingPathComponent("arrived-from-a-pull.yaml"),
                   atomically: true, encoding: .utf8)
        let ms = revisit(controller)
        check(!reads.contains(true), "a revisit scanned the command library on the main thread", &ok)
        store.debugBackgroundReload.debugDrainQueue()
        pump { store.commands.count > before }
        check(reads.contains(false), "a revisit never scanned the library at all", &ok)
        // A command's id is its category and file name (`terraform/...`).
        check(store.commands.contains { $0.id.hasSuffix("/arrived-from-a-pull") },
              "the command that arrived on disk never reached the page", &ok)

        // An edit while a read is in flight.
        guard let target = store.commands.first(where: { !store.isFavorite($0.id) })?.id else {
            return fail("no unfavourited command to toggle", &ok)
        }
        store.reloadAllInBackground {}
        store.toggleFavorite(target)
        store.debugBackgroundReload.debugDrainQueue()
        pump(timeout: 0.3) { false }
        check(store.isFavorite(target), "a favourite set while a read was in flight was undone by that read", &ok)
        printTime("Commands (\(store.commands.count) commands)", ms)
    }

    // MARK: Sticky Board

    private static func checkStickyBoard(_ ok: inout Bool) {
        print("\n-- P11: Sticky Board --")
        let root = scratch("sticky")
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("FM_STICKY_BOARD_DIR", root.path, 1)
        defer { unsetenv("FM_STICKY_BOARD_DIR") }
        let controller = StickyBoardController()
        let store = controller.store
        for n in 0..<150 {
            _ = store.addNote(text: "Sticky \(n): remember the thing about the staging cluster",
                              color: .yellow, x: Double(n % 10) * 220, y: Double(n / 10) * 200, rotationDegrees: 0)
        }
        store.flushPendingWrite()
        let window = mount(controller)
        defer { window.orderOut(nil) }
        store.debugBackgroundReload.debugDrainQueue()
        pump(timeout: 0.3) { false }

        // A note added by another writer of the same file - another machine's
        // sync, as far as this store can tell. Built before the hook: its own
        // `init` reads the file, which is not the revisit being measured.
        let other = StickyBoardStore()
        _ = other.addNote(text: "Arrived from a pull", color: .pink, x: 10, y: 10, rotationDegrees: 0)
        other.flushPendingWrite()
        var reads: [Bool] = []
        StickyBoardStore.debugOnRead = { reads.append($0) }
        defer { StickyBoardStore.debugOnRead = nil }
        let ms = revisit(controller)
        check(!reads.contains(true), "a revisit read the notes file on the main thread", &ok)
        store.debugBackgroundReload.debugDrainQueue()
        pump { store.notes.contains { $0.text == "Arrived from a pull" } }
        check(reads.contains(false), "a revisit never read the notes file at all", &ok)
        check(store.notes.contains { $0.text == "Arrived from a pull" }, "the note that arrived on disk never reached the board", &ok)

        // An edit while a read is in flight.
        store.reloadAllInBackground {}
        _ = store.addNote(text: "Typed while a read was in flight", color: .green, x: 0, y: 0, rotationDegrees: 0)
        store.debugBackgroundReload.debugDrainQueue()
        pump(timeout: 0.3) { false }
        check(store.notes.contains { $0.text == "Typed while a read was in flight" },
              "a note added while a read was in flight was undone by that read", &ok)
        store.flushPendingWrite()
        printTime("Sticky Board (151 notes)", ms)
    }

    // MARK: Reading List

    private static func checkReadingList(_ ok: inout Bool) {
        print("\n-- P11: Reading List --")
        let root = scratch("reading")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ReadingListStore(root: root)
        for n in 0..<400 {
            _ = store.add("https://example.com/articles/\(n)", tags: n % 3 == 0 ? ["sre"] : [])
        }
        store.flush()
        let controller = ReadingListController(store: store, fetcher: NoMetadataFetcher())
        let window = mount(controller)
        defer { window.orderOut(nil) }
        store.debugBackgroundReload.debugDrainQueue()
        pump(timeout: 0.3) { false }

        // Built before the hook, for the same reason as the Sticky Board's.
        let other = ReadingListStore(root: root)
        _ = other.add("https://example.com/arrived-from-a-pull")
        other.flush()
        var reads: [Bool] = []
        ReadingListStore.debugOnRead = { reads.append($0) }
        defer { ReadingListStore.debugOnRead = nil }
        let ms = revisit(controller)
        check(!reads.contains(true), "a revisit read the links file on the main thread", &ok)
        store.debugBackgroundReload.debugDrainQueue()
        pump { store.links.contains { $0.url.contains("arrived-from-a-pull") } }
        check(reads.contains(false), "a revisit never read the links file at all", &ok)
        check(store.links.contains { $0.url.contains("arrived-from-a-pull") },
              "the link that arrived on disk never reached the list", &ok)

        // A revisit that finds nothing changed keeps the cards it has.
        let rebuildsBefore = controller.debugGridRebuildCount
        _ = revisit(controller)
        store.debugBackgroundReload.debugDrainQueue()
        pump(timeout: 0.3) { false }
        check(controller.debugGridRebuildCount == rebuildsBefore,
              "an unchanged revisit rebuilt the card grid \(controller.debugGridRebuildCount - rebuildsBefore) time(s)", &ok)

        // An edit while a read is in flight.
        store.reloadAllInBackground {}
        _ = store.add("https://example.com/saved-while-a-read-was-in-flight")
        store.debugBackgroundReload.debugDrainQueue()
        pump(timeout: 0.3) { false }
        check(store.links.contains { $0.url.contains("saved-while-a-read-was-in-flight") },
              "a link saved while a read was in flight was undone by that read", &ok)
        printTime("Reading List (401 links)", ms)
    }

    // MARK: The Tasks page's off-main parse

    /// Found while building the above: the vendored YAML parser recurses once
    /// per list element, a GCD worker thread's stack is 512 KB, and the Tasks
    /// page's `ShiftStore.reloadAllAsync` parsed on a GCD queue. A long active
    /// task list therefore crashed the app with `EXC_BAD_ACCESS` on a stack
    /// address the moment the Tasks page was visited. Both now parse on
    /// `HelmParseThread`. A crash fails this suite by its exit code, which is
    /// the regression this case exists to catch.
    private static func checkALongTaskListParsesOffMain(_ ok: inout Bool) {
        print("\n-- P11: a long task list parses off the main thread without overflowing the stack --")
        let root = scratch("shift")
        defer { try? FileManager.default.removeItem(at: root) }
        let tasks: [Yaml] = (0..<1500).map { n in
            var task = ShiftTask.fresh()
            task.title = "Task \(n): rotate the key for service \(n)"
            task.tags = ["ops", "q\(n % 4)"]
            task.dueDate = "2026-10-\(String(format: "%02d", 1 + n % 28))"
            task.notes = "Line one\nLine two of task \(n)"
            return ShiftYaml.toYaml(task)
        }
        try? ShiftYaml.writeList(path: root.appendingPathComponent("tasks/active.yaml").path, key: "tasks", items: tasks)
        setenv("FM_SHIFT_DIR", root.path, 1)
        defer { unsetenv("FM_SHIFT_DIR") }
        let store = ShiftStore()
        var landed = false
        store.reloadAllAsync { landed = true }
        pump(timeout: 30) { landed }
        check(landed, "the off-main parse of 1500 tasks never landed", &ok)
        check(store.activeTasks.count == 1500, "the off-main parse loaded \(store.activeTasks.count) of 1500 tasks", &ok)
        if ok { print("  OK   1500 tasks parsed on HelmParseThread and applied") }
    }

    // MARK: Notebook at the minimum window

    /// Found while rendering this work at three sizes: a Notebook visit at
    /// the 960pt minimum grew the whole window to 1265pt - on `main` on the
    /// first visit, and with the background read on every revisit too, since
    /// its apply rebuilt the page after it was on screen. Two `HelmEmptyState`
    /// bodies held their one-line width at compression resistance 750, above
    /// the window's 500 (gotcha (13)): the editor overlay's because its wrap
    /// width was still 0 on the first layout pass, the preview's because its
    /// copy set its width instead of its container (gotcha (22)).
    private static func checkNotebookKeepsTheMinimumWindow(_ ok: inout Bool) {
        print("\n-- P11: a Notebook visit at the 960pt minimum never widens the window --")
        let (window, shell) = ReviewTourLab.makeOffScreenShell()
        defer { window.orderOut(nil) }
        var frame = window.frame
        frame.size = NSSize(width: 960, height: 620)
        window.setFrame(frame, display: false)
        window.orderFront(nil)
        shell.show(.homeCanvas)
        shell.view.layoutSubtreeIfNeeded()
        for visit in ["first visit", "revisit"] {
            shell.show(.notebook)
            shell.view.layoutSubtreeIfNeeded()
            // Let the background read land and the page settle.
            pump(timeout: 1.0) { false }
            shell.view.layoutSubtreeIfNeeded()
            check(window.frame.width <= 960.5,
                  "Notebook's \(visit) at the 960pt minimum widened the window to \(window.frame.width)pt", &ok)
            shell.show(.homeCanvas)
            shell.view.layoutSubtreeIfNeeded()
        }
        if ok { print("  OK   the window stayed 960pt across a first visit and a revisit") }
    }

    // MARK: Helpers

    private static func mount(_ controller: NSViewController) -> NSWindow {
        let window = OffScreenProbe.window(width: 1300, height: 900, styleMask: [.titled, .resizable])
        window.contentView = controller.view
        window.orderFront(nil)
        controller.viewWillAppear()
        return window
    }

    /// One revisit, timed on the main thread.
    private static func revisit(_ controller: NSViewController) -> Double {
        controller.viewWillDisappear()
        let start = CFAbsoluteTimeGetCurrent()
        controller.viewWillAppear()
        return (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    private static func printTime(_ name: String, _ ms: Double) {
        print(String(format: "  TIME %@: a revisit's viewWillAppear held the main thread %.1f ms (evidence, not asserted)", name, ms))
    }

    /// Three copies of every starter command, in its real on-disk format.
    private static func multiplyLibrary(_ root: URL, times: Int) -> [URL] {
        var written: [URL] = []
        let fm = FileManager.default
        for category in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where category.hasDirectoryPath {
            for file in (try? fm.contentsOfDirectory(at: category, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "yaml" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let stem = file.deletingPathExtension().lastPathComponent
                for copy in 1...times {
                    let url = category.appendingPathComponent("\(stem)-copy\(copy).yaml")
                    try? text.replacingOccurrences(of: "id: \(stem)", with: "id: \(stem)-copy\(copy)")
                        .write(to: url, atomically: true, encoding: .utf8)
                    written.append(url)
                }
            }
        }
        return written
    }

    private static func scratch(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("page-load-off-main-\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Pump the run loop until `landed()` holds, bounded.
    private static func pump(timeout: TimeInterval = 5, until landed: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !landed(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// No network in a suite: every metadata request answers "nothing".
    private final class NoMetadataFetcher: ReadingListMetadataFetching {
        func fetch(url: String, completion: @escaping (Result<ReadingListMetadata, ReadingListMetadataError>) -> Void) {
            completion(.failure(ReadingListMetadataError(message: "no network in a suite")))
        }
    }
}

#endif

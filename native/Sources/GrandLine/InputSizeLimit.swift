// Grand Line - native macOS app.
//
// R2-SEC-12: the most text a paste, a drop or a chosen file may carry into a
// parser that runs on the main thread.
//
// The vault's CSV import and the Log Analyzer's pasted, copied or dropped
// input had no cap, and the Log Analyzer runs fifteen redaction regexes over
// whatever it is given. A large enough file was a self-inflicted beachball.
// The cap is the backup bundle's own per-file limit
// (`BackupArchiveLimits.maxBytesPerFile`, 8 MB), so the app has one answer to
// "how big is too big for one file", and it sits far above any real password
// manager export or log capture worth reading by eye.

import Foundation

enum InputSizeLimit {
    static var maxBytes: Int {
        #if FM_SELFTESTS
        if let override = maxBytesOverrideForTests { return override }
        #endif
        return BackupArchiveLimits.maxBytesPerFile
    }

    #if FM_SELFTESTS
    /// A smaller cap for a suite, so a check that the cap is applied fails in
    /// a second with the cap reverted, instead of beachballing for minutes
    /// over a real 8 MB input. Every user restores `nil`.
    static var maxBytesOverrideForTests: Int?
    #endif

    /// The sentence to show when `what` is over the limit, or `nil`.
    static func refusal(byteCount: Int, what: String) -> String? {
        guard byteCount > maxBytes else { return nil }
        let megabytes = maxBytes / (1024 * 1024)
        return "\(what) is over \(megabytes) MB, so it was not read"
    }

    static func refusal(forText text: String, what: String) -> String? {
        refusal(byteCount: text.utf8.count, what: what)
    }

    /// Asked before the file is read, from its size on disk, so a huge file
    /// is never loaded into memory just to be refused.
    static func refusal(forFileAt url: URL, what: String) -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return refusal(byteCount: size, what: what)
    }
}

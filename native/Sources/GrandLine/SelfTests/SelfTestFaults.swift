// Grand Line - native macOS app.
//
// REL-21 / REL-24 of the 2026-10 end-to-end review: the one place a suite
// makes a scratch file unreadable, or a scratch directory refuse a delete.
//
// # Why `chmod 000` alone is not enough here
//
// Every sensitive store reads through `StoreLoadFailure.read(_:sensitive:)`,
// which first tightens the file to 0600 (M3's read half). The owner may always
// change a file's mode, so that chmod quietly turns a 0000 file back into a
// readable one and the store never sees a read error - a fault test built on
// `chmod 000` alone would pass with the fix reverted. An extended ACL entry
// that denies `read` to this user survives the chmod, because a mode change
// does not touch the ACL. Both are applied, so the file is unreadable whether
// or not the code under test chmods it first.
//
// # Rules
//
//  - **Scratch paths only.** Every caller passes a path under a directory the
//    suite itself created in `NSTemporaryDirectory()`. Nothing here may ever
//    point at a captain's store.
//  - **Prove the fault took.** `makeUnreadable` reads the file back and
//    returns `false` when it can still read it (a root process, a file system
//    without ACLs). A caller fails the case loudly on `false` rather than
//    running assertions that could not fail.
//  - **Undo it before cleanup.** `restoreReadable` clears the ACL and the
//    mode so the suite can read the original bytes back and the scratch
//    directory can be removed.
//
// Do not remove the guard below: `Phase3PolishSelfTest` asserts that every
// file in this directory carries it.
#if FM_SELFTESTS

import Darwin
import Foundation

enum SelfTestFaults {

    /// Make `url` unreadable by this process: mode 0000 plus an ACL entry
    /// denying `read` to this user. Returns whether a read now fails.
    @discardableResult
    static func makeUnreadable(_ url: URL) -> Bool {
        _ = denyRead(url.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        return (try? Data(contentsOf: url)) == nil
    }

    /// Undo `makeUnreadable`.
    static func restoreReadable(_ url: URL, mode: Int = 0o600) {
        if let empty = acl_init(0) {
            acl_set_file(url.path, ACL_TYPE_EXTENDED, empty)
            acl_free(UnsafeMutableRawPointer(empty))
        }
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    /// Read `url` back after `restoreReadable`, for the "the bytes are still
    /// the original ones" assertion.
    static func bytes(of url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    /// Bytes that are not valid UTF-8 (a Latin-1 `é`) inside otherwise valid
    /// YAML - REL-21's second fault. A reader that decodes the file as UTF-8
    /// fails on it while every byte is still real data.
    static func latin1YAML(key: String, id: String) -> Data {
        var data = Data("\"\(key)\":\n  - \"id\": \"\(id)\"\n    \"title\": \"caf".utf8)
        data.append(0xE9)
        data.append(contentsOf: Array("\"\n".utf8))
        return data
    }

    // MARK: - ACL

    private static func denyRead(_ path: String) -> Bool {
        guard let uuid = currentUserUUID() else { return false }
        var acl: acl_t? = acl_init(1)
        defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
        var entry: acl_entry_t?
        guard acl_create_entry(&acl, &entry) == 0,
              acl_set_tag_type(entry, ACL_EXTENDED_DENY) == 0 else { return false }
        var qualifier = uuid
        guard withUnsafeMutablePointer(to: &qualifier, { acl_set_qualifier(entry, $0) }) == 0 else {
            return false
        }
        var permset: acl_permset_t?
        guard acl_get_permset(entry, &permset) == 0,
              acl_add_perm(permset, ACL_READ_DATA) == 0,
              acl_set_permset(entry, permset) == 0 else { return false }
        return acl_set_file(path, ACL_TYPE_EXTENDED, acl) == 0
    }

    /// `mbr_uid_to_uuid` lives in libSystem but its header (`membership.h`)
    /// is not in the Darwin module Swift imports, so it is looked up by name.
    private static func currentUserUUID() -> uuid_t? {
        typealias Lookup = @convention(c) (uid_t, UnsafeMutableRawPointer) -> Int32
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "mbr_uid_to_uuid") else {
            return nil
        }
        let lookup = unsafeBitCast(symbol, to: Lookup.self)
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        guard withUnsafeMutablePointer(to: &uuid, { lookup(getuid(), UnsafeMutableRawPointer($0)) }) == 0 else {
            return nil
        }
        return uuid
    }
}

#endif

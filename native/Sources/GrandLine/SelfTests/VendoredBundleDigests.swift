// Grand Line - native macOS app.
//
// R2-SEC-12: the two vendored web bundles (`Vendor/Excalidraw/web`,
// `Vendor/Monaco/web`) are reproducible from committed lockfiles, but nothing
// rebuilds them in CI, so a hand edit to the committed JavaScript would ship.
// Their build scripts now record a SHA-256 of every shipped file in
// `BUILD-INFO.txt`; this recomputes each one and reports every difference,
// plus any file in the bundle the list does not name.
//
// Shared by `WhiteboardSelfTest` and `CodePreviewSelfTest`.
//
// GL-27: compiled into debug builds only. Do not remove this guard -
// `Phase3PolishSelfTest` asserts every file in this directory carries it.
#if FM_SELFTESTS

import CryptoKit
import Foundation

enum VendoredBundleDigests {

    /// Every problem with `directory`'s recorded digests, empty when they all
    /// match. A missing or empty digest list is itself a problem, so this can
    /// never pass by finding nothing to check.
    static func problems(in directory: URL) -> [String] {
        let info = directory.appendingPathComponent("BUILD-INFO.txt")
        guard let text = try? String(contentsOf: info, encoding: .utf8) else {
            return ["BUILD-INFO.txt is missing or unreadable"]
        }
        var recorded: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("sha256 ") {
            let parts = line.dropFirst("sha256 ".count).components(separatedBy: "  ")
            guard parts.count == 2 else { return ["BUILD-INFO.txt has a malformed digest line: \(line)"] }
            recorded[parts[1]] = parts[0]
        }
        guard !recorded.isEmpty else {
            return ["BUILD-INFO.txt records no digests - rebuild with the bundle's Scripts/build-*-web.sh"]
        }

        var problems: [String] = []
        for (path, expected) in recorded.sorted(by: { $0.key < $1.key }) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(path)) else {
                problems.append("\(path) is listed but missing")
                continue
            }
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if actual != expected { problems.append("\(path) does not match its recorded SHA-256 - edited by hand?") }
        }
        let shipped = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { String($0.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count + 1)) }
            .filter { $0 != "BUILD-INFO.txt" } ?? []
        for path in shipped where recorded[path] == nil {
            problems.append("\(path) ships in the bundle but has no recorded SHA-256")
        }
        return problems
    }
}

#endif

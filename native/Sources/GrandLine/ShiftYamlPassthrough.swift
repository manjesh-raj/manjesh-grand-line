// Grand Line - native macOS app.
//
// GL-01's second half for the Shift YAML stores: a record this build reads
// perfectly well, but which carries one extra key from a *newer* build, must
// not lose that key the next time this build writes the file.
//
// B23. GL-01's usual shape is a read that fails; this is a read that succeeds
// and a write that loses something, with no symptom at all. `ShiftStore`
// rewrites each file whole from its decoded structs, and a struct has nowhere
// to put a key it does not know - so the newer machine silently finds its own
// field gone every time the older one touches the file, across a git sync
// whose entire purpose is two machines on two builds.
//
// `StickyBoardStore`'s `knownKeys` + `passthrough` pair is the worked example
// this follows; the difference is only that Shift has three record types in
// three files, so the mechanism is a reusable value rather than three copies.
//
// **Not the same mechanism as preserving a record that will not decode at
// all** (`StickyBoardStore.unreadableRecords`). That one keeps whole records;
// this one keeps stray keys on records that decode fine, and neither covers
// the other.

import Foundation
import Yaml

/// Per-record keys a build did not write, kept verbatim and put straight back.
struct ShiftYamlPassthrough {

    /// record id -> the pairs this build does not write, in file order.
    private var extras: [String: [(key: Yaml, value: Yaml)]] = [:]

    /// How many records carry at least one unknown key. Zero for a file only
    /// ever written by this build; a suite asserts it, and it is the cheap
    /// way to notice that adding a field to a model without adding its key to
    /// `knownKeys` has made this build treat its own output as foreign.
    var recordsWithExtras: Int { extras.count }

    init() {}

    /// Rebuilds the map from what was just read off disk. Called on every
    /// reload, so a record deleted elsewhere drops out on its own.
    ///
    /// `idKey` is the record's identity field; a record without one cannot be
    /// matched back up at write time and is skipped (the store drops it for
    /// the same reason).
    mutating func capture(_ items: [Yaml], knownKeys: Set<String>, idKey: String = "id") {
        var found: [String: [(key: Yaml, value: Yaml)]] = [:]
        for item in items {
            guard let dict = item.dictionary else { continue }
            // `Yaml.==` deliberately ignores quote style, so one lookup
            // matches an id key however the file spelled it.
            guard case .string(let id, _)? = dict[ShiftYamlBridge.key(idKey)],
                  !id.isEmpty else { continue }
            let unknown = dict.pairs.filter { pair in
                // A non-string key is legal YAML and is never something this
                // app writes, so it is unknown by definition.
                guard case .string(let name, _) = pair.key else { return true }
                return !knownKeys.contains(name)
            }
            guard !unknown.isEmpty else { continue }
            found[id] = unknown
        }
        extras = found
    }

    /// Appends whatever was kept for `id` to a freshly serialised record.
    ///
    /// Appended **last**, so this build's own keys keep their established
    /// order and the resulting `git diff` stays readable.
    func merged(_ serialised: Yaml, id: String) -> Yaml {
        guard let unknown = extras[id], !unknown.isEmpty,
              var dict = serialised.dictionary else { return serialised }
        for pair in unknown { dict[pair.key] = pair.value }
        return .dictionary(dict)
    }
}

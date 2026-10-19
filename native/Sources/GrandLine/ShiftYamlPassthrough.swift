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

    /// Adds one record's unknown keys, replacing any already kept for its
    /// id - for a record that moves into this file from another one (a task
    /// reopened out of a completed-month file), so the move does not drop
    /// what the other file carried.
    mutating func absorb(_ item: Yaml, knownKeys: Set<String>, idKey: String = "id") {
        var one = ShiftYamlPassthrough()
        one.capture([item], knownKeys: knownKeys, idKey: idKey)
        for (id, pairs) in one.extras { extras[id] = pairs }
    }

    /// Overlays `other`'s kept keys on this one's, `other` winning a key both
    /// carry for the same record. The conflict-resolution rewrite reads two
    /// sides of one file and needs every unknown key either side carried.
    func overlaid(with other: ShiftYamlPassthrough) -> ShiftYamlPassthrough {
        var out = self
        for (id, pairs) in other.extras {
            var merged = out.extras[id] ?? []
            for pair in pairs {
                merged.removeAll { $0.key == pair.key }
                merged.append(pair)
            }
            out.extras[id] = merged
        }
        return out
    }

    /// The identity of a raw record, or `nil` for one without a usable id -
    /// shared by every rewrite that edits a file one record at a time.
    static func recordID(_ item: Yaml, idKey: String = "id") -> String? {
        guard case .string(let id, _)? = item.dictionary?[ShiftYamlBridge.key(idKey)], !id.isEmpty else {
            return nil
        }
        return id
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

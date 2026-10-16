# Vendored YamlSwift

Source: [behrang/YamlSwift](https://github.com/behrang/YamlSwift), pinned to upstream `master`
commit `063286d0a66200b6ae0687c06914b19fe7c8dc83`. MIT licensed - see `LICENSE`.

## Why vendored, not a remote SPM dependency

This app deliberately has zero remote SPM dependencies (see `Vendor/SwiftTerm/README.md` for the
original reasoning) - `Package.resolved` doesn't exist. The Tools page's YAML validate/beautify
tool (cockpit-tools-page-core) needs a real YAML parser, not a hand-rolled one - a hand-rolled
subset was fine for the captain's original HTML mockup, but the whole point of this tool is that
the captain pastes real Kubernetes manifests into it, which use enough of the YAML spec (anchors,
multi-document `---` separators, block/flow scalars, folded strings) that a partial parser would
silently misparse or reject real input. YamlSwift is pure Swift (no C library, unlike Yams'
libyaml-backed alternative), small (~1,500 lines across 6 files), and MIT licensed - vendored here
verbatim, unmodified, the same way `Vendor/SwiftTerm` is vendored.

## What's used, and a real limitation worth knowing

`Yaml.load`/`Yaml.loadMultiple` (`Yaml.swift`) are what `ToolsController`'s YAML tool calls for
Validate and as the parse step of Beautify - `loadMultiple` is what makes multi-resource Kubernetes
manifests (documents separated by `---`) work correctly, not just a single top-level object.

There is no `save`/`dump` API upstream for producing YAML text back out of a parsed `Yaml` value -
`YamlBeautify.swift` (`native/Sources/GrandLine/`) has its own small serializer for that,
which is serialization of an already-correctly-parsed tree, not YAML parsing, so it doesn't
reintroduce the "hand-rolled parser" problem this vendoring was meant to avoid.

## Local patch: `YamlOrderedMap` (fm/cockpit-tools-yaml-order-perf-fix)

Upstream `Yaml.dictionary` wraps a plain Swift `[Yaml: Yaml]`, which has no defined iteration
order. This used to be treated as a deliberate, documented trade-off ("beautify sorts keys
alphabetically for deterministic output, like `JSONSerialization.WritingOptions.sortedKeys` does
for the JSON tool") - but a real captain manifest (~35 Kubernetes Deployments, each with 10 keys
in a specific, meaningful order) showed this is a real data-fidelity bug, not a style choice: YAML
mapping key order carries meaning to a human reader, and Beautify was silently destroying it at
every nesting level, including the top-level document keys.

The fix is `YAMLOrderedMap.swift`, a new file (not present upstream) defining `YamlOrderedMap`: an
insertion-order-preserving map (a real dictionary for O(1) lookup, plus a parallel `keys` array)
that replaces `[Yaml: Yaml]` as `Yaml.dictionary`'s associated value everywhere - the enum case
itself (`Yaml.swift`), its subscript/`ExpressibleByDictionaryLiteral`/`dictionary` property, and
every block/flow-map parsing accumulator in `YAMLParser.swift` (`parseBlockMap`, `parseFlowMap`,
`parseQuestionMarkkeyValue`, `parseStringKeyValue`, `putToMap`, `checkKeyUniqueness`). The parser
already builds each mapping key-by-key in source order during recursive descent - the bug was
purely that the *accumulator type* it folded those keys into had no memory of that order once
folded. `YamlBeautify.swift` now walks `dict.pairs` (insertion order) instead of sorting `dict.keys`.

## Local patch: linear-time tokenizer and parser (Grand Line polish report, P11)

Upstream's tokenizer and parser are both O(n^2) in the size of a document, and this app reads its
stores through them on every visit to a page. Measured in Grand Line, a 400-link reading list took
about 7s to parse and a 150-note sticky board about 1.2s, on the main thread. After this patch the
same files parse in about 0.28s and 0.11s, in a debug build.

There were three separate costs, found one after another with `sample`:

1. **The tokenizer copied the remaining text for every token** (`substring(from:)`), bridging a
   fresh `NSString` each time. `Yaml.tokenize` (`YAMLTokenizer.swift`) now walks one `NSString`
   with a moving offset and matches within the range from the offset to the end.
2. **Every pattern scanned the whole remaining text.** `rangeOfFirstMatch` is ICU's `find`, which
   searches forward for a match starting anywhere in the range, so a `^`-anchored pattern that
   did not match at the offset still cost a scan of the rest of the document. Matches now pass
   `.anchored`. This was the bigger half of the tokenizer's cost.
3. **The parser copied the remaining token array for every token.** `Context.advance`
   (`YAMLParser.swift`) did `tokens.remove(at: 0)` on a copy. `Context` now shares one token array
   and moves a `position` along it; `tokens` is the same remaining run, as a slice.

**It is the same parse.** `NSRegularExpression` treats a search range's bounds as the string's
own bounds by default (anchoring bounds on, transparent bounds off), so `^` matches at the offset,
`$` at the end, and no lookaround sees before the offset - exactly what matching against the
copied remainder did. `.anchored` changes nothing for a pattern whose every top-level alternative
begins with `^`, which is true of every pattern the tokenizer uses; **an added pattern must keep
that true.** Verified when the patch was written by running the old and new tokenizers side by
side over 97 documents (every YAML file in this repository, every store shape the app writes, and
hand-written edge cases: literal and folded blocks, flow collections, comments, CRLF, anchors,
multi-document, a malformed document): identical token lists. And by dumping `Yaml.loadMultiple`
and `Yaml.load(preserveComments: true)` for 96 documents before and after the parser change:
identical output.

`FM_RUN_VENDORED_PATCHES_TESTS` asserts all three YamlSwift patches are present, by code markers
with comments stripped, because a re-sync that drops one of these leaves every behavioural suite
green - only the cost changes.

## Re-syncing

If YamlSwift is ever updated, re-fetch `Sources/Yaml/*.swift` (except the new, not-upstream
`YAMLOrderedMap.swift`) and `LICENSE` from the pinned commit (or a newer one) into this directory,
then re-apply the `YamlOrderedMap` patch and the linear-time patch above - neither is upstream and
neither will survive a raw re-fetch, the same caveat SwiftTerm's vendoring documents for its own
patches. Then run `FM_RUN_VENDORED_PATCHES_TESTS`.

# Vendored Excalidraw (the Whiteboard destination's canvas)

Source: [`@excalidraw/excalidraw`](https://github.com/excalidraw/excalidraw) **0.18.1** from npm,
bundled with React 19.1.0 / React DOM 19.1.0 and esbuild 0.25.9. All MIT licensed - see
`LICENSE-excalidraw` and `LICENSE-react`. `web/BUILD-INFO.txt` records the exact versions the
committed bundle was built from.

## Why vendored, and why embedded rather than reimplemented

Two separate decisions.

**Embedded, not reimplemented.** Excalidraw is a mature infinite hand-drawn canvas: shapes, arrows
with real bindings, text, freehand, multi-select, grouping, undo, export, a shape library, the whole
keyboard map. Rebuilding that in AppKit would be a large effort that stays permanently behind the
real thing, for a feature whose value is that it behaves exactly like the tool the captain already
knows. So `WhiteboardController` hosts the real library in a `WKWebView` and adds only what this app
can uniquely contribute: the Helm theme, the drill-header chrome, and the Claude diagram call.

**Vendored, not fetched.** This app has zero remote dependencies by design (`Vendor/SwiftTerm/README.md`
has the original reasoning; `Package.resolved` does not exist) and is offline-first by posture - a
whiteboard that needed the network to *open* would be a regression from "everything stays on this
machine". So the built bundle is committed here, exactly like SwiftTerm's and whisper.cpp's sources
are, and the app loads it from disk with `loadFileURL`. There is no CDN script tag, no runtime
download, and no npm at app-build time: `swift build` never touches this directory.

Offline is enforced rather than promised. `web/index.html` carries a Content-Security-Policy with
`default-src 'self'` and `connect-src 'self'`, so even the CDN font fallback baked into the library
(`ASSETS_FALLBACK_URL`) cannot fire, and Excalidraw's embeddable-link feature has no `frame-src` to
load into. The web view also uses a non-persistent data store, so nothing is written to disk.

## Layout

| Path | What it is |
| --- | --- |
| `src/package.json` | The pinned dependency set. Edited by hand; installed only by the build script. |
| `src/whiteboard.js` | Hand-written entry point: mounts Excalidraw and defines `window.GrandLineWhiteboard`, the bridge the native side calls. |
| `src/index.html` | Hand-written page shell: the CSP, the suspend stylesheet, the one classic `<script>` tag. |
| `web/` | **Generated and committed.** `whiteboard.js` (the bundle), `whiteboard.css`, `index.html`, `fonts/`, `BUILD-INFO.txt`. |

## Rebuilding

```sh
native/Scripts/build-excalidraw-web.sh      # needs node/npm + network, build-time only
```

Run it after editing anything in `src/`, or after bumping a version in `src/package.json`, and
commit the regenerated `web/`. The same "a script generates it, you re-run the script, the output is
committed" convention as `WhisperMetalShaderSource.swift` - nothing regenerates itself.

## What the bundle contains, and the two deliberate omissions

One classic IIFE script (`--format=iife`), not an ES module graph: a module graph on a `file://`
origin is a portability question with nothing to gain here, and this way the page needs no import
map and no per-engine behaviour. Everything Excalidraw dynamically imports is inlined, which is why
the file is ~8MB - that includes Mermaid (the real "Mermaid to Excalidraw" feature, kept because it
works fully offline and is genuinely useful) and all ~40 UI locales (kept so the language picker
isn't a broken control).

Two things are left out:

- **`fonts/Xiaolai`** - 12MB of CJK handwriting subsets, 95% of the entire font payload, for glyph
  coverage this app's boards do not use. Excalidraw falls back to a system face for anything it
  cannot fetch, so the cost is CJK text rendering in a non-handwritten font rather than anything
  breaking. Re-add the directory in the build script if that changes.
- **`dist/dev`** - the development build of the library. `--conditions=production` selects
  `dist/prod`; without that flag esbuild cannot resolve the package's `./index.css` export at all.

## The entry file waits for the canvas fonts, and that is a correctness fix

`src/whiteboard.js` does not post `ready` until `loadCanvasFonts()` says Excalifont is genuinely
being used for measurement. That is not startup polish - it fixes a real, captain-reported defect
where a component's caption rendered as a few characters and the rest was gone.

The mechanism, measured rather than guessed at. Excalidraw sizes a text element by measuring the
string on a canvas at the moment the element is created, then **clips the real render to that
width**. Its own webfonts are registered lazily, so an element created before Excalifont is in use
is measured with the browser's fallback metrics and drawn in Excalifont, which is the wider of the
two. On this bundle, at 16px:

| caption | fallback | Excalifont | clipped |
| --- | --- | --- | --- |
| `Server` | 41.8 | 48.7 | no |
| `CloudWatch` | 79.6 | 88.7 | no |
| `RDS / Aurora` | 88.9 | 106.9 | **yes** |
| `Terraform / IaC` | 100.2 | 127.3 | **yes** |

A bound caption survives a gap of up to the bound-text padding (10pt) and is clipped past it, which
is why the captain saw it on some components and not others.

Two things that look like the fix and are not, both measured: `document.fonts.ready` resolves while
every face is still `unloaded`, and `document.fonts.load(spec)` resolves *before* the face is usable
by `measureText`. Only polling the measurement itself - comparing against a family that certainly
does not exist - reports the truth, which is what `fontIsInUse()` does. The wait is bounded
(`FONT_WAIT_MS`) and every failure is swallowed: a font that 404s or hangs must never be the reason
the canvas never appears.

`WhiteboardViewSelfTest.checkCaptionsAreNotClipped` is the guard, and it was confirmed to catch the
regression by name rather than merely to pass.

**A separate, still-unfixed truncation lives one layer down**, and loading the font does not touch
it: a *bound* caption containing `U+FE0F` (VARIATION SELECTOR-16) is truncated regardless. That is
handled on the native side by `WhiteboardLabel`, which strips presentation selectors from every
caption before it reaches the canvas; see that file for the measurements that rule out every
"it's an emoji problem" reading of it.

## A known, pre-existing arrow-binding defect, recorded so it is not re-discovered

A bound arrow whose two endpoints share an x coordinate - which every straight-down edge in
`DiagramDSL`'s flowchart layout is - is drawn slanting well off its target instead of vertically.
Reproduced on a four-box chain with no icons, no groups and no components involved, and reproduced
identically at the node height this app used *before*
`fm/grand-line-whiteboard-component-icons-overhaul` changed it, so it is neither caused by nor
affected by that work. Excalidraw recomputes a bound arrow's endpoints from a `focus` value derived
from the points it was given, and a zero-width arrow appears to make that derivation degenerate.
Left alone deliberately: fixing it is its own investigation into Excalidraw's binding maths.

## Upgrading

Bump the version in `src/package.json`, re-run the build script, then check three things by hand -
each is something a version bump has a real chance of moving:

1. **The bridge still exists.** `src/whiteboard.js` calls `convertToExcalidrawElements`,
   `updateScene`, `addFiles`, `resetScene`, `scrollToContent`, `getSceneElements` and the
   `excalidrawAPI` / `theme` / `langCode` / `UIOptions` props. A rename here is a silent failure at runtime, not a
   build error - the destination's overlay stays up, or an action reports through the bridge.
2. **`window.EXCALIDRAW_ASSET_PATH` is still how fonts are resolved**, and `dist/prod/fonts` is
   still the tree they come from.
3. **Dark-mode image inversion still behaves as the icons assume.** The library applies
   `invert(93%) hue-rotate(180deg)` to every image on a dark canvas - SVG included, because its own
   guard for SVGs compares the cached mime type against a map with no `svg` key, so it never fires.
   `Scripts/build-whiteboard-icons.py` draws the component chips to survive exactly that transform
   (lightness flips, hue is kept). If a version bump fixes the guard, the chips still render - they
   simply stop inverting in dark mode, which is worth a look but is not a breakage.
4. **The CSP still covers it.** A new feature that fetches something new will fail closed, which is
   the intended direction - but check the console before assuming a rendering bug.

`FM_RUN_WHITEBOARD_TESTS=1` covers the native side of all of this (asset resolution, the bridge's
reply plumbing, the AI parse, the gating decision); the canvas itself is verified by running the app.

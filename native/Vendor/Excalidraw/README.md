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

## Upgrading

Bump the version in `src/package.json`, re-run the build script, then check three things by hand -
each is something a version bump has a real chance of moving:

1. **The bridge still exists.** `src/whiteboard.js` calls `convertToExcalidrawElements`,
   `updateScene`, `resetScene`, `scrollToContent`, `getSceneElements` and the `excalidrawAPI` /
   `theme` / `langCode` / `UIOptions` props. A rename here is a silent failure at runtime, not a
   build error - the destination's overlay stays up, or an action reports through the bridge.
2. **`window.EXCALIDRAW_ASSET_PATH` is still how fonts are resolved**, and `dist/prod/fonts` is
   still the tree they come from.
3. **The CSP still covers it.** A new feature that fetches something new will fail closed, which is
   the intended direction - but check the console before assuming a rendering bug.

`FM_RUN_WHITEBOARD_TESTS=1` covers the native side of all of this (asset resolution, the bridge's
reply plumbing, the AI parse, the gating decision); the canvas itself is verified by running the app.

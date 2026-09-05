# Vendored Monaco Editor (the Code Preview destination's editor)

Source: [`monaco-editor`](https://github.com/microsoft/monaco-editor) **0.54.0** from npm, bundled
with esbuild 0.25.9. MIT licensed - see `LICENSE-monaco`. `web/BUILD-INFO.txt` records the exact
versions the committed bundle was built from, and exactly which parts of the package are in it.

## Why Monaco, and why vendored

**Monaco, specifically.** This was a captain decision taken after reviewing three options side by
side - vendor CodeMirror 6, vendor Monaco, or build a native `NSTextView` highlighter. Monaco is the
engine behind VS Code, which is the editor the captain reads code in, so a pasted snippet looks the
way they already expect it to. The lighter CodeMirror option and the native one were both
considered and not chosen.

**Embedded, not reimplemented.** Correct syntax highlighting is not a small problem: it is a real
tokenizer per language, plus bracket matching, folding, selection, find, and a caret that behaves.
`NSTextView` gives none of that, and an `NSRegularExpression` colouriser over a handful of keywords
is the thing that looks fine on the example and wrong on real code. So `CodePreviewController` hosts
the real editor in a `WKWebView` and adds only what this app can uniquely contribute: the Helm
theme, the tab bar, and the git-synced persistence.

**Vendored, not fetched.** This app has zero remote dependencies by design (`Vendor/SwiftTerm/README.md`
has the original reasoning; `Package.resolved` does not exist) and is offline-first by posture. So
the built bundle is committed here, exactly like SwiftTerm's and Excalidraw's are, and the app loads
it from disk with `loadFileURL`. There is no CDN script tag, no runtime download, and no npm at
app-build time: `swift build` never touches this directory.

Offline is enforced rather than promised. `web/index.html` carries a Content-Security-Policy with
`default-src 'self'` and `connect-src 'self'`, and `FM_RUN_CODE_PREVIEW_TESTS` reads that policy out
of the committed bytes rather than trusting this paragraph.

## Layout

| Path | What it is |
| --- | --- |
| `src/package.json` | The pinned dependency set. Edited by hand; installed only by the build script. |
| `src/code-preview.js` | Hand-written entry point: mounts the editor, defines the JSON tokenizer and the Helm-derived theme, and exposes `window.GrandLineCodePreview` - the bridge the native side calls. |
| `src/editor.worker.entry.js` | Hand-written entry point for Monaco's own editor worker. |
| `src/index.html` | Hand-written page shell: the CSP, the suspend stylesheet, the one classic `<script>` tag. |
| `web/` | **Generated and committed.** `code-preview.js`, `code-preview.css`, `index.html`, `BUILD-INFO.txt`. Four files, nothing else - see "Self-contained" below. |

## Rebuilding

```sh
native/Scripts/build-monaco-web.sh      # needs node/npm + network, build-time only
```

Run it after editing anything in `src/`, or after bumping a version in `src/package.json`, and
commit the regenerated `web/`. The same "a script generates it, you re-run the script, the output is
committed" convention as `WhisperMetalShaderSource.swift` and the Excalidraw bundle - nothing
regenerates itself, and `swift build` cannot tell that `src/` changed.

## What the bundle contains, and the three deliberate omissions

One classic IIFE script (`--format=iife`), not an ES module graph, for the same reason the
Whiteboard's is: a module graph on a `file://` origin is a portability question with nothing to
gain, and this way the page needs no import map. ~3.8MB of JS and ~256KB of CSS - under half the
Excalidraw bundle's size, because of what is left out:

- **`vs/language/{typescript,json,css,html}` are not imported.** Those are the *language services* -
  validation, IntelliSense, hovers, formatting - i.e. exactly the IDE machinery this panel is not
  supposed to carry. What *is* imported is `editor.all.js`, the editor's own contributions (find,
  folding, bracket matching, multi-cursor, the context menu), plus a hand-picked set of
  `basic-languages`, which are pure Monarch tokenizers.
- **Most of `basic-languages`.** Monaco ships ~90; fifteen are bundled (the captain's own day-to-day
  set plus the DevOps formats this app deals in elsewhere). The list is in `web/BUILD-INFO.txt` and
  in `CodePreviewLanguage.all`, which is the native side's copy of the same table.
- **`dist/dev` and the source maps.** Production build only.

### Self-contained: no fonts directory, no worker file

Two things the Excalidraw bundle keeps as separate files are inlined here instead, which is why
`web/` has four files and no subdirectories:

- **The codicon glyph font** is inlined into the CSS as a `data:` URI (`--loader:.ttf=dataurl`).
  Monaco fetches it lazily otherwise, and a missing font renders the find widget and the context
  menu as tofu.
- **Monaco's editor worker** is bundled separately and then inlined into `code-preview.js` as source
  text, started at runtime from a Blob URL. A sibling `editor.worker.js` would be simpler, but this
  page runs on a `file://` origin where starting a worker from a relative path is not portable and
  `fetch()`ing it to build a Blob is blocked outright. The worker is genuinely needed even with no
  language service registered: link detection and the unicode highlighter both run through
  `EditorWorkerService` on ordinary text, and Monaco throws the first time it wants a worker it
  cannot make.

## Upgrading

Bump the version in `src/package.json`, re-run the build script, then check four things by hand -
each is something a version bump has a real chance of moving:

1. **The API surface the bridge uses still exists.** `src/code-preview.js` calls
   `monaco.editor.create`, `createModel`, `setModelLanguage`, `defineTheme`, `setTheme`, `tokenize`,
   `saveViewState`/`restoreViewState`, and the `actions.find` action id. A rename here is a silent
   failure at runtime, not a build error.
2. **`editor.all.js` and `editor.worker.start.js` still exist under `esm/vs/editor/`**, and the
   `basic-languages/<id>/<id>.contribution.js` path shape is unchanged. These are the two the build
   script imports by path.
3. **The theme token names still match.** `applyTheme`'s `rules` name Monarch token types
   (`keyword`, `string`, `type`, …) and its `colors` name Monaco UI colour keys
   (`editor.selectionBackground`, `editorLineNumber.foreground`, …). An unknown key is ignored
   silently, so a renamed one shows up as a colour that stopped following the theme.
4. **The CSP still covers it.** A new feature that fetches something new will fail closed, which is
   the intended direction - but check the console before assuming a rendering bug.

`FM_RUN_CODE_PREVIEW_TESTS=1` covers the native side (asset resolution, the offline CSP, the
language table, detection, the store's round trip); `FM_RUN_CODE_PREVIEW_VIEW_TESTS=1` mounts the
real page in a real window and drives the real bridge, including reading Monaco's own tokenizer
output back to prove highlighting actually happened.

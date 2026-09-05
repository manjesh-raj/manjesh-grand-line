// Manjesh Grand Line - the Code Preview's editor worker entry point.
//
// Built into its own bundle by `native/Scripts/build-monaco-web.sh`, which then
// inlines the result into `code-preview.js` as text (see that file's "The
// worker" section for why it is embedded rather than shipped as a sibling
// file: this page runs on a `file://` origin, where starting a worker from a
// relative path is not portable and `fetch()`ing it to build a Blob is blocked
// outright).
//
// This is Monaco's own worker, unmodified - none of the `vs/language/*`
// services are registered on it, because none of them are imported into the
// page either. What it actually serves is the plain-text work
// `EditorWorkerService` does on any document regardless of language: link
// detection, the unicode highlighter, word ranges. Without it Monaco throws
// the first time it wants a worker.
import "monaco-editor/esm/vs/editor/editor.worker.start.js";

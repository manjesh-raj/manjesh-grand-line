// Grand Line - the Whiteboard destination's web side.
//
// Hand-written entry point for the bundle `native/Scripts/build-excalidraw-web.sh`
// produces (see ../README.md). It mounts the real `@excalidraw/excalidraw`
// React component full-page and exposes exactly one global,
// `window.GrandLineWhiteboard`, as the bridge the native side drives with
// `evaluateJavaScript`. Nothing here reaches the network: every asset it needs
// (the bundle, its CSS, the woff2 fonts) is a sibling file on disk, and
// index.html carries a Content-Security-Policy that makes that structural
// rather than a claim.
//
// Two conventions worth keeping if this file is edited:
//
//   1. **Every entry point answers.** Each bridge call posts exactly one
//      `{ type: "reply", callID, ok, ... }` message back to Swift, so the
//      native side never has to guess whether an `evaluateJavaScript` that
//      returned `undefined` actually did anything. A throw inside a bridge
//      call is caught and answered as `ok: false` with a real message.
//   2. **No always-on animation or polling.** The one rAF loop in this file
//      is the gating probe, which stays dormant unless the native side turns
//      it on for a measurement (see `startGatingProbe`). Adding a permanent
//      ticker here is the exact battery mistake `CockpitTerminalView`'s
//      display gating exists to undo.
import React, { useCallback, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  Excalidraw,
  convertToExcalidrawElements,
  exportToCanvas,
} from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";

// Excalidraw resolves its lazily-loaded woff2 subsets against this base. The
// bundle and its `fonts/` directory are siblings, so "./" is the whole answer -
// and it is what keeps the CDN fallback baked into the library
// (`ASSETS_FALLBACK_URL`) from ever being reached for a font we ship.
window.EXCALIDRAW_ASSET_PATH = "./";

const post = (payload) => {
  try {
    window.webkit.messageHandlers.grandlineWhiteboard.postMessage(payload);
  } catch (err) {
    // No native host (e.g. the page opened in a plain browser for debugging).
    // Never throw from a bridge call just because nobody is listening.
    if (window.console) console.warn("whiteboard: no native host", err);
  }
};

const reply = (callID, body) => {
  if (callID === undefined || callID === null) return;
  post({ type: "reply", callID, ...body });
};

let api = null;
let suspended = false;

function Whiteboard({ onReady }) {
  const [theme, setTheme] = useState(
    document.documentElement.dataset.theme === "dark" ? "dark" : "light"
  );

  // The native side owns the theme, so it is pushed in rather than read from
  // the OS: the app's own Helm light/dark mode is what decides, exactly like
  // every other surface in this app.
  window.__setWhiteboardTheme = setTheme;

  const excalidrawAPICallback = useCallback(
    (instance) => {
      api = instance;
      onReady();
    },
    [onReady]
  );

  return React.createElement(Excalidraw, {
    excalidrawAPI: excalidrawAPICallback,
    theme,
    langCode: "en",
    // The whiteboard is a local scratch surface: the two features that reach
    // for the network (live collaboration, the shared-link/library browser)
    // have nothing to talk to here, so they are off rather than present and
    // broken.
    UIOptions: {
      canvasActions: {
        loadScene: true,
        saveToActiveFile: false,
        export: { saveFileToDisk: true },
        toggleTheme: false,
      },
    },
    onChange: () => {
      // Deliberately not a per-keystroke bridge message: the native side only
      // wants a coarse "is there anything on this board" signal for its drill
      // header, and posting on every pointer move would be its own battery
      // problem. `elementCount` is read on demand instead (see `stats`).
    },
  });
}

/// Pull Excalidraw's own webfonts in before anything is told the canvas is
/// usable.
///
/// **This is a correctness fix, not a polish one.** Excalidraw sizes a text
/// element by measuring the string on a canvas at conversion time, and then
/// clips the real render to that width. Its fonts are registered but *lazy* -
/// a face is only fetched the first time something asks for it - so a diagram
/// inserted before Excalifont has loaded is measured with the browser's
/// fallback metrics and drawn in Excalifont, which is the wider of the two.
/// Measured on this bundle: "RDS / Aurora" measures 88.9 in the fallback and
/// 106.9 in Excalifont, so 18pt of it was drawn outside its own element and
/// clipped away - which is what a captain sees as a caption missing its last
/// few characters.
///
/// `document.fonts.ready` alone is not enough and was measured not to be: it
/// resolves while every lazy face is still `unloaded`, so each one has to be
/// asked for by name.
///
/// Deliberately bounded and deliberately non-fatal. A font that 404s or hangs
/// must never be the reason the canvas never appears, so every face swallows
/// its own failure and the whole wait gives up after `FONT_WAIT_MS` - at which
/// point the board still works and, at worst, a long caption clips exactly as
/// it did before this existed.
const FONT_WAIT_MS = 4000;

/// The families the canvas can render with, minus Xiaolai - excluded from the
/// build (see BUILD-INFO.txt), so asking for it would be a guaranteed 404 on
/// every launch rather than a useful wait.
const CANVAS_FONTS = [
  "Excalifont",
  "Nunito",
  "Comic Shanns",
  "Lilita One",
  "Cascadia",
  "Assistant",
];

/// A string with enough varied glyphs that a real face and the fallback cannot
/// coincidentally measure the same.
const FONT_PROBE_TEXT = "RDS / Aurora Wij";

/// Measured width of `FONT_PROBE_TEXT` in `family`, or `NaN` if the canvas is
/// unavailable.
function probeWidth(family) {
  try {
    const ctx = document.createElement("canvas").getContext("2d");
    ctx.font = '16px "' + family + '"';
    return ctx.measureText(FONT_PROBE_TEXT).width;
  } catch (err) {
    return NaN;
  }
}

/// True once `family` is genuinely being used for measurement.
///
/// Deliberately not `document.fonts.check()` and not the resolution of
/// `document.fonts.load()` - both were measured to answer "yes" while
/// `measureText` was still returning fallback metrics, which is the only
/// number that matters here. Comparing against a family that certainly does
/// not exist tests the thing itself.
function fontIsInUse(family) {
  const real = probeWidth(family);
  const fallback = probeWidth("__grandline_missing_family__");
  return isFinite(real) && isFinite(fallback) && Math.abs(real - fallback) > 0.5;
}

function loadCanvasFonts() {
  if (!document.fonts || !document.fonts.load) return Promise.resolve();
  const deadline = Date.now() + FONT_WAIT_MS;
  return new Promise((resolve) => {
    const attempt = () => {
      // Asked for by name on every pass rather than once: Excalidraw registers
      // its faces around the time this first runs, so an early call can match
      // nothing at all and resolve instantly.
      CANVAS_FONTS.forEach((family) => {
        try {
          document.fonts.load('16px "' + family + '"').catch(() => {});
        } catch (err) {
          /* a family this build does not ship is not worth failing over */
        }
      });
      // Only Excalifont is waited *for*. It is what the canvas draws with by
      // default and what every diagram this app generates uses; the rest are
      // asked for so a captain who switches font in Excalidraw's own UI has
      // them warm, but none of them may hold the canvas up.
      if (fontIsInUse("Excalifont") || Date.now() >= deadline) {
        resolve();
        return;
      }
      setTimeout(attempt, 50);
    };
    attempt();
  });
}

const root = createRoot(document.getElementById("app"));
root.render(
  React.createElement(Whiteboard, {
    // `ready` is what unblocks every native path that puts elements on this
    // canvas, so waiting for the fonts here is what keeps a caption from being
    // measured against the wrong metrics - see `loadCanvasFonts`.
    onReady: () => {
      loadCanvasFonts().then(() => post({ type: "ready" }));
    },
  })
);

// --- The bridge -----------------------------------------------------------

const liveElements = () =>
  (api ? api.getSceneElements() : []).filter((el) => !el.isDeleted);

const bridge = {
  /// Loads AI-generated (or pasted) elements onto the canvas.
  ///
  /// `skeleton` is Excalidraw's own documented *element skeleton* format, not
  /// its full internal element shape - `convertToExcalidrawElements` is the
  /// library's own function for filling in every derived field (id, seed,
  /// version nonces, bindings, container/label wiring). That is why the native
  /// prompt asks a model for the skeleton: it is a small, documented surface,
  /// and anything the model gets wrong about the internals is not ours to
  /// guess at.
  loadScene(callID, payload) {
    try {
      if (!api) throw new Error("the canvas is still starting up");
      const skeleton = payload && payload.elements;
      if (!Array.isArray(skeleton) || skeleton.length === 0) {
        throw new Error("no elements to load");
      }
      // `convertToExcalidrawElements` is Excalidraw's own internals, not this
      // app's - a skeleton shape the native-side validation did not (or
      // cannot) catch can still make it throw a raw JS runtime error (a
      // TypeError like "undefined is not an object (evaluating
      // 'o.children.forEach')", or one of its own internal `Error`s naming
      // an id). None of that is something the captain can act on, so it is
      // caught here specifically - never let it reach the outer catch's
      // `reply` verbatim - logged for debugging, and replaced with one
      // message that is always actionable regardless of what went wrong
      // inside the library.
      // Icon artwork, when the native side sent any. Files go in *before*
      // the elements that reference them: an `image` element whose `fileId`
      // names a file the scene does not have yet renders as a broken
      // placeholder and stays broken, because nothing re-resolves it later.
      const files = (payload && payload.files) || [];
      if (files.length) {
        api.addFiles(files.map((f) => ({
          id: f.id,
          dataURL: f.dataURL,
          mimeType: f.mimeType || "image/svg+xml",
          created: Date.now(),
        })));
      }
      let converted;
      try {
        converted = convertToExcalidrawElements(skeleton);
      } catch (convErr) {
        if (window.console) console.error("whiteboard: convertToExcalidrawElements failed", convErr);
        throw new Error("Claude's diagram used something this whiteboard couldn't draw. Try rewording the description, or try again.");
      }
      if (!converted.length) throw new Error("no elements survived conversion");
      const existing = payload.mode === "append" ? liveElements() : [];
      api.updateScene({ elements: [...existing, ...converted] });
      api.scrollToContent(converted, { fitToContent: true, animate: false });
      reply(callID, { ok: true, count: converted.length });
    } catch (err) {
      reply(callID, { ok: false, message: String((err && err.message) || err) });
    }
  },

  /// Serializes what is *actually* on the board right now, back into the same
  /// element-skeleton shape `loadScene` accepts and `WhiteboardDiagram.parse`
  /// validates.
  ///
  /// This is what makes iterative refinement honest. A model asked to "make the
  /// database box bigger" has to be told what is on the board, and the board -
  /// not whatever the model believes it drew three turns ago - is the truth:
  /// the whole point of embedding a real Excalidraw is that the captain can
  /// move, delete and draw with its own tools between two AI turns.
  ///
  /// Deliberately lossy, and lossy in a stated direction. Excalidraw publishes
  /// no inverse of `convertToExcalidrawElements`, so this reconstructs the
  /// documented skeleton surface only: geometry, type, id, the styling fields
  /// the prompt itself offers, bound labels folded back into their container
  /// (Excalidraw stores a shape's caption as a separate `text` element with a
  /// `containerId`, which is exactly how the skeleton's `label` is expanded on
  /// the way in), arrow bindings as `start`/`end` ids, and a frame's children
  /// recovered from each element's own `frameId`. Everything derived - seeds,
  /// version nonces, points arrays, `boundElements` - is left out on purpose:
  /// the model has no business reasoning about it, and `loadScene` regenerates
  /// all of it from the skeleton anyway.
  snapshot(callID) {
    try {
      if (!api) throw new Error("the canvas is still starting up");
      reply(callID, { ok: true, elements: toSkeleton(liveElements()) });
    } catch (err) {
      reply(callID, { ok: false, message: String((err && err.message) || err) });
    }
  },

  clear(callID) {
    try {
      if (!api) throw new Error("the canvas is still starting up");
      api.resetScene();
      reply(callID, { ok: true, count: 0 });
    } catch (err) {
      reply(callID, { ok: false, message: String((err && err.message) || err) });
    }
  },

  fitToContent(callID) {
    try {
      if (!api) throw new Error("the canvas is still starting up");
      const elements = liveElements();
      if (elements.length) {
        api.scrollToContent(elements, { fitToContent: true, animate: false });
      }
      reply(callID, { ok: true, count: elements.length });
    } catch (err) {
      reply(callID, { ok: false, message: String((err && err.message) || err) });
    }
  },

  setTheme(callID, payload) {
    try {
      const mode = payload && payload.theme === "dark" ? "dark" : "light";
      document.documentElement.dataset.theme = mode;
      if (window.__setWhiteboardTheme) window.__setWhiteboardTheme(mode);
      // M1 of the UI modernization audit (report.md §3M): "match Excalidraw's
      // island radius/fill via its CSS custom properties if exposed". They
      // are - `.Island` resolves its fill from `--island-bg-color`, its
      // corner from `--border-radius-lg` and its shadow from
      // `--shadow-island`, all three read from the document root - so the one
      // seam-hider that finding asks for is three variable writes rather than
      // a patch to the vendored bundle.
      //
      // Every value comes from the native side (this app's own card token and
      // radius scale); anything absent is left alone, so an older native
      // build that only sends `theme` keeps exactly today's Excalidraw look.
      const island = (payload && payload.island) || {};
      const root = document.documentElement;
      if (island.bg) root.style.setProperty("--island-bg-color", island.bg);
      if (island.radius) root.style.setProperty("--border-radius-lg", island.radius);
      if (island.shadow) root.style.setProperty("--shadow-island", island.shadow);
      reply(callID, { ok: true });
    } catch (err) {
      reply(callID, { ok: false, message: String((err && err.message) || err) });
    }
  },

  /// F15's "Copy image": flatten the whole board - the captured screenshot
  /// and every annotation drawn over it - into one PNG.
  ///
  /// `exportToCanvas` is Excalidraw's own exporter, which is the entire point
  /// of the choice: it renders through the same code path the canvas itself
  /// uses, so a freehand stroke, a bound arrow label and a blurred rectangle
  /// all come out looking the way the captain drew them. The native side has
  /// no renderer of its own and should never grow one - a second renderer is
  /// a second thing to keep in step with a vendored library.
  ///
  /// Two deliberate choices about what gets flattened:
  ///
  ///   - **The background is included.** A transparent PNG pasted into a chat
  ///     window or a ticket renders against whatever that app's surface is,
  ///     which for a dark-canvas board means dark strokes on white. The board
  ///     the captain is looking at is what they mean to send.
  ///   - **Only live elements.** `liveElements()` already drops deleted ones;
  ///     exporting the raw scene would bake in shapes the captain erased.
  ///
  /// The PNG comes back as a data URL in the reply. That is a large string for
  /// a large board, which is why `maxWidthOrHeight` is bounded from the native
  /// side rather than left open.
  ///
  /// **Not declared `async`.** The native bridge evaluates
  /// `window.GrandLineWhiteboard.<name>(id, payload);` as an expression
  /// statement, and `WKWebView.evaluateJavaScript` fails an expression whose
  /// value is a `Promise` with "returned a result of an unsupported type" -
  /// which reaches the caller as a bridge failure *before* the real reply
  /// arrives, so the export looked broken while it was in fact working.
  /// Measured, not guessed: the first version of this command was `async` and
  /// `WhiteboardCaptureViewSelfTest` failed on exactly that message. The work
  /// is async, so it is started and deliberately not returned; the reply comes
  /// through `reply(...)` like every other command's.
  exportImage(callID, payload) {
    exportImageAsync(callID, payload);
  },

  stats(callID) {
    reply(callID, { ok: true, count: liveElements().length, suspended });
  },

  /// Called when the destination is hidden (and again when it is shown).
  ///
  /// WebKit already stops painting and throttles rAF for a `WKWebView` whose
  /// NSView is hidden - `document.visibilityState` goes `hidden` - so this is
  /// not the thing keeping idle cost at zero. What it does add is the part
  /// WebKit cannot know about: CSS transitions/animations inside Excalidraw's
  /// own chrome are paused outright, the canvas loses focus so no caret blinks,
  /// and the gating probe (if running) is stopped.
  suspend(callID) {
    suspended = true;
    document.documentElement.classList.add("gl-suspended");
    if (document.activeElement && document.activeElement.blur) {
      document.activeElement.blur();
    }
    stopGatingProbe();
    reply(callID, { ok: true, visibility: document.visibilityState });
  },

  resume(callID) {
    suspended = false;
    document.documentElement.classList.remove("gl-suspended");
    reply(callID, { ok: true, visibility: document.visibilityState });
  },

  // --- Gating probe -------------------------------------------------------
  //
  // Dormant by default and only ever started by an explicit native call, so
  // this file has no always-on loop. It exists because "the hidden tab costs
  // nothing" deserves evidence stronger than an Activity Monitor eyeball: a
  // rAF counter that stops advancing while the view is hidden is WebKit
  // telling us it stopped compositing this page.
  startGatingProbe(callID) {
    startGatingProbe();
    reply(callID, { ok: true });
  },

  readGatingProbe(callID) {
    reply(callID, {
      ok: true,
      frames: probeFrames,
      visibility: document.visibilityState,
      suspended,
    });
  },
};

// --- Board -> skeleton ----------------------------------------------------

// The styling fields the generation prompt itself offers, and nothing else. A
// skeleton carrying an unknown key is not a crash, but it is noise in a prompt
// that has to stay readable, and round-tripping a field the model was never
// told about invites it to invent more of them.
const SKELETON_STYLE_KEYS = [
  "strokeColor",
  "backgroundColor",
  "fillStyle",
  "strokeWidth",
  "strokeStyle",
  "roughness",
  "fontSize",
  "fontFamily",
  "textAlign",
];

function toSkeleton(elements) {
  // A shape's caption lives as its own `text` element pointing back at the
  // container. Fold those in as `label` and drop them as standalone entries,
  // which is the shape `loadScene` is handed on the way in.
  const labels = new Map();
  for (const el of elements) {
    if (el.type === "text" && el.containerId) {
      labels.set(el.containerId, el.text || "");
    }
  }
  // A frame owns its children by each child naming the frame, not the other
  // way round - but the skeleton format wants the list on the frame.
  //
  // A bound caption inherits its container's `frameId`, and captions are folded
  // into their container below rather than emitted, so a naive membership list
  // names ids that are not in the reply. That is not cosmetic: the native
  // validator refuses a frame whose "children" names an element that is not
  // there, and `convertToExcalidrawElements` needs every named child to exist.
  // So a caption is skipped here for the same reason it is skipped below.
  const children = new Map();
  for (const el of elements) {
    if (!el.frameId) continue;
    if (el.type === "text" && el.containerId) continue;
    if (!children.has(el.frameId)) children.set(el.frameId, []);
    children.get(el.frameId).push(el.id);
  }

  const out = [];
  for (const el of elements) {
    if (el.type === "text" && el.containerId) continue;
    const node = { type: el.type === "magicframe" ? "frame" : el.type, id: el.id };
    for (const key of ["x", "y", "width", "height", "angle"]) {
      if (typeof el[key] === "number" && el[key] !== 0) node[key] = round(el[key]);
    }
    for (const key of SKELETON_STYLE_KEYS) {
      if (el[key] !== undefined && el[key] !== null) node[key] = el[key];
    }
    if (el.type === "text") {
      node.text = el.text || "";
    } else if (labels.has(el.id)) {
      node.label = { text: labels.get(el.id) };
    }
    if (el.type === "arrow" || el.type === "line") {
      if (el.startBinding && el.startBinding.elementId) {
        node.start = { id: el.startBinding.elementId };
      }
      if (el.endBinding && el.endBinding.elementId) {
        node.end = { id: el.endBinding.elementId };
      }
    }
    if (node.type === "frame") {
      node.name = el.name || "";
      node.children = children.get(el.id) || [];
    }
    out.push(node);
  }
  // A frame with an empty `children` list is refused by the native validator
  // and crashes `convertToExcalidrawElements` outright - so a frame the captain
  // emptied by hand is degraded to a plain rectangle here rather than handed
  // back as a skeleton nothing downstream will accept.
  return out.map((node) => {
    if (node.type !== "frame" || node.children.length > 0) return node;
    const degraded = { ...node, type: "rectangle", label: { text: node.name || "" } };
    // Deleted rather than set to undefined: this crosses the WebKit message
    // bridge, where an undefined value is not the same as an absent key.
    delete degraded.name;
    delete degraded.children;
    return degraded;
  });
}

const round = (n) => Math.round(n * 100) / 100;

let probeFrames = 0;
let probeHandle = null;

function startGatingProbe() {
  probeFrames = 0;
  if (probeHandle !== null) return;
  const tick = () => {
    probeFrames += 1;
    probeHandle = window.requestAnimationFrame(tick);
  };
  probeHandle = window.requestAnimationFrame(tick);
}

function stopGatingProbe() {
  if (probeHandle !== null) {
    window.cancelAnimationFrame(probeHandle);
    probeHandle = null;
  }
}

// The body of the `exportImage` bridge command. Kept out of the `bridge`
// object because an entry point there must not return a value the native side
// cannot marshal - see that command's own note.
async function exportImageAsync(callID, payload) {
  try {
    if (!api) throw new Error("the canvas is still starting up");
    const elements = liveElements();
    if (!elements.length) throw new Error("the board is empty - there is nothing to copy");
    const appState = api.getAppState();
    const canvas = await exportToCanvas({
      elements,
      appState: {
        ...appState,
        exportBackground: true,
        exportWithDarkMode: appState.theme === "dark",
      },
      files: api.getFiles(),
      exportPadding: (payload && payload.padding) || 16,
      maxWidthOrHeight: (payload && payload.maxWidthOrHeight) || 4096,
    });
    const dataURL = canvas.toDataURL("image/png");
    reply(callID, {
      ok: true,
      dataURL,
      width: canvas.width,
      height: canvas.height,
      count: elements.length,
    });
  } catch (err) {
    reply(callID, { ok: false, message: String((err && err.message) || err) });
  }
}

window.GrandLineWhiteboard = bridge;

window.addEventListener("error", (event) => {
  post({ type: "error", message: String(event.message || "script error") });
});
window.addEventListener("unhandledrejection", (event) => {
  post({
    type: "error",
    message: String((event.reason && event.reason.message) || event.reason || "promise rejection"),
  });
});

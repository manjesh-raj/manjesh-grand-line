#!/bin/bash
# Manjesh Grand Line - native macOS app.
#
# Provisions the local video-generation pipeline: a dedicated Python venv
# with `dgrauet/ltx-2-mlx` (pinned to the exact commit this feature was
# validated against, 91e6f6c9bd621ff2ae31adfee643e113d67d6ae8 -
# fm/grandline-videogen-feasibility-scout's own scout report has the full
# validation evidence), plus the exact set of LTX-2.3 q4-distilled model
# files that pipeline mode needs - not the upstream tool's own default
# `snapshot_download` of the whole ~60GB repo (which bundles three
# transformer variants and two duplicate-sized LoRA files this pipeline mode
# never touches; traced through `DistilledPipeline.load()` in the vendored
# tool's own source during the scout's validation pass), plus the separate
# ~8GB `mlx-community/gemma-3-12b-it-4bit` text encoder LTX-2.3 needs.
#
# Run from `VideoGenController`'s "Set Up" button, through the same real
# Console-tab mechanism every other multi-gigabyte/long-running/sudo-needing
# action in this app already uses (`AppShellController.runInConsole`,
# `bootstrap.onRunCommand`/`vault.onRunCommand`'s own convention) - not a
# custom Swift progress bar. A ~13-minute, ~27GB, multi-file download is
# exactly the case a real terminal's own progress output serves better than
# a hand-rolled one, and it means this script owns the whole provisioning
# story with no parallel Swift-side download/retry logic to keep in sync.
#
# Idempotent: every step checks whether its own output already exists before
# doing the work, so a captain who re-runs this after an interrupted first
# attempt (dropped Wi-Fi mid-download, etc.) only re-fetches what's actually
# missing - each `hf_hub_download` call below is itself a single already-
# resumable-by-huggingface_hub-internals file fetch, and skipping a file
# whose target path already exists and is a plausible size is this script's
# own layer of that same idea applied per-file across the whole set.
#
# `set -e`: any real failure (network, disk, pip) stops the script and
# leaves partial state behind rather than reporting success - the next run
# repairs it starting from whatever finished last time.
set -e

VIDEOGEN_DIR="${FM_VIDEOGEN_DIR:-$HOME/Library/Application Support/FirstmateCockpit/videogen}"
VENV_DIR="$VIDEOGEN_DIR/venv"
MODEL_DIR="$VIDEOGEN_DIR/models/ltx-2.3-mlx-q4"
HF_CACHE_DIR="$VIDEOGEN_DIR/hf-cache"
LTX_COMMIT="91e6f6c9bd621ff2ae31adfee643e113d67d6ae8"

mkdir -p "$VIDEOGEN_DIR" "$MODEL_DIR" "$HF_CACHE_DIR"
export HF_HOME="$HF_CACHE_DIR"

echo "== Grand Line video generation: setup =="
echo "Target: $VIDEOGEN_DIR"

# --- 1. Python venv + the pinned ltx-2-mlx packages -------------------------
if [ ! -x "$VENV_DIR/bin/ltx-2-mlx" ]; then
  echo "-- creating venv and installing ltx-2-mlx (pinned commit $LTX_COMMIT) --"
  PYTHON_BIN="$(command -v python3.12 || command -v python3)"
  if [ -z "$PYTHON_BIN" ]; then
    echo "No python3 found on PATH. Install Python 3.12+ (e.g. \`brew install python@3.12\`) and try again." >&2
    exit 1
  fi
  "$PYTHON_BIN" -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip --quiet
  "$VENV_DIR/bin/pip" install --quiet \
    "git+https://github.com/dgrauet/ltx-2-mlx.git@${LTX_COMMIT}#subdirectory=packages/ltx-core-mlx" \
    "git+https://github.com/dgrauet/ltx-2-mlx.git@${LTX_COMMIT}#subdirectory=packages/ltx-pipelines-mlx"
  echo "-- venv ready --"
else
  echo "-- venv already installed, skipping --"
fi

# --- 2. Selective model download --------------------------------------------
# The exact file set `DistilledPipeline.load()` reads for `generate
# --distilled` on the LTX-2.3 q4 pack, confirmed live during validation
# (native/Sources/FirstmateCockpit/VideoGenEnvironment.swift's
# `requiredModelFiles` is the same list, so the two cannot drift apart).
echo "-- checking model files (dgrauet/ltx-2.3-mlx-q4) --"
"$VENV_DIR/bin/python3" - <<'PYEOF'
import os
from huggingface_hub import hf_hub_download

model_dir = os.path.join(
    os.environ.get(
        "FM_VIDEOGEN_DIR",
        os.path.expanduser("~/Library/Application Support/FirstmateCockpit/videogen"),
    ),
    "models",
    "ltx-2.3-mlx-q4",
)
repo = "dgrauet/ltx-2.3-mlx-q4"

# (filename, minimum plausible byte size - catches an aborted/partial file
# left over from an interrupted run, the same floor
# `WhisperModelManager`/`WhisperModelValidationError` already uses for this
# exact reason)
files = [
    ("config.json", 10),
    ("embedded_config.json", 10),
    ("quantize_config.json", 10),
    ("split_model.json", 10),
    ("connector.safetensors", 1_000_000_000),
    ("transformer-distilled.safetensors", 1_000_000_000),
    ("vae_encoder.safetensors", 100_000_000),
    ("vae_decoder.safetensors", 100_000_000),
    ("audio_vae.safetensors", 10_000_000),
    ("vocoder.safetensors", 10_000_000),
    ("spatial_upscaler_x2_v1_1.safetensors", 100_000_000),
    ("spatial_upscaler_x2_v1_1_config.json", 10),
]

for name, min_size in files:
    dest = os.path.join(model_dir, name)
    if os.path.exists(dest) and os.path.getsize(dest) >= min_size:
        print(f"already present: {name}")
        continue
    print(f"downloading: {name}")
    hf_hub_download(repo, name, local_dir=model_dir)

print("model files ready")
PYEOF

# --- 3. The Gemma-3-12B text encoder ----------------------------------------
# LTX-2.3's text encoder path needs this separately (not bundled in the LTX
# pack itself - only LTX-2.5 packs bundle their own text encoder). The
# `mlx-community` mirror downloads without a Hugging Face token, confirmed
# live during validation.
echo "-- checking Gemma-3-12B text encoder (mlx-community/gemma-3-12b-it-4bit) --"
"$VENV_DIR/bin/python3" -c "
from huggingface_hub import snapshot_download
snapshot_download('mlx-community/gemma-3-12b-it-4bit')
print('gemma text encoder ready')
"

echo "== Setup complete. You can close this tab and return to the Video page. =="

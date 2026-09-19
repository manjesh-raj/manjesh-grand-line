# Features that were built and then removed

> Feature history, relocated out of `AGENTS.md` by P1 of full review #3.
> **This file is not imported into an agent session.** Read it when you are
> about to touch this area; the standing rules that apply everywhere live in
> the repository root `AGENTS.md`.
>
> Content below is verbatim from the `AGENTS.md` this was split out of. It is a
> record of what shipped, what was tried, and what replaced it - entries are in
> the order they were written, so a later one can correct an earlier one.

## VPN (built, then removed)

A rail section and a Tools panel for controlling Barracuda VPN and OpenVPN Connect were built across several tasks (`fm/grandline-vpn-toggle-integration`, `fm/grandline-hosts-vpn-flyout-redesign`, `fm/grandline-rail-unify-and-mark-polish`, `fm/grandline-vpn-divider-and-connect-fixes`) and then removed entirely (`fm/grandline-remove-vpn-feature`) once live testing showed both clients have restrictions that make reliable control from this app impractical: Barracuda's own Network Extension crashes internally (a nil-argument exception in its own `PacketTunnel` code) on any connect triggered outside its own app UI - confirmed via its own crash logs across 5 real attempts, and not an "app needs to be running first" issue - and OpenVPN Connect is Electron/Chromium-based, which does not expose its real UI content to macOS's Accessibility API even after trying the standard techniques to force it. Neither is fixable from this app's side. If this is ever revisited, re-confirm both clients' restrictions haven't changed before rebuilding any of it.

## Video generation (removed)

**Historical, and deliberately not re-derivable from the code any more: PR #309 ("Add local text-to-video generation, a new 'Video' Stores card (LTX-2)") and PR #310 ("Add real Video Stores settings and a feedback-driven regeneration loop") shipped a local on-device text-to-video generator (`.videoGen`, a Stores destination) built on a vendored LTX-2 MLX pipeline - `fm/grandline-remove-video-feature` removed the whole feature outright** after the captain's own extended real-world testing found local video generation wasn't achievable at a useful duration on this Mac: even a 30-second clip hit Metal out-of-memory failures and severe slowdowns after 30+ minutes of real generation attempts, well short of what was wanted. Removed: `VideoGenController.swift`, `VideoGenEngine.swift`, `VideoGenEnvironment.swift`, `VideoPromptEnhancer.swift`, `SelfTests/VideoGenSelfTest.swift`, `native/Scripts/videogen-setup.sh`, the `RailDestination.videoGen`/`DestinationSlotID.videoGen`/`DaylightModule.videoGen` cases and every switch arm over them, the `FM_RUN_VIDEOGEN_TESTS` self-test dispatch in `main.swift`, and the `videogen-setup.sh` resource-copy step in `native/build_native_app.sh`. The locally-downloaded ~27GB LTX-2 model and its Python venv under `~/Library/Application Support/FirstmateCockpit/videogen/` are local machine state outside this git repo and were deliberately left for separate cleanup, not deleted by this removal. **If local video generation is ever revisited, re-derive the feasibility question from scratch** (a different pipeline, quantization, or hardware) rather than assuming the prior implementation's CLI-argument-mapping/duration/clarity findings still apply - none of that code survives this removal.

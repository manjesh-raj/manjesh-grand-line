# Helm kit versions

The Helm kit is every `Helm*.swift` file in `native/Sources/GrandLine/`.
`native/Sources/GrandLine/HelmKitVersion.swift` holds its version table: `HelmKit.version` for the kit as a whole and one semantic version per component.
This file is the release notes for that table, newest release first.
`FM_RUN_HELM_KIT_VERSION_TESTS` reads it, so its shape is part of the contract.

## How to release

1. Change the component.
2. Bump that component's version in `HelmKit.components` (or `HelmKit.surfaces` for an app-level view).
3. Add a section at the top of this file for the new kit version, with one bullet per component that moved.
4. Move `HelmKit.version` by the largest bump in the section.
5. Run `FM_RUN_HELM_KIT_VERSION_TESTS=1 .build/debug/GrandLine` and paste the digest it prints into `HelmKit.sourceDigests`.

The suite prints a new digest only once one of the file's versions has moved.
A changed kit file with no bump fails the run.

## The bump rule

- **patch**: a visual tweak that changes no call site.
- **minor**: a new or extended component, option or token.
- **major**: a breaking replacement, or a removal.
- **new**: a component that did not exist. It enters at 1.0.0 and moves the kit by a minor.

The kit version moves by the largest bump in its release.
A removal is written `` `Name` 1.2.0 → removed (removed) `` and moves the kit by a major.

## Bullet format

Each bullet starts with the component name in backticks, the two versions and the bump kind:

```
- `HelmPageSidebar` 1.0.0 → 1.1.0 (minor): what changed, and the proposal or PR.
```

A change that is not a kit component (a private list retired inside a page, for example) is written as plain prose under the section, without the backticked shape.

## 1.4.0 - S04: one page-sidebar surface

- `HelmPageSidebar` 1.0.0 → 1.1.0 (minor): `Surface.band`, now the default, plus `HelmPageSidebar.Band` (the side-panel fill and its edge hairline, theme-following) and `bandPaneWidth` / `bandInsets` (Settings' own numbers, so every band is one width with one padding).

Schedules, Reading list and Notebook hold their columns in a `.sidePanel` split pane with the band's width and padding, where they sat on the page ground. Settings reads the same constants and looks as it did. Commands' column loses its card and sits on a full-height band behind it. Code's "Snippets" and "Quick actions" cards are one band running from the page's edge to the status bar, with the two actions as its footer (the private card pair is removed). Tasks, Hosts and Poneglyph keep `.plain` explicitly.

## 1.3.0 - S07: Runbook and Postmortem cards are the control

- `HelmPlateCard` 1.0.0 → 1.1.0 (minor): `Content.actionReveal` (`.always`, the default and the plate as it was, or `.onAim`) and `Content.onDuplicate`. An `.onAim` plate has no action row: the whole card opens (click, Return, Space, VoiceOver), its subtitle is the record's meta line, it is as tall as its header, and duplicate and delete show as 28pt corner glyphs only on hover or focus. ⌫ deletes through the caller's confirm and ⌘D duplicates.

Runbooks and Postmortems opt in. A runbook's meta line is "OpenSSL · 1 step · updated 5 min ago", a postmortem's "Updated 5 min ago · Root cause: …", and a runbook can be duplicated ("<title> copy"). Their Open buttons and resting trash glyphs are gone.

## 1.2.2 - S08: Follow-ups is a lane like the other three

- `Tasks board (page)` 1.0.1 → 1.0.2 (patch): in the sidebar layout the Follow-ups lane wears the status lanes' wash, keeps its amber dot and gains a dashed "Add follow-up" row; its first card lines up with the other lanes'. In the floating bar it stays classic, with a quiet "Add follow-up" at the leading edge like "Add task". The lane's style is now set on every render, so the first render (before the sidebar shell adopts the page) can no longer fix it in the classic shape.

## 1.2.1 - S09: the Done window moves into the Done lane

- `Tasks board (page)` 1.0.0 → 1.0.1 (patch): "Done · last 7 days" leaves the filter row in both layouts and its collapsed Filter menu. The Done lane's count reads "1 · last 7 days", and the List's done tasks sit under a "Done · last 7 days" group header.

## 1.2.0 - S10: the Morning briefing reads as prose

- `HelmContrast` 1.0.0 → 1.1.0 (minor): `quietLink(tintHex:theme:)` and `quietLinkDot(_:font:)`, the one recipe for a link inside prose (ink text, a dot in the target's hue, a faint hover underline).
- `MorningBriefingCard` 1.0.0 → 1.0.1 (patch): every clause is ink with a leading dot, the hover underline is faint, and only a bad state word ("overdue") keeps its colour. The same paragraph view draws Home's briefing card.

## 1.1.0 - S11: the Health card says one verdict

- `HelmRingGauge` 1.0.0 → 1.1.0 (minor): `configure(value:total:tint:)` takes an optional verdict tint for the arc.
- `HelmModuleCard` 1.0.0 → 1.1.0 (minor): the `.ring` and `.ringWithLines` bodies take an optional `tint`, which the arc and the title both paint.
- `StateVocabulary` 1.0.0 → 1.1.0 (minor): `StateWord.tint`, the colour a surface leads with for each state.
- `Home Health card` 1.0.0 → 1.0.1 (patch): the title is the worst verdict in its colour, the ring takes the same tint, the "1 failing" pill is gone, and the note adds "6 of 8 healthy, 1 not run yet".

## 1.0.0 - baseline (S01)

The kit as it stood at `30e26ac3`, minted by S01 of the 2026-11-17 UI/UX proposals.
Every component and every surface in `HelmKitVersion.swift` starts at 1.0.0.
`HelmKitVersionSelfTest` is new with it.

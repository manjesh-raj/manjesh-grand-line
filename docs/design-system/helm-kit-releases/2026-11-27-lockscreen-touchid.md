# 2026-11-27 - The lock screen's Touch ID button

The kit change behind design A on the lock screen (`fm/grandline-lockscreen-touchid-fallback`).

- `HelmIconButton` 1.1.0 → 1.2.0 (minor): a `.circle` reports zero alignment insets, so it lays out at exactly its side. A borderless `NSButton` carries top and bottom alignment insets, which drew every circle as an oval (the Secrets chest's Touch ID button, the lock screen's in-pill arrow). `joinsKeyViewLoop`, off by default, lets Tab reach the button while it is enabled even with Full Keyboard Access off, and never takes focus on a click - the `SceneGateHotspotView` rule. The lock screen's Touch ID button is its first user.

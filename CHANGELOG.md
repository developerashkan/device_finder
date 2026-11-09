## 0.2.0

**New: `Radar3DView`** — a holographic, perspective 3D radar.

* Orbit camera (drag with inertia, double-tap reset, idle auto-orbit),
  volumetric sweep with a light curtain, sweep pings (orb flash + ground
  ripple), depth-sorted light pillars and orbs, collision-free one-line labels
  with a per-size budget, confidence ellipses, range rings for distance-only
  devices, adaptive "nice" range, floating particle field.
* `RadarTarget` (+ `fromState` / `fromStates`), `Radar3DTheme.dark()` /
  `.light()`, `paintBackground`, tap-to-select, semantic summary, reduced
  motion support, labels use the host app's font.

**Engine — correctness and reliability**

* Per-observer filtering: every `observerId` gets its own fusion window and
  Kalman filter; anchors are ranged from their own observer. Previously every
  anchor received the same single-phone distance, so multi-anchor fixes were
  meaningless. (**Behavior change** — set `observerId` = anchor `id`.)
* One anchor / phone-only samples now mean distance-only (`fix == null`)
  instead of an invented position.
* Losing anchors keeps the last fix as `FixStatus.stale`; a stale estimate no
  longer reports a fresh fix; the proximity trend clears when stale.
* Mirror resolver: velocity used whole seconds (always 0 at 10 Hz); now uses
  microsecond timing with smoothed velocity.
* Name grouping: samples that arrived before `setInfo` no longer leave an
  orphan "ghost" device; renaming one member of a shared group keeps the
  others' data; devices without info expose their own id (never empty).
* `forget()` resolves grouped ids and removes stale mappings; new `clear()`,
  `applyProfile()`, `reloadProfiles()`, `deviceCount`.
* `tick()` notifies at most once per call; the Kalman filter is fed only when
  new samples arrive.
* NaN / infinite / absurd RSSI is rejected at the door; duplicate and
  out-of-order timestamps never move the Kalman state; confidence ellipses can
  no longer be NaN.
* Anchor changes are detected by position, not only id.

**Tools**

* `GeigerHaptics`: `stop()` silences immediately, ticks stop after 3 s without
  updates, injectable clock/tick for tests, `isRunning`.
* `FileProfileStore`: one corrupt entry no longer discards the rest; writes
  are serialized. The store is now web-safe (conditional `dart:io` import) —
  the package supports **web**.
* Stable, platform-identical hashing (exact 32-bit multiply; `String.hashCode`
  and plain multiplication differ on the web).

**Widgets & example**

* `RadarScene` keeps an exact fractional phase; `MultiRadarView` uses a stable
  bearing hash; `DeviceList` text ≥ 11 px and no doubled margins; muted text
  contrast raised to ≥ 4.5:1.
* New example "Finder" app: simulated room with hubs (no Bluetooth needed) and
  a Live BLE mode with permission / unavailable states, locate screen with
  proximity meter, stats, direction and haptics; dark and light themes;
  adaptive phone / wide layouts.
* Example fixes: builds from a fresh clone (published `device_finder_ble`),
  macOS Bluetooth entitlement + usage string, Android BLE feature optional,
  timers/subscriptions cancelled on dispose.
* README screenshots now render on GitHub and pub.dev (previous image URL
  pointed to a non-existent path).

Requires Flutter 3.29 / Dart 3.7.

## 0.1.4

* Updated app screenshot in README.

## 0.1.3

* Fix README screenshot rendering on pub.dev.

## 0.1.2

* Update README.

## 0.1.1

* Added app screenshot to README.

## 0.1.0

Initial release.

- Pure-Dart signal engine: Kalman filter, source fusion, path-loss distance
  estimation, Gauss–Newton trilateration with mirror-ambiguity resolution,
  geometric calibration with fit validation.
- Premium widget catalog: sweeping radar (lit sectors, confidence ellipse),
  signal meter, device list grouped by broadcast name.
- Zero-latency repaint architecture (mutate, never rebuild).
- Geiger haptics for eyes-free search.
- Offline calibration profiles (JSON file store, atomic writes).
- Hardware capability adaptation (connected-link preference, TxPower priors).

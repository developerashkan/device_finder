# ADR 0001 — Locked Tech Stack for `device_finder`

- **Status:** Accepted (Phase 0 synthesis — 2026-08-06)
- **Deciders:** Agent A (Platform), Agent B (Math/Fusion), Agent C (Visual), orchestrator
- **Inspiration sources (read at Phase 0):** `ben-z/findphone` (Swift BLE RSSI CLI), `p4r1ch4y/superfind` (particle-filter evolution), `flutter_blue_plus` @ 2.3.11 (source-verified), Flutter engine/docs.

## Context

We must ship a fully offline-capable BLE device tracking package to pub.dev with a premium radar UI. Hard constraints: near-zero latency (mutate, never rebuild), dependency-minimized, cross-platform (Android/iOS), and a math core that is verifiable in isolation.

## Decisions

### D1 — Package topology (dependency firewall)
`device_finder` (published) depends on **Flutter SDK only** for its UI; its signal engine imports **nothing but `dart:math` / `dart:async` / `dart:collection`**. BLE capture is an **optional, separately published** package `device_finder_ble` (depends on `flutter_blue_plus` ^2.3.11). Rationale: flutter_blue_plus is now commercially licensed; the core package must not be contaminated. Engine ↔ driver boundary is a pure data interface: `RssiSample(source, dbm, at)`.

### D2 — Rendering: `CustomPaint`, not shaders
Verdict: **standard `CustomPainter`/Canvas with discipline**. This workload (sweep beam, ~720 arc fills, one ellipse, gradient rings) is CPU/geometry-bound, not per-pixel-bound; `FragmentProgram` adds runtime shader compilation and per-pixel GPU cost with no win here. Locked rules (from Agent C, verified against docs + engine sources):
1. Never `saveLayer` in the frame loop; never `Opacity` widget — alpha in `Paint`.
2. Zero per-frame allocations: reuse `Paint`/paths/`Offset` lists; precompute.
3. `drawRawPoints` + preallocated `Float32List` for grid ticks/beam sampling.
4. No `clipPath`/`clipRRect` in the hot path; keep geometry inside the circle analytically.
5. Draw back-to-front (sectors → beam → rings → ellipse → labels).
6. Integer phase tracking for the beam (1/100° units), bucket = `phase ~/ bucketSize`, no float drift.

### D3 — Animation/repaint wiring (the liveness contract)
A **raw `Ticker`** (not `AnimationController.unbounded`) ticks a shared mutable `RadarScene`; every painter is constructed as `CustomPainter(scene) : super(repaint: scene)` with `shouldRepaint => false`; the scene `notifyListeners()`s after each tick (one ticker repaints *all* attached painters on the same frame). Live BLE data mutates scene fields + `notifyListeners()` directly — **`setState`/widget rebuilds are forbidden on the BLE hot path**. `isComplex` only if profiling shows raster-cache wins.

### D4 — Signal engine math (all numbers locked)
- Path loss: `d = 10^((Tx − R)/(10n))`, priors `Tx = −59 dBm @ 1 m`, `n = 2.8`; distance clamp `[0.5, 30]` m; `σ_d = (d·ln10/(10n))·σ_R`, `σ_R ≥ 1.5 dB`.
- Kalman (dB domain, state `[rssi, v]`): `q1 = 0.05 dB²/s`, `q2 = 0.09 dB²/s³`, `R = 9 dB²`; `dt` clamped `[0.001, 2]` s; `dt ≤ 0` → skip predict; `dt > 0.5` s → zero velocity, `P ← 4P`; expose `P11` for 95% CI.
- Trilateration: Gauss–Newton with Levenberg–Marquardt damping (λ₀=1e-3, ×10/÷10, clamp [1e-10,1e6]), weighted centroid init, stop at `‖Δ‖<1e-3 m` | RMS < 0.05 m | 20 iters; covariance `(JᵀWJ)⁻¹`; 95% ellipse = χ²₂=5.991 (semi-axis scale 2.447).
- N=2: closed-form circle intersection; degenerate → clamp projection onto baseline. Mirror ambiguity resolved by **movement-history scoring**: `S(c) = −[0.25·J² + 1.5·(1 − cos θ)]` with exponential-decay position prediction, flip hysteresis (margin > 1.0 for 2 consecutive updates; re-lock at margin > 3.0; fresh anchor set drops threshold to 0.25).
- Fusion: per-source ring buffers (span ≤ 2.5 s; minimum counts advert ≥ 2 / link ≥ 3); winner = freshest source with `σ ≤ 1.25·σ_best`; all-σ > 15 dB → freshest observation; none → no estimate.
- Staleness: `τ > 2.5 s` → stale flag (Kalman frozen, output held); `τ > 5 s` → windows dropped (ghost prevention); re-arm needs 3 fresh samples.
- Calibration: ≥ 50 samples per distance at 1/2/4/8 m, median per point, linear fit on `log10(d)` (`n = −β₁/10`, `Tx = β₀`); accept iff RMS ≤ 8 dB ∧ `1.5 ≤ n ≤ 4.5` ∧ `−85 ≤ Tx ≤ −35 dBm`; require ≥ 3 distances.
- Hardware adaptation: connected-link RSSI preferred when available (σ 4 dB vs advert σ 7 dB); advertised `TxPower` (AD 0x0A) used as free calibration reference when present, else priors.

### D5 — Identity
Group devices by **broadcast name** (user-visible), fall back to stable address → vendor/kind heuristics → "Unknown". Never treat rotating MACs as separate devices; raw address kept only as a `fingerprint` for profile lookup (and profiles are matched on the *name* fingerprint when addresses rotate).

### D6 — Haptics
Geiger-counter pattern: haptic interval ∝ distance (accelerating as target nears), on a dedicated throttled timer decoupled from the frame loop; `HapticFeedback.selectionClick()` granularity, never vibrate-heavy patterns.

### D7 — Offline profiles
Abstract `ProfileStore` (interface in core, so hosts can inject SQLite/shared_prefs/anything). Default `FileProfileStore` over `dart:io` (JSON, atomic write via temp+rename), **no network, no plugins**. Profile lookup is an in-memory cache loaded at engine start and on write — instant load on device detect.

### D8 — Testing gates
`flutter test` must pass before any phase is considered done. Star tests: (a) dogleg-walk mirror resolution with synthetic RSSI (σ=3 dB); (b) Kalman smoothness ≤ 5 dB RMS with clean signal; (c) calibration rejection on corrupt fit; (d) 3-anchor ellipse coverage ≥ 90% of 100 noisy trials; (e) staleness/ghost-drop timing.

## Consequences
Positive: zero runtime deps in core engine; swappable BLE drivers; testable math; pub.dev-friendly (workspaces, pana-clean structure, example app included). Negative: two packages to version/release; driver package is optional so users must add it explicitly (mitigated by README and a one-line `DeviceFinder.withDefaultDriver()` convenience in `device_finder_ble`).

# 03 · UX, GUI & Accessibility

_Worktree HEAD `e20dbfb`. Read-only audit._

**Verdict:** a genuinely well-crafted, opinionated app — far above template quality.
There's a real design system, pervasive haptics, thoughtful progressive disclosure,
strong empty/loading/error coverage, and reduce-motion handling where it counts. The
remaining gaps are a short, fixable list: Dynamic Type robustness, a scattering of
missing VoiceOver labels, one data-loss confirmation, no first-run onboarding, and
(strategically) alignment to iOS 26 Liquid Glass.

## Navigation & core flows

Home (`RootView`, path-bound `NavigationStack` over `AppRoute`) → primary **Spatial
Scan** card + **Scan Gallery** button + a 2-col "More tools" grid (Live Depth, Object
Capture, Room Plan, Model Studio, AR Viewer) → Settings gear. Deep links from
widget/Siri handled.

- **Scan** is a clean state machine (`idle/scanning/finishing → scanningSurface`,
  `reviewing → reviewSurface`): quality dial + coaching + orbit ring → Stop → review
  (viewer + preset row + collapsible tools drawer + action row: AR / Studio / Save /
  Export).
- **Gallery** is smartly reused as viewer, merge picker, place picker, and standalone
  AR viewer via `mergeKind`/`dismissOnSelect`/`title`.
- **State coverage is strong** — empty, search-empty, loading, error, and
  crash-recovery alerts are all handled; honest unsupported-device paths everywhere.

**Friction / gaps:**
- **No first-run onboarding or permission priming** (no first-launch flag anywhere) —
  the ARKit camera prompt fires cold on the first scan.
- **Conceptual overlap on home** — Spatial Scan's subtitle claims it scans "objects,
  rooms, areas" (`RootView.swift:30`), yet Object Capture and Room Plan are separate
  tiles with **no subtitles** (`:216`), so four scan-like modes aren't differentiable.
- **Title duplication** — `navigationTitle("Magic Camera")` (`:85`) + a 28 pt header
  "Magic Camera" (`:149`) on one screen.
- **Export is a tall action sheet** (up to 8 buttons for a textured mesh) — functional,
  not premium.
- **`CaptureQuality` segmented control has 5 tiers** — cramped/truncation-prone on a
  narrow iPhone.

## Design system & visual quality

**There is a real, centralized, consistently-used token system** (`Theme.swift`):
intentional palette (deliberately de-saturated periwinkle accent — the comments show
it was lowered in chroma because "the blue surfaces are aggressive"), a 4-step radius
scale, materials, gradients, and reusable modifiers/styles (`glassPanel`,
`appBackground`, `PressableCardStyle`, `PrimaryButtonStyle`, `GlassButtonStyle`). The
identical bottom-glass-panel layout across Scan/Review/Studio/LiveDepth gives a
coherent, premium "camera-dark glass" identity. Against the design-quality checklist
it hits hierarchy, depth/layering, semantic color, and designed press states —
opinionated, not generic.

**Token gaps (foundational — close before an iOS 26 pass):**
- **No spacing scale** — padding is hardcoded literals (8/10/12/14/16/18/20/24)
  everywhere. Add `Theme.space*`.
- **No typography tokens** — fonts inline (`.system(size: 28, weight: .heavy)`
  `RootView.swift:150`; fixed `.system(size:18/19)` in `Controls.swift:23`,
  `SpatialScanReviewTools.swift:918`). A named ramp centralizes this **and flags the
  fixed-point-size text that doesn't scale** (see Accessibility).
- **No motion tokens** — `spring(response:0.3, dampingFraction:0.7)` copy-pasted across
  all button styles; ad-hoc `easeInOut` scattered.
- **Elevation is a boolean** (`elevated:`), not a scale.

**vs. iOS 26 Liquid Glass:** philosophically close (already `.ultraThinMaterial`,
capsules, continuous corners) but it's **hand-rolled glass over a force-locked black
theme** (`MagicCameraApp.swift:43` `preferredColorScheme(.dark)`). The premium iOS 26
move is to adopt the native `.glassEffect()`/`GlassEffectContainer` APIs for controls
and let the glass be adaptive. Forced dark is defensible for a camera app, but it
should be a *decision* — today there's no light treatment at all. See
[05-tech-currency](05-tech-currency.md) for the deployment-target trade-off.

## Interaction polish — consistently designed, not default

- **Haptics are pervasive and graded** — `.heavy` on record, `.medium` on
  primary/commit, `.light` on toggles, on essentially every actionable control.
- **Press/active states everywhere** via `PressableCardStyle` + scale+opacity spring
  button styles; selected states flip fill+foreground.
- **Standout: the processing overlay** (`SpatialScanView.swift:191`) — a 350 ms grace
  delay so sub-second edits never flash a modal, a live `TimelineView` elapsed-time
  readout proving it isn't frozen, and a wired **Cancel** on every op. Best-in-class
  feedback.
- **Inline busy states** in buttons (spinner + "Isolating…/Reconstructing…") across
  the tools surface — the user always knows what's running.
- Rich purpose-built gestures (walk joystick, lasso, 3D ruler, cross-section clip
  shader, placement ghost, drag-to-aim relight).

## Accessibility

**Strengths:** Reduce Motion respected on the vestibular-heavy auto-orbits
(`MeshViewer.swift:291`, `MetalPointCloudView.swift:244`); the scan coaches are
exemplary (`accessibilityElement(children:.ignore)` + label + value); ~35
accessibility modifiers overall; black-on-accent contrast ≈ **6.1:1** (passes AA — the
accent-lightening paid off).

**Concrete gaps (file:line):**
- **No Dynamic Type hardening anywhere** — zero `dynamicTypeSize` usages. Custom
  controls use **fixed frames** (`Controls.swift:27` chip 66×56; compact tiles
  `RootView.swift:226`) and **fixed-point-size text** (`Controls.swift:23`
  `.system(size:18)`; `SpatialScanReviewTools.swift:918` `.system(size:19)`) that
  doesn't scale. At AX sizes, chip text clips/overflows. **Most important a11y item
  for submission.** (Native `Form`/`List` screens scale fine; risk is the custom
  camera surfaces.)
- **Icon-only buttons missing `accessibilityLabel`:** undo/redo
  (`SpatialScanView.swift:789`), auto-orbit toggle (`:887`), LiveDepth measure/undo
  (`LiveDepthCameraView.swift:97,126`), Studio ± steppers (`ModelStudioView.swift:588`
  — VoiceOver reads "minus / X / plus" with the axis only spatially associated).
- **Minor contrast:** small white-on-accent captions
  (`SpatialScanReviewTools.swift:518`, `white.opacity(0.82)` ≈ 3.4:1) — under AA for small text.

## Prioritized recommendations

**HIGH**
1. **Add a discard confirmation.** Review "New" (`SpatialScanView.swift:556`) calls
   `discard()` immediately — an unsaved scan is destroyed with no confirm and no
   in-session undo (crash-autosave only covers relaunch). Gate behind a
   `confirmationDialog` when the current result is unsaved.
2. **Harden Dynamic Type** — let custom chips/tiles grow (`ViewThatFits`/wrap),
   replace fixed-point-size *text* with semantic fonts, add a sensible
   `dynamicTypeSize(...accessibility3)` clamp on the dense HUDs. Hit `Controls.swift`,
   `SpatialScanReviewTools.swift`, `RootView.swift` tiles first.
3. **Fill the missing VoiceOver labels** above — low effort, real impact.

**MEDIUM**
4. **First-run onboarding + permission priming** — a 2–3 pane primer before the system
   camera prompt.
5. **Clarify the home mode taxonomy** — fold Object Capture / Room Plan under Spatial
   Scan or give the compact tiles one-line subtitles; remove the duplicated title.
6. **Replace the export action sheet** with a designed sheet grouped *3D model / point
   data / share link*, each with a one-line hint + file-size estimate.
7. **Extract spacing/type/motion tokens** into `Theme` — de-risks the Liquid Glass pass.

**LOW / STRATEGIC**
8. **iOS 26 Liquid Glass** — adopt native glass APIs for controls; make the theme
   adaptive rather than force-locked black.
9. **Home palette rhythm** — the primary Spatial Scan (warm red) sits above the Gallery
   (amber): two warm cards stacked. Give the primary the brand-blue `accentGradient` so
   it reads as *the* action.
10. Gate `RecordingDot`'s pulse on Reduce Motion (`Controls.swift:165`); fix the small
    white-on-accent caption contrast.

**Note:** scan review is power-user-dense even with excellent disclosure; the
hero-button + collapse strategy is the right mitigation and is well executed — keep
tuning copy/order rather than adding controls.

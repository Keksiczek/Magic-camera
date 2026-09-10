# What is worth taking from Apple's RoomPlan / ObjectCapture pipeline

_Written 2026-08-06, after the r88 device round. The question behind it: why is
Apple's object crop so much cleaner than ours, and how much of their published
pipeline can we actually use._

## The short verdict

**Skip the machine learning.** RoomPlan's architecture is public — a U-Net over a
bird's-eye semantic map for corners/edges, an SSD-style detector over per-wall
orthographic projections for doors and windows, a 3D conv U-Net over a voxelised
frustum for furniture. The *weights* are not, and none of it is reachable without
a training set of thousands of annotated rooms. Apple's own write-up concedes
this. Building the architecture without the data buys nothing.

**ObjectCapture is a black box by construction.** `PhotogrammetrySession` exposes
configuration, not algorithms. The only way to have "the same results as Apple"
is to call it — which the app already does, in two places.

What is left is small, cheap, and directly aimed at problems this app measurably
has.

## The thing that actually explains the crop quality

It is not their 3D reasoning. It is that **Apple segments in 2D, on every image,
and treats that as the answer** — and that their capture UI refuses to finish
until the user has orbited the subject, so "what is foreground" is never
ambiguous.

We already have that machinery: `SubjectMasker` lifts a Vision subject mask per
keyframe and `KeyframeSubjectFilter` intersects them into a visual hull. The
architecture is right. **The trust order is wrong.**

Today `isolateSubject` runs the mask first and then hands its output to
`PointCloudSegmenter.isolateSubjects`, which re-decides the question by
clustering — and clustering can, and twice did, overrule the mask and keep the
wrong part. Both flattening incidents in r87–r88 came from the cluster step, not
from the mask; the `isolate funnel` breadcrumb reads `→ mask → hull → cluster`
and the loss was always in the last term.

**Rule to adopt: when the mask had enough views to be evidence, it is the
subject. Geometry then only sheds detached specks — it does not get to choose
which body is the real one.** That is Apple's order, and it is the one failure
mode we keep paying for.

## The four items, in value order

_All four are in as of 2026-08-06 — none device-verified yet._

### 1. The mask outranks the clustering — done (`bffad51`)

When `KeyframeSubjectFilter` used at least `PointCloudVisibilityFilter.minViews`
worth of views, strip the support plane and then run `removeStrayClusters` —
which sheds floaters and explicitly refuses to cut more than half — instead of
seed-and-grow, which picks a winner. Seed-and-grow stays for the tapless and
thin-evidence cases, where there is nothing better.

### 2. `isObjectMaskingEnabled` — done

Neither `PhotogrammetrySession.Configuration` in this app sets it —
`GuidedObjectCapture` and `KeyframePhotogrammetry` both configure only
`sampleOrdering`. This is Apple's own foreground segmentation, i.e. literally the
mechanism behind the crop quality being admired.

Turn it on for `GuidedObjectCapture` (a turntable capture of one object) and
**not** for `KeyframePhotogrammetry`, whose input can be a room sweep where
masking the background would eat the walls. Set it explicitly either way so the
intent is in the code rather than in an SDK default.

### 3. The guidance signals (not the models) — done

Apple's scan-guidance nets are two-layer MLPs with tens of parameters — too small
to be doing anything clever. The value is in the *inputs*:

| hint | inputs |
|---|---|
| "Turn up the light" | mean luminance + ARFrame feature-point count |
| "Slow down" / "Move farther away" | 3D camera linear velocity + **2D projected velocity in image space** |

The projected velocity is the interesting one: 3D speed alone cannot tell "walking
briskly across a large room" (fine) from "waving the phone 20 cm from a mug"
(ruinous). The r88 Object scan logged `shake 22` — the gate fired and the user
was never told why. Three floats off `ARFrame`; no CoreML needed.

Shipped as `CaptureGuidance` (pure math) + `ScanRecorder.reportGuidance`. Two
details worth keeping straight: the hint is computed and reported **before** the
steadiness gate returns — reporting after it would coach only the frames that
were never in trouble — and it is held by a stabiliser for four frames in both
directions, so one jerk mid-orbit doesn't flash a pill. Both scan coaches rank
motion above their own progress copy, because a frame that fast is being dropped
outright.

### 4. Bird's-eye z-slicing occupancy map — done

The one part of RoomPlan that is not a neural net: project the cloud into a
512×512 grid, ~3 cm in XY and 30 cm in height, value = point density. Pure
geometry.

Worth it because it beats what we do now on its own terms. Wall finding runs
RANSAC over the raw cloud, and `FloorPlanBuilder` needs a **classified mesh** —
so a point scan without ARKit classification gets no plan at all. In a density
BEV, walls are vertical ridges a threshold can find, and the result is a better
set of seeds for plane snapping than random RANSAC triples.

Shipped as `OccupancyGrid`, feeding two places: `SurfaceCleanup` derives wall
seeds from it whenever the sweep carried fewer than two ARKit plane anchors
(anchors win when they exist — better evidence), and `FloorPlanBuilder` falls
back to it for scans with no classification. The diagnostics line now reads
`planes N (M seeded, K bev, L manhattan)`, so which source fed the flattening is
visible on a device round.

One thing the writeup does not warn about: **connected components do not work
here.** A closed room's walls touch at every corner, so a flood fill returns the
whole room as one blob that no single line fits, and the whole extraction returns
nothing. It is a Hough vote instead — each wall is found independently and no
code ever has to decide where a corner ends — with a PCA refit afterwards for
exact geometry, and a gap split so a doorway breaks a wall into two runs rather
than bridging them. Corner cells go to whichever wall is fitted first, so runs
come out about a band-width short at each end; harmless, and the tests pin it.

## What we are not doing, and why

- Room layout / door / window / furniture detection nets — no training data.
- Replacing `PhotogrammetrySession` with our own SfM/MVS — the article is right
  that it would not be 1:1, and we would be trading a maintained black box for an
  unmaintained one.
- Reimplementing ARKit's SLAM or semantic segmentation — not reachable.

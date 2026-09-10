# Magic Camera — what it is

*Written 2026-08-10. This is the one document that is allowed to be opinionated.*

## The one-line version

**A LiDAR scanner that hands you a finished model, not a point cloud and a
homework assignment.**

## What that means in practice

Apple gives every Pro iPhone a depth sensor and three good APIs — ARKit's scene
depth, RoomPlan, Object Capture — and then stops. The gap between "ARKit gave me
depth samples" and "here is a textured model I would actually show someone" is
where this app lives. Everything in the pipeline exists to close a specific part
of that gap, and anything that doesn't should be cut.

Three commitments follow from that, and they decide arguments:

**1. The finish is the product.** A user should not have to know what a voxel,
a chart, or a Manhattan frame is. The scan arrives, the recipe runs, and what
comes out is right. Manual tools exist for the cases the automatic path gets
wrong — they are the escape hatch, not the workflow. When an automatic step and
a manual step disagree about scope, the automatic one loses: it must be the safe
default.

**2. Nothing leaves the device.** Capture, reconstruction, texture bake, and the
on-device language model all run locally. iCloud sync is the user's own
container. This is not a privacy slogan bolted on afterwards — it is why the
whole pipeline is written in Metal and Swift instead of uploaded somewhere, and
it is the honest answer to "where do my scans of my flat go".

**3. The app tells the truth about what it did.** Every stage breadcrumbs what it
decided — points kept, points carved, planes flattened, texels spent, memory
left. The diagnostics export is a first-class feature, not developer leftovers.
Rounds r74 through r88 were all debugged from it, and the r88 round was solved
because the export could be laid next to the user's own scan files and compared.
A pipeline this deep with no instrumentation is a pipeline nobody can fix.

## Who it is for

Someone who wants a real measurement or a real model of a real space, on the
phone in their pocket, in a few minutes: a room before a renovation, a piece of
furniture before buying a rug, an object to print or drop into a scene. Not a
survey-grade professional (the sensor cannot honour that), and not a game
player. The bar is "good enough that you'd send it to someone", and the ceiling
is set by the LiDAR, not by our willingness to grind.

## What it refuses to be

- **A cloud service.** No accounts, no uploads, no "processing on our servers".
- **A parameter panel.** Every tuning knob that reaches the UI has to earn it by
  changing something the user can see and name. The rest lives in `ScanConfig`
  with a comment explaining what it cost to learn.
- **A viewer.** Importing and looking at models is table stakes; the value is in
  what the capture pipeline produces.
- **Honest-looking.** A model that is quietly wrong is worse than one that is
  visibly incomplete. A step that would delete the user's furniture, flatten
  their subject, or invent 59% of a texture must refuse and say so rather than
  ship something plausible.

## The quality ladder, in the order it binds

This is the ranking to reason with when deciding what to work on. Each rung is
only worth climbing once the one below it holds.

1. **Geometry is where the thing actually is.** Registration, drift, level.
2. **Geometry is complete.** No holes the user has to explain.
3. **Nothing was deleted that mattered.** Filters take tails, never bodies.
4. **The texture is photographed, not synthesised.**
5. **The model is small enough to share and open.**
6. **It looks intentional** — flat walls flat, square corners square.

r88 found faults at rungs 1, 3 and 4 simultaneously, which is why the round was
worth more than any feature would have been.

## How work gets decided

Measure first. Every fix that has held up came from a number — a fraction of
points on a lattice, a floor's tilt per quadrant, a repair count against a page
budget. Every fix that had to be reverted came from reasoning about the code
without one. When the user reports something, the first move is to get the scan
file, not to read the pipeline.

# Handoff — Activate the Multi-Page Texture Atlas

_Self-contained brief for a fresh session. Branch
`claude/cloud-mesh-postprocess-optimize-8cb455`, worktree
`/Users/keks/Developer/Magic-camera/.claude/worktrees/cloud-mesh-postprocess-optimize-8cb455`.
This is Tier-1 item 1.1 in [07-roadmap](07-roadmap.md) — the single highest-value
quality lever in the app._

## Goal

Roughly halve texture blur on large-room scans by baking the color atlas across
**multiple texture pages** instead of one. The unwrap already supports pages; the
bake, the in-memory model, the on-disk codec, and the exporters do not.

## Why (the ceiling)

Single-page atlas density is a pure **area accountant**:

```
capDensity (texels/metre) = maxTexSize · √(packEfficiency · pages / totalArea)
```

`ChartAtlas.swift:289-292` (`packEfficiency ≈ 0.65`). With `pages = 1`, an 8192²
atlas over a ~142 m² room is bounded at **~1.8 mm/texel even with a perfect
unwrap** — so room detail past ~cm that the geometry floor (28 mm) already pushed
into the texture is then blurred by the texture too. **N pages buy √N**: 4 pages →
~0.9 mm/texel (**~3.4×** the linear sharpness, because you also recover from the
current under-fill). Small objects are already at their density target, so paging is
a no-op for them (the code early-outs — `ChartAtlas.swift:293`).

## What is ALREADY built (do not rebuild)

`ChartAtlas.build(mesh:maxTexSize:minTexSize:targetTexelsPerMetre:maxPages:) -> Layout?`
(`ChartAtlas.swift:211`) fully supports paging:
- `maxPages: Int = 1` parameter — callers currently pin it to 1.
- `pageBudget(...)` picks the page count from area vs. target (`:289`).
- `pack(..., maxPages:)` spills charts across pages; `packing.pageCount`,
  `packing.pages[chartIndex]`, `packing.origins`, `packing.rotated` (`:299-323`).
- `Layout.pageOfTri: [UInt8]` — per-triangle page index, non-empty only when
  `pageCount > 1` (`:59-66`, populated at `:318,326`).

So the **UV layout + per-triangle page assignment already exist**. The gap is
everything downstream of the layout.

## What is NOT wired (the work)

1. **The bake produces one image.** `PhotoTextureBaker.bake` and
   `GPUTextureBaker.bakeMultiView` (`GPUTextureBaker.swift:194`) rasterise into a
   single atlas. For paging, bake **one image per page** (loop pages; each page bakes
   only the triangles whose `pageOfTri == page`, same multi-view blend), or bake N
   render targets. Output becomes `[Data]` (one PNG/JPEG per page) + the `pageOfTri`
   map.
2. **`TexturedMesh` holds a single atlas** — `struct TexturedMesh { mesh; uvs;
   texturePNG: Data; textureSize: Int }` (`MeshTextureBaker.swift:16`). Make it
   multi-page: `textures: [Data]`, `textureSize`, and a per-triangle (or per-vertex)
   `page: [UInt8]`. Keep a single-page convenience initializer so call sites that
   don't page are untouched.
3. **The on-disk codec is single-texture.** `MeshStore` v2 stores one texture block
   (`MeshStore.swift:41-100`). Add a **v3** that stores `pageCount` + N blocks + the
   page map; keep v2 **load** working (existing saved models must still open).
4. **Exporters emit one texture.** USDZ (`TexturedMeshExporter.writeUSDZ:145`, via
   SceneKit), GLB (`TexturedMeshExporter.glbData:42`, hand-rolled glTF), and the web
   viewer (`WebViewerExporter`) each bind one image. Multi-page needs **N materials**
   (one per page image) with each triangle assigned the material of its page — i.e.
   submesh/material-group per page. This is the largest export change; USDZ material
   groups and glTF `primitives[]` per material are the mechanisms.
5. **Viewers** — `MeshViewer` / `MetalPointCloudView` (SceneKit) likewise need
   per-page materials to display the textured result in-app.

## Recommended sequencing (land in 2 stages, low-risk)

**Stage 1 — plumbing at `pageCount = 1` (must be byte-identical to today).** Change
the model (`TexturedMesh` → arrays), the bake output, the codec (v3 write / v2+v3
read), the exporters and viewers to iterate pages — but keep all call sites passing
`maxPages: 1`. Verify a textured save/reload/export is unchanged (same bytes / same
render). This de-risks the whole change before any quality behavior shifts.

**Stage 2 — activate.** Pass `maxPages: 4` (device-tiered by `physicalMemory`, like
the existing atlas caps) from the **surface** bake call sites:
`PhotoTextureBaker.swift:100` (Build Surface) and `:360` (one-tap model). Leave the
cloud-color path (`MeshTextureBaker.swift:35`) and small objects at 1. Then validate.

## Do this FIRST and independently — JPEG atlas

The atlas is encoded **PNG** (`TextureAtlas.encodePNG:275`, via
`CGImageDestination`). A 4-page 8192² PNG atlas would bloat every save/export.
Switch atlas encoding to **JPEG** (`CGImageDestination` with `UTType.jpeg`,
quality ≈ 0.9) — USDZ and glTF both accept JPEG textures, and this shrinks files
~5–10× with no visible loss on photo-baked color. This is a small, self-contained
change that helps even at one page, so do it before Stage 2. (Keep PNG only if a
lossless path is ever needed.)

## Validation — MANDATORY, real device exports only

Per hard-won project history, **synthetic meshes have burned this 3×**. Validate
against **real device exports** (put PLYs/USDZ in `scratchpad/real`), and when
compiling the atlas/geometry type standalone, **dedupe double-sided faces first**.
Confirm: (a) Stage 1 output identical at 1 page; (b) big-room texel density up ~3.4×
with no chart-seam regression; (c) export file size controlled by JPEG; (d) peak GPU
/ memory during the per-page bake stays within budget (pages are baked one at a
time, so peak should not scale with page count — verify).

## Key files

- `MagicCamera/SpatialScan/ChartAtlas.swift` (unwrap + paging — already done)
- `MagicCamera/SpatialScan/AreaProportionalAtlas.swift` (fallback layout — same formula)
- `MagicCamera/SpatialScan/PhotoTextureBaker.swift` (bake; call sites `:100`, `:360`)
- `MagicCamera/SpatialScan/GPUTextureBaker.swift` (GPU multi-view blend → per-page)
- `MagicCamera/SpatialScan/MeshTextureBaker.swift` (`TexturedMesh` def `:16`; cloud path `:35`)
- `MagicCamera/SpatialScan/TextureAtlas.swift` (`encodePNG:275` → add JPEG)
- `MagicCamera/SpatialScan/MeshStore.swift` (v2 texture block → v3 multi-page)
- `MagicCamera/SpatialScan/TexturedMeshExporter.swift` (USDZ `:145` / GLB `:42`)
- `MagicCamera/SpatialScan/WebViewerExporter.swift`, `MeshViewer.swift` (viewers)

## Context to load first

- Project memory `scan-quality-session-2026-06.md` (r58/r59) has the original
  multi-page design notes and the ~10-file blast radius; `app-analysis-2026-07.md`
  has the summary. Read [02-scan-pipeline](02-scan-pipeline.md) §"texture bake".
- Workflow: work in this worktree; `xcodegen generate` after adding files; the
  generated `project.pbxproj` is committed (keep in sync); batch edits, build once at
  the end with `xcodebuild build` (skip tests); `git -C <worktree>` + absolute paths.

## Acceptance

Big-room textures visibly sharper (target ~0.9 mm/texel at 4 pages), no regression
at 1 page, saved models still open (v2 load), USDZ/GLB/web all render every page,
export size controlled by JPEG, device-verified on a real large-room scan.

# surfaces — the screens, and the ones with landmines

SwiftUI throughout, with UIKit/SceneKit/Metal representables where the content
demands it. `UI/Theme.swift` and `UI/Controls.swift` are the design system;
reach for them before styling anything locally.

## The screens

| Surface | File | Notes |
|---|---|---|
| Home | `App/RootView.swift` | mode entry; gated by `DeviceCapabilities` |
| Onboarding | `App/OnboardingView.swift` | once, first launch |
| Live Depth | `LiveDepth/LiveDepthCameraView.swift` + `MetalDepthView.swift` | `MTKView` representable; effects, measure, shutter, record |
| **Spatial Scan** | `SpatialScan/SpatialScanView.swift` | **1022 lines — see the landmine below** |
| Scan review tools | `SpatialScanReviewTools.swift`, `ReviewToolsCloud/Geometry/Mesh/Reconstruction.swift` | split out of the view precisely because the tools tree grew too deep |
| Capture setup | `CaptureOptionsPanel.swift`, `CaptureProfilePicker.swift` | shows the estimated point/memory cost before committing |
| Post-process | `PostProcessPanel.swift` | the `ScanRecipe` steps, switchable |
| Point cloud render | `MetalPointCloudView.swift` | Metal + eye-dome lighting, colour modes, lasso |
| Mesh render | `MeshViewer.swift`, `MeshSceneBuilder.swift` | SceneKit |
| AR | `ARViewerView.swift`, `ARQuickLookView.swift`, `RealityMeshPreview.swift` | Quick Look needs a SceneKit-written USDZ |
| Gallery | `ScanGalleryView.swift` | reads through `ScanLibrary` only |
| Measurements | `ScanMeasurementsView.swift` | from `ScanMetrics` |
| Floor plan | `FloorPlanView.swift` | + PDF export |
| Export | `ExportSheet.swift` | shows the byte cost per format from `ExportPresets` |
| Model Studio | `Studio/ModelStudioView.swift` | 757 lines — watch its growth |
| RoomPlan | `RoomPlan/RoomPlanScan.swift`, `RoomCombinedView.swift` | |
| Object Capture | `ObjectCapture/ObjectCaptureEntry.swift`, `GuidedObjectCapture.swift` | Apple's guided photogrammetry |
| Sensors | `Capabilities/CapabilitiesView.swift` | honest live report; nothing faked |
| Settings | `UI/SettingsView.swift` | includes **Diagnostics export** and the sample-confidence kill switch |
| Storage | `UI/StorageManagerView.swift` | footprint per model |
| Unsupported | `UI/UnsupportedView.swift` | non-LiDAR devices land here, never on a degraded scan |

## The landmines

**`SpatialScanView` is at the type checker's limit.** Its tools tree has crashed
Swift's *type-metadata instantiation* — a stack overflow, not a slow build — and
the diagnostic names `body`, never your lines. **Extend it by extracting a
nominal sub-`View`**: a `struct SomethingPanel: View`, not another modifier and
not another `@ViewBuilder` closure. The `ReviewTools*` files exist for exactly
this reason; add to them rather than to `body`.

**SceneKit swaps `scnView.pointOfView` under `allowsCameraControl`.** The walk
camera must re-assert `pointOfView = cameraNode` (`OrbitCamera` `.walk`) or the
joystick moves a node that is not on screen.

**SceneKit is soft-deprecated by Apple.** It is still the right choice for the
review viewers today; do not start new surfaces on it without a reason, and
`RealityMeshBuilder` / `RealityMeshPreview` are the RealityKit path when one is
needed.

**Localisation: `Text("a" + "b")` produces no key.** SwiftUI keys a `Text` on
its *literal*, so any concatenation, interpolation-built label or
programmatically assembled string ships English silently. `LocalizationTests`
guards the table, not the call sites. Roughly 62 `showToast` strings are known
to still be English.

**Cancel heavy work when the app backgrounds.** `handleEnterBackground` on the
scan view cancels review-time reconstruction and bake; without it the
"failed to terminate" watchdog kills the app. Any new long-running review
operation must join that path — and must go through `runOperation`, so it
completes exactly once.

**Every review-time operation goes through `runOperation`.** Not doing so leaks
a spinner or applies a superseded result over a newer one.

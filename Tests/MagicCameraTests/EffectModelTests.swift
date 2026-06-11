import XCTest
import simd
@testable import MagicCamera

final class EffectModelTests: XCTestCase {
    // The C `EffectType` enum imports as UInt32; DepthEffectKind is Int32.
    // Retired gimmick effects (outline/fog/normals) keep their shader slots,
    // so the remaining cases must still line up with their explicit values.
    func testEffectKindRawValuesMatchShaderEnum() {
        XCTAssertEqual(DepthEffectKind.none.rawValue, Int32(EffectTypeNone.rawValue))
        XCTAssertEqual(DepthEffectKind.heatmap.rawValue, Int32(EffectTypeHeatmap.rawValue))
        XCTAssertEqual(DepthEffectKind.bokeh.rawValue, Int32(EffectTypeBokeh.rawValue))
        XCTAssertEqual(DepthEffectKind.relight.rawValue, Int32(EffectTypeRelight.rawValue))
        XCTAssertEqual(DepthEffectKind.portrait.rawValue, Int32(EffectTypePortrait.rawValue))
        XCTAssertEqual(DepthEffectKind.colorPop.rawValue, Int32(EffectTypeColorPop.rawValue))
        XCTAssertEqual(DepthEffectKind.depthGrade.rawValue, Int32(EffectTypeDepthGrade.rawValue))
    }

    func testParameterFlagsPerEffect() {
        XCTAssertTrue(DepthEffectKind.bokeh.usesFocusDistance)
        XCTAssertFalse(DepthEffectKind.heatmap.usesFocusDistance)
        XCTAssertTrue(DepthEffectKind.heatmap.usesDepthRange)
        XCTAssertTrue(DepthEffectKind.relight.usesLightDirection)
        XCTAssertFalse(DepthEffectKind.none.usesIntensity)
    }

    func testUniformsCarrySettings() {
        var settings = EffectSettings()
        settings.kind = .heatmap
        settings.fogDensity = 1.25   // still part of the uniform layout
        settings.intensity = 0.7
        let context = FrameUniformContext(
            viewToImage: matrix_identity_float3x3,
            depthTexel: SIMD2<Float>(0.01, 0.02),
            depthIntrinsics: SIMD4<Float>(100, 100, 50, 40),
            depthSize: SIMD2<Float>(256, 192),
            hasSegmentation: false)
        let u = settings.uniforms(context: context)
        XCTAssertEqual(u.effect, Int32(EffectTypeHeatmap.rawValue))
        XCTAssertEqual(u.fogDensity, 1.25, accuracy: 1e-5)
        XCTAssertEqual(u.intensity, 0.7, accuracy: 1e-5)
        XCTAssertEqual(u.depthTexel.x, 0.01, accuracy: 1e-5)
        XCTAssertEqual(u.depthIntrinsics.x, 100, accuracy: 1e-5)
        XCTAssertEqual(u.depthSize.y, 192, accuracy: 1e-5)
    }

    /// The default relight direction must match the pre-elevation behaviour
    /// (azimuth 0 → light from the right at ~37° — the old fixed (0.8, 0, -0.6)).
    func testDefaultRelightDirectionUnchanged() {
        var settings = EffectSettings()
        settings.kind = .relight
        let u = settings.uniforms(context: .identity)
        XCTAssertEqual(u.lightDir.x, 0.8, accuracy: 0.01)
        XCTAssertEqual(u.lightDir.y, 0.0, accuracy: 0.01)
        XCTAssertEqual(u.lightDir.z, -0.6, accuracy: 0.01)
    }
}

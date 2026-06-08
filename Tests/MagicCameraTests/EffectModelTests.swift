import XCTest
import simd
@testable import MagicCamera

final class EffectModelTests: XCTestCase {
    // The C `EffectType` enum imports as UInt32; DepthEffectKind is Int32.
    func testEffectKindRawValuesMatchShaderEnum() {
        XCTAssertEqual(DepthEffectKind.none.rawValue, Int32(EffectTypeNone.rawValue))
        XCTAssertEqual(DepthEffectKind.heatmap.rawValue, Int32(EffectTypeHeatmap.rawValue))
        XCTAssertEqual(DepthEffectKind.bokeh.rawValue, Int32(EffectTypeBokeh.rawValue))
        XCTAssertEqual(DepthEffectKind.outline.rawValue, Int32(EffectTypeOutline.rawValue))
        XCTAssertEqual(DepthEffectKind.fog.rawValue, Int32(EffectTypeFog.rawValue))
        XCTAssertEqual(DepthEffectKind.normals.rawValue, Int32(EffectTypeNormals.rawValue))
        XCTAssertEqual(DepthEffectKind.relight.rawValue, Int32(EffectTypeRelight.rawValue))
    }

    func testParameterFlagsPerEffect() {
        XCTAssertTrue(DepthEffectKind.bokeh.usesFocusDistance)
        XCTAssertFalse(DepthEffectKind.fog.usesFocusDistance)
        XCTAssertTrue(DepthEffectKind.fog.usesFogDensity)
        XCTAssertTrue(DepthEffectKind.heatmap.usesDepthRange)
        XCTAssertTrue(DepthEffectKind.relight.usesLightAzimuth)
        XCTAssertFalse(DepthEffectKind.none.usesIntensity)
    }

    func testUniformsCarrySettings() {
        var settings = EffectSettings()
        settings.kind = .fog
        settings.fogDensity = 1.25
        settings.intensity = 0.7
        let context = FrameUniformContext(
            viewToImage: matrix_identity_float3x3,
            depthTexel: SIMD2<Float>(0.01, 0.02),
            depthIntrinsics: SIMD4<Float>(100, 100, 50, 40),
            depthSize: SIMD2<Float>(256, 192))
        let u = settings.uniforms(context: context)
        XCTAssertEqual(u.effect, Int32(EffectTypeFog.rawValue))
        XCTAssertEqual(u.fogDensity, 1.25, accuracy: 1e-5)
        XCTAssertEqual(u.intensity, 0.7, accuracy: 1e-5)
        XCTAssertEqual(u.depthTexel.x, 0.01, accuracy: 1e-5)
        XCTAssertEqual(u.depthIntrinsics.x, 100, accuracy: 1e-5)
        XCTAssertEqual(u.depthSize.y, 192, accuracy: 1e-5)
    }
}

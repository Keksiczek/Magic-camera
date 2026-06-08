//
//  SensorInfo.swift
//  Magic Camera
//
//  Builds an honest report of what the running device actually supports:
//  ARKit capabilities, motion sensors and physical cameras. No faked sensors.
//

import ARKit
import AVFoundation
import CoreMotion

struct SensorItem: Identifiable {
    let id = UUID()
    let name: String
    let available: Bool
    let detail: String?

    init(_ name: String, _ available: Bool, _ detail: String? = nil) {
        self.name = name
        self.available = available
        self.detail = detail
    }
}

struct SensorSection: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    let items: [SensorItem]
}

enum SensorInfo {
    static func sections() -> [SensorSection] {
        [arKit(), cameras(), motion()]
    }

    // MARK: - ARKit

    private static func arKit() -> SensorSection {
        let videoFormats = ARWorldTrackingConfiguration.supportedVideoFormats
        let maxRes = videoFormats.map { $0.imageResolution }
            .max { $0.width * $0.height < $1.width * $1.height }
        let resDetail = maxRes.map { "\(Int($0.width))×\(Int($0.height))" }

        var items: [SensorItem] = [
            SensorItem("World tracking", ARWorldTrackingConfiguration.isSupported),
            SensorItem("LiDAR scene depth", DeviceCapabilities.supportsSceneDepth,
                       DeviceCapabilities.supportsSceneDepth ? "ARKit sceneDepth" : "Not available"),
            SensorItem("Smoothed depth", DeviceCapabilities.supportsSmoothedSceneDepth),
            SensorItem("Mesh reconstruction", DeviceCapabilities.supportsSceneReconstruction),
            SensorItem("People occlusion", DeviceCapabilities.supportsPersonSegmentation),
            SensorItem("Face tracking", ARFaceTrackingConfiguration.isSupported),
            SensorItem("Body tracking", ARBodyTrackingConfiguration.isSupported),
            SensorItem("Geo tracking", ARGeoTrackingConfiguration.isSupported),
            SensorItem("Max video format", !videoFormats.isEmpty, resDetail),
        ]
        items.append(SensorItem("Supported video formats", !videoFormats.isEmpty,
                                "\(videoFormats.count) formats"))
        return SensorSection(title: "ARKit", systemImage: "arkit", items: items)
    }

    // MARK: - Cameras

    private static func cameras() -> SensorSection {
        let backTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .builtInUltraWideCamera,
            .builtInTelephotoCamera, .builtInLiDARDepthCamera
        ]
        let back = AVCaptureDevice.DiscoverySession(
            deviceTypes: backTypes, mediaType: .video, position: .back).devices
        let front = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTrueDepthCamera, .builtInWideAngleCamera],
            mediaType: .video, position: .front).devices

        func has(_ type: AVCaptureDevice.DeviceType, in devices: [AVCaptureDevice]) -> Bool {
            devices.contains { $0.deviceType == type }
        }

        let items: [SensorItem] = [
            SensorItem("Wide camera", has(.builtInWideAngleCamera, in: back)),
            SensorItem("Ultra-wide camera", has(.builtInUltraWideCamera, in: back)),
            SensorItem("Telephoto camera", has(.builtInTelephotoCamera, in: back)),
            SensorItem("LiDAR depth camera", has(.builtInLiDARDepthCamera, in: back)),
            SensorItem("TrueDepth (front)", has(.builtInTrueDepthCamera, in: front)),
        ]
        return SensorSection(title: "Cameras", systemImage: "camera.aperture", items: items)
    }

    // MARK: - Motion

    private static func motion() -> SensorSection {
        let manager = CMMotionManager()
        var items: [SensorItem] = [
            SensorItem("Accelerometer", manager.isAccelerometerAvailable),
            SensorItem("Gyroscope", manager.isGyroAvailable),
            SensorItem("Magnetometer", manager.isMagnetometerAvailable),
            SensorItem("Device motion (fused)", manager.isDeviceMotionAvailable),
            SensorItem("Barometer (rel. altitude)", CMAltimeter.isRelativeAltitudeAvailable()),
            SensorItem("Absolute altitude", CMAltimeter.isAbsoluteAltitudeAvailable()),
            SensorItem("Pedometer steps", CMPedometer.isStepCountingAvailable()),
        ]
        items.append(SensorItem("Attitude reference", manager.isDeviceMotionAvailable,
                                "Roll / pitch / yaw"))
        return SensorSection(title: "Motion", systemImage: "gyroscope", items: items)
    }
}

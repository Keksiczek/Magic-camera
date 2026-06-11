//
//  MediaSaver.swift
//  Magic Camera
//
//  Saves captured photos/videos to the photo library, requesting add-only
//  authorization. Async/await based, so callers stay on their own actor and
//  errors surface as a Bool result rather than being swallowed.
//

import Photos
import UIKit
import UniformTypeIdentifiers

enum MediaSaver {
    static func savePhoto(_ cgImage: CGImage) async -> Bool {
        let image = UIImage(cgImage: cgImage)
        guard await requestAddAuthorization() else { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    /// Saves ready-made PNG bytes as a photo asset. Used for cutouts: going
    /// through UIImage would re-encode to JPEG and flatten the alpha channel.
    static func savePNGData(_ data: Data) async -> Bool {
        guard await requestAddAuthorization() else { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.uniformTypeIdentifier = UTType.png.identifier
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: options)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    static func saveVideo(_ url: URL) async -> Bool {
        guard await requestAddAuthorization() else { return false }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    private static func requestAddAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status == .authorized || status == .limited)
            }
        }
    }
}

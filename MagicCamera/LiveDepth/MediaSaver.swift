//
//  MediaSaver.swift
//  Magic Camera
//
//  Saves captured photos/videos to the photo library, requesting add-only
//  authorization. Surfaces success/failure rather than swallowing errors.
//

import Photos
import UIKit

enum MediaSaver {
    static func savePhoto(_ cgImage: CGImage, completion: @escaping (Bool) -> Void) {
        let image = UIImage(cgImage: cgImage)
        requestAddAuthorization { granted in
            guard granted else { dispatchMain { completion(false) }; return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                dispatchMain { completion(success) }
            }
        }
    }

    static func saveVideo(_ url: URL, completion: @escaping (Bool) -> Void) {
        requestAddAuthorization { granted in
            guard granted else { dispatchMain { completion(false) }; return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, _ in
                dispatchMain { completion(success) }
            }
        }
    }

    private static func requestAddAuthorization(_ completion: @escaping (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            completion(status == .authorized || status == .limited)
        }
    }

    private static func dispatchMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

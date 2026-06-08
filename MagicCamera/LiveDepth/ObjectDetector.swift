//
//  ObjectDetector.swift
//  Magic Camera
//
//  Runs a set of model-free Vision requests over an ARKit captured image and
//  returns generic object boxes (objectness saliency) plus labelled people and
//  animals. No bundled CoreML model required; results are deduplicated and
//  capped. Runs synchronously on a background queue (Vision is heavy).
//

import CoreVideo
import Vision

final class ObjectDetector: @unchecked Sendable {
    private let minBoxArea: CGFloat = 0.004   // drop specks
    private let maxBoxArea: CGFloat = 0.92    // drop near-full-frame saliency
    private let iouThreshold: CGFloat = 0.55  // merge overlapping boxes

    func detect(pixelBuffer: CVPixelBuffer,
                orientation: CGImagePropertyOrientation,
                maxResults: Int = 8) -> [RawDetection] {
        let saliency = VNGenerateObjectnessBasedSaliencyImageRequest()
        let humans = VNDetectHumanRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: orientation, options: [:])
        try? handler.perform([saliency, humans, animals])

        var detections: [RawDetection] = []

        if let observation = saliency.results?.first as? VNSaliencyImageObservation,
           let objects = observation.salientObjects {
            for object in objects {
                detections.append(RawDetection(label: "Object",
                                               confidence: object.confidence,
                                               boundingBox: object.boundingBox))
            }
        }
        for observation in humans.results ?? [] {
            detections.append(RawDetection(label: "Person",
                                           confidence: observation.confidence,
                                           boundingBox: observation.boundingBox))
        }
        for observation in animals.results ?? [] {
            let label = observation.labels.first?.identifier.capitalized ?? "Animal"
            detections.append(RawDetection(label: label,
                                           confidence: observation.confidence,
                                           boundingBox: observation.boundingBox))
        }

        return prune(detections, maxResults: maxResults)
    }

    // MARK: - Filtering / NMS

    private func prune(_ detections: [RawDetection], maxResults: Int) -> [RawDetection] {
        let filtered = detections.filter {
            let area = $0.boundingBox.width * $0.boundingBox.height
            return area >= minBoxArea && area <= maxBoxArea
        }
        // Labelled detections win ties over generic "Object" at equal confidence.
        let sorted = filtered.sorted {
            if abs($0.confidence - $1.confidence) > 0.001 { return $0.confidence > $1.confidence }
            return ($0.label != "Object") && ($1.label == "Object")
        }

        var kept: [RawDetection] = []
        for candidate in sorted {
            if kept.contains(where: { iou($0.boundingBox, candidate.boundingBox) > iouThreshold }) {
                continue
            }
            kept.append(candidate)
            if kept.count >= maxResults { break }
        }
        return kept
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let interArea = intersection.width * intersection.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }
}

//
//  ARQuickLookView.swift
//  Magic Camera
//
//  Presents a USDZ file in AR Quick Look (QLPreviewController), which gives the
//  system "View in AR" experience — placing the captured mesh in the room.
//
//  The preview controller is *presented* from an invisible host controller
//  rather than embedded: QLPreviewController only shows its native Done button
//  when it has a presentingViewController, so embedding it directly in a
//  fullScreenCover left no way back. Done → previewControllerDidDismiss →
//  dismiss() closes the SwiftUI cover as well.
//

import QuickLook
import SwiftUI

struct ARQuickLookView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ARQuickLookPresenter(url: url, onDismiss: { dismiss() })
            .ignoresSafeArea()
            .background(Color.black)
    }
}

private struct ARQuickLookPresenter: UIViewControllerRepresentable {
    let url: URL
    let onDismiss: @MainActor @Sendable () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(url: url, onDismiss: onDismiss) }

    func makeUIViewController(context: Context) -> QLHostController {
        let host = QLHostController()
        host.view.backgroundColor = .black
        let coordinator = context.coordinator
        host.onFirstAppear = { [weak host] in
            guard let host else { return }
            let preview = QLPreviewController()
            preview.dataSource = coordinator
            preview.delegate = coordinator
            preview.modalPresentationStyle = .overFullScreen
            host.present(preview, animated: false)
        }
        return host
    }

    func updateUIViewController(_ controller: QLHostController, context: Context) {
        context.coordinator.url = url
    }

    /// Invisible black host whose only job is to present the preview once its
    /// view is in a window (presenting earlier silently fails).
    final class QLHostController: UIViewController {
        var onFirstAppear: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onFirstAppear?()
            onFirstAppear = nil
        }
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource,
                             QLPreviewControllerDelegate {
        var url: URL
        private let onDismiss: @MainActor @Sendable () -> Void

        init(url: URL, onDismiss: @escaping @MainActor @Sendable () -> Void) {
            self.url = url
            self.onDismiss = onDismiss
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }

        // QLPreviewControllerDelegate is a nonisolated protocol while the
        // data-source conformance makes this class @MainActor — so the delegate
        // callback is nonisolated and hops back explicitly (QL calls it on main).
        nonisolated func previewControllerDidDismiss(_ controller: QLPreviewController) {
            Task { @MainActor [onDismiss] in onDismiss() }
        }
    }
}

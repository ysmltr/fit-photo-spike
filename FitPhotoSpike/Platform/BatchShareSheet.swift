import SwiftUI
import UIKit

/// SwiftUI presents this controller as a sheet. The entire batch is passed as
/// file URLs; it does not decode the batch or save to Photos automatically.
struct BatchShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let session: AppSessionFiles?
    let onCompletion: (Bool) -> Void

    func makeUIViewController(context: Context) -> SharePresentationController {
        SharePresentationController(urls: urls, session: session, onCompletion: onCompletion)
    }

    func updateUIViewController(_ controller: SharePresentationController, context: Context) {}

    /// Present after the SwiftUI sheet's host has entered the window hierarchy.
    /// An explicit source anchor satisfies UIKit's iPad popover requirement.
    final class SharePresentationController: UIViewController, UIPopoverPresentationControllerDelegate {
        private let urls: [URL]
        // Keep app-owned files alive through system activity completion/dismissal.
        private let session: AppSessionFiles?
        private let onCompletion: (Bool) -> Void
        private var presentedShareSheet = false
        private var reportedCompletion = false

        init(urls: [URL], session: AppSessionFiles?, onCompletion: @escaping (Bool) -> Void) {
            self.urls = urls
            self.session = session
            self.onCompletion = onCompletion
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .systemBackground
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard !presentedShareSheet else { return }
            presentedShareSheet = true
            let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
            controller.completionWithItemsHandler = { [weak self] _, completed, _, _ in
                Task { @MainActor [weak self] in self?.complete(completed) }
            }
            if UIDevice.current.userInterfaceIdiom == .pad {
                controller.modalPresentationStyle = .popover
                controller.popoverPresentationController?.sourceView = view
                controller.popoverPresentationController?.sourceRect = CGRect(
                    x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
                controller.popoverPresentationController?.permittedArrowDirections = []
                controller.popoverPresentationController?.delegate = self
            }
            controller.presentationController?.delegate = self
            present(controller, animated: true)
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            complete(false)
        }

        private func complete(_ completed: Bool) {
            // UIKit can report both activity completion and dismissal. SwiftUI
            // must close its host sheet once, including an iPad outside tap.
            guard !reportedCompletion else { return }
            reportedCompletion = true
            onCompletion(completed)
        }
    }
}

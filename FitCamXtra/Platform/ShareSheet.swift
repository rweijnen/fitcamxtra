import SwiftUI
import UIKit

/// The system share sheet. Used instead of ShareLink because the log is shared
/// as a file, which has to be written first and then handed over.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// A file URL that can drive `.sheet(item:)`.
struct SharePayload: Identifiable {
    let url: URL
    var id: String { url.path }
}

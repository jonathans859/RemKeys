import SwiftUI

/// Shell for the per-tab "what does this screen do" sheet, opened from the
/// info button every tab carries at the top right. Content is provided by
/// the tab and adapts to the current settings (e.g. Virtual Input explains
/// slider gestures only while slider mode is on), so the explanation always
/// matches what the user's configuration actually does.
struct InfoSheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form { content }
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

/// The standard top-right toolbar info button.
struct InfoButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "info.circle")
        }
        .accessibilityLabel("About this screen")
        .accessibilityHint("Explains how this screen works")
    }
}

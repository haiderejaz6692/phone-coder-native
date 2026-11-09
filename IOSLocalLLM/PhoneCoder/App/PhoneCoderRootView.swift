import SwiftUI

struct PhoneCoderRootView: View {
    @State private var defaultSelection: PhoneCoderTab = .server
    private let selection: Binding<PhoneCoderTab>?

    /// A supplied binding lets a parent control navigation. Otherwise the
    /// root owns mutable selection, starting on the center Server tab.
    init(selection: Binding<PhoneCoderTab>? = nil) {
        self.selection = selection
    }

    var body: some View {
        TabView(selection: selection ?? $defaultSelection) {
            ForEach(PhoneCoderTab.allCases) { tab in
                NavigationStack {
                    Text("Available in the next build")
                        .navigationTitle(tab.accessibilityLabel)
                        .navigationBarTitleDisplayMode(.inline)
                }
                .tabItem {
                    Label(tab.accessibilityLabel, systemImage: tab.systemImage)
                        .accessibilityLabel(tab.accessibilityLabel)
                }
                .tag(tab)
            }
        }
        .accessibilityIdentifier(PhoneCoderBuildManifest.current.bundleIdentifier + ".root")
    }
}

import SwiftUI

/// Persistent native tabs preserve each navigation stack and reserve their own safe area.
struct RootShellView: View {
    @StateObject private var libraryModel = LibraryViewModel()
    @StateObject private var learningModel = LearningViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var settings: ReaderSettingsStore
    @EnvironmentObject private var modelPrefs: AIModelPreferenceStore
    @State private var selectedTab: ShellTab = .library

    var body: some View {
        TabView(selection: $selectedTab) {
            LibraryView(model: libraryModel, learningModel: learningModel)
                .tabItem { Label("Library", systemImage: "books.vertical") }
                .tag(ShellTab.library)
            LearningView(model: learningModel)
                .tabItem { Label("Learning", systemImage: "lightbulb") }
                .tag(ShellTab.learning)
            NotebookView(model: libraryModel, learningModel: learningModel)
                .tabItem { Label("Notebook", systemImage: "bookmark") }
                .tag(ShellTab.notebook)
        }
        .tint(LRColor.accent)
        .onOpenURL { url in
            if url.scheme == "genbooks", url.host == "learning" {
                selectedTab = .learning
                return
            }
            selectedTab = .library
            Task { await libraryModel.handleIncomingURL(url) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, !learningModel.isLoading { learningModel.load() }
        }
        .task {
            learningModel.load()
            await libraryModel.load()
        }
    }
}

#Preview {
    RootShellView()
        .environmentObject(ReaderSettingsStore())
        .environmentObject(AIModelPreferenceStore())
}

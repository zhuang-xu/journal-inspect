import JournalCore
import SwiftUI

@main
struct JournalInspectApp: App {
    var body: some Scene {
        WindowGroup {
            ReaderView()
                .frame(minWidth: 960, minHeight: 720)
        }
    }
}

/// One composition root per window. Feature models share the same memory store.
@MainActor
enum JournalAppComposition {
    static func makeReader() -> ReaderViewModel {
        let cache = JournalEmbeddingCache()
        let store = PersonalMemoryStore(embeddingCache: cache)
        return ReaderViewModel(
            memory: MemoryViewModel(store: store),
            prompt: PromptViewModel(service: JournalPromptService(memoryStore: store, cache: cache))
        )
    }
}

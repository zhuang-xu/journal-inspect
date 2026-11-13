import Foundation

/// Resumable per-entry commits. Reads and model calls stay off the main actor.
public struct PersonalMemoryUpdater: Sendable {
    public let store: PersonalMemoryStore
    public let extractor: any PersonalMemoryExtracting
    public let sourceURL: URL
    public let indexDirectory: URL
    public init(
        store: PersonalMemoryStore, extractor: any PersonalMemoryExtracting,
        sourceURL: URL = JournalReader().sourceURL,
        indexDirectory: URL = JournalMetadataStore.defaultDirectory
    ) {
        self.store = store
        self.extractor = extractor
        self.sourceURL = sourceURL
        self.indexDirectory = indexDirectory
    }
    public func update(
        forceExtraction: Bool = false, progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws {
        let entries = try await journalWorker {
            let index = try JournalMetadataStore(directory: indexDirectory)
            var entries: [JournalEntry] = []
            var offset = 0
            repeat {
                try Task.checkCancellation()
                let page = try index.browse(limit: 500, offset: offset)
                entries += page.entries
                guard let next = page.nextOffset else { break }
                offset = next
            } while true
            return entries
        }
        let generation = try await store.beginUpdate(entries: entries)
        var report = MemoryBuildReport(totalEntries: entries.count)
        try await store.recordBuild(report, generation: generation)
        do {
            for (i, entry) in entries.enumerated() {
                try Task.checkCancellation()
                let text: String
                do {
                    text = try await journalWorker {
                        try JournalReader(sourceURL: sourceURL).openEntry(
                            uuid: entry.uuid, sourceID: entry.sourceID
                        ).text
                    }
                } catch let error as JournalReaderError where error.code == "entry_unavailable" {
                    report.unavailableEntries += 1
                    report.completedEntries += 1
                    progress(i + 1, entries.count)
                    continue
                }
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    report.nonemptyEntries = (report.nonemptyEntries ?? 0) + 1
                }
                report.decodedTextBytes = (report.decodedTextBytes ?? 0) + text.utf8.count
                let needsExtraction =
                    forceExtraction
                    ? true
                    : try await store.needsUpdate(
                        entry: entry, revision: memoryRevision(text),
                        version: extractor.processingVersion)
                if needsExtraction {
                    do {
                        var candidates: [MemoryCandidate] = []
                        // Commit only after all bounded passages and source validation succeed.
                        for passage in Self.passages(text) {
                            try Task.checkCancellation()
                            candidates += try await extractor.extract(from: passage)
                            guard candidates.count <= 12 else {
                                throw PersonalMemoryError.invalidCandidate
                            }
                        }
                        let current = try await journalWorker {
                            try JournalReader(sourceURL: sourceURL).openEntry(
                                uuid: entry.uuid, sourceID: entry.sourceID
                            ).text
                        }
                        guard memoryRevision(current) == memoryRevision(text) else {
                            throw PersonalMemoryError.staleUpdate
                        }
                        try Task.checkCancellation()
                        try await store.replace(
                            entry: entry, text: text, candidates: candidates,
                            version: extractor.processingVersion, generation: generation)
                        report.extractedEntries += 1
                        report.candidateCount += candidates.count
                        if candidates.isEmpty {
                            report.zeroCandidateEntries = (report.zeroCandidateEntries ?? 0) + 1
                        }
                    } catch PersonalMemoryError.invalidCandidate {
                        // Bad output from one entry must not prevent reading the rest of history.
                        // Leave its revision uncheckpointed so a subsequent run can retry it.
                        report.failedEntries = (report.failedEntries ?? 0) + 1
                    }
                } else {
                    report.unchangedEntries += 1
                }
                report.completedEntries += 1
                if report.completedEntries % 10 == 0 {
                    try await store.recordBuild(report, generation: generation)
                }
                progress(i + 1, entries.count)
            }
            try Task.checkCancellation()
            report.status = (report.failedEntries ?? 0) == 0 ? .completed : .failed
            report.finishedAt = Date()
            try await store.recordBuild(report, generation: generation)
        } catch {
            report.status = error is CancellationError ? .cancelled : .failed
            report.finishedAt = Date()
            try? await store.recordBuild(report, generation: generation)
            throw error
        }
    }

    private static func passages(_ text: String) -> [String] {
        var result: [String] = []
        var part = ""
        for scalar in text.unicodeScalars {
            if part.utf8.count + scalar.utf8.count > 3000 {
                result.append(part)
                part = ""
            }
            part.unicodeScalars.append(scalar)
        }
        if !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(part) }
        return result
    }
}

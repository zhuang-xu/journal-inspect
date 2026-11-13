import Foundation

extension LocalEmbeddingModel {
    /// Fixed locations only: no directory scan, download, or inference during discovery.
    public static var defaultModelURL: URL? {
        var directories = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support/JournalInspect/Models", isDirectory: true)
        ]
        if let resources = Bundle.main.resourceURL {
            directories.append(resources.appendingPathComponent("Models", isDirectory: true))
        }
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        directories.append(checkout.appendingPathComponent("Models", isDirectory: true))
        return directories.lazy.map { $0.appendingPathComponent(modelFilename) }.first { url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            return values?.isRegularFile == true
                && FileManager.default.isReadableFile(atPath: url.path)
        }
    }
}

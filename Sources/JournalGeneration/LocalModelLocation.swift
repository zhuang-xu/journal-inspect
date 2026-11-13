import Foundation

extension LocalAnswerModel {
    /// Locate weights without loading them or reading private Journal content.
    /// The source-relative fallback supports running this checkout from Xcode.
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
        return findModel(in: directories)
    }

    static func findModel(in directories: [URL]) -> URL? {
        // Prefer the larger model across all known locations; retain the baseline for manual comparison.
        for model in GenerationModel.allCases {
            if let url = directories.lazy.map({ $0.appendingPathComponent(model.filename) }).first(
                where: { url in
                    let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                    return values?.isRegularFile == true
                        && FileManager.default.isReadableFile(atPath: url.path)
                })
            {
                return url
            }
        }
        return nil
    }
}

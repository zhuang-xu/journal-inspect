import Darwin
import Foundation

/// Shared filesystem policy only; each store owns its schema and SQLite configuration.
enum PrivateStoreFile {
    static func prepare(in directory: URL, named filename: String) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try require(
            try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
            "Private store directory must not be a symbolic link.")
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let url = directory.appendingPathComponent(filename)
        // Restrict existing files too, before SQLite opens them or creates sidecars.
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        try require(descriptor >= 0, "Cannot open private store file.")
        defer { close(descriptor) }
        var attributes = stat()
        try require(
            fstat(descriptor, &attributes) == 0 && attributes.st_mode & S_IFMT == S_IFREG,
            "Private store must be a regular file.")
        try require(fchmod(descriptor, 0o600) == 0, "Cannot restrict private store permissions.")
        return url
    }
}

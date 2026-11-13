import CryptoKit
import Foundation

/// Rejects incompatible weights before invoking native code. Reads in bounded chunks.
enum ModelVerification {
    static func verify(_ url: URL) throws -> GenerationModel {
        guard let file = try? FileHandle(forReadingFrom: url) else {
            throw GenerationError.modelUnavailable
        }
        defer { try? file.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            hash.update(data: data)
        }
        let checksum = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard let model = GenerationModel.allCases.first(where: { $0.sha256 == checksum }) else {
            throw GenerationError.modelUnavailable
        }
        return model
    }
}

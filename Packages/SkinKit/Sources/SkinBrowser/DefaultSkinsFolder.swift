import Foundation
import SkinLibrary

/// `~/Roadie/Skins`: the skins folder Roadie creates when none is configured (#0169).
public enum DefaultSkinsFolder {
    public static let relativePath = "Roadie/Skins"

    public static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: relativePath, directoryHint: .isDirectory)
    }

    /// Creates the folder (intermediates included) if missing; returns it. A file in the way or a failure throws.
    @discardableResult
    public static func ensure(at url: URL, fileManager: FileManager = .default) throws -> URL {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw CocoaError(.fileWriteFileExists, userInfo: [NSURLErrorKey: url]) }
            return url
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// True when the folder holds no `.wsz` at any depth, or can't be read.
    public static func hasNoSkins(_ url: URL) -> Bool {
        guard let files = try? FolderScanner.list(folder: url) else { return true }
        return files.isEmpty
    }
}

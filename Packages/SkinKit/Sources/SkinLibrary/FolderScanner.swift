import Foundation

/// Lists a skins folder into `FileStamp`s.
public enum FolderScanner {
    public static func list(folder: URL, extensions: Set<String> = ["wsz"]) throws -> [FileStamp] {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SkinLibraryError.folderUnreadable("not a folder")
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { throw SkinLibraryError.folderUnreadable("cannot enumerate") }
        // `resolvingSymlinksInPath` drops a leading /private (/var/folders/…) while the enumerator may report it, so
        // accept either spelling of the root.
        var prefixes = [root.path]
        let real = root.path.withCString { realpath($0, nil) }
        if let real {
            prefixes.append(String(cString: real))
            free(real)
        }
        prefixes = Array(Set(prefixes)).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        var stamps: [FileStamp] = []
        for case let url as URL in enumerator {
            guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.path
            guard let prefix = prefixes.first(where: { path.hasPrefix($0) }) else { continue }
            stamps.append(
                FileStamp(
                    path: String(path.dropFirst(prefix.count)),
                    size: Int64(values.fileSize ?? 0),
                    mtime: values.contentModificationDate?.timeIntervalSince1970 ?? 0))
        }
        stamps.sort { $0.path < $1.path }
        return stamps
    }
}

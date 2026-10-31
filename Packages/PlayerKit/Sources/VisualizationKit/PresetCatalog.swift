import Foundation

/// The presets the window can choose from: the classics plus `.milk` files found in folders (design §5.1).
public enum PresetCatalog {
    public static let classics: [VisualizationPreset] = ClassicStyle.allCases.map(VisualizationPreset.classic)

    /// `*.milk` files (any case) and `*.milkpreset` bundles under `folder`, recursively; hidden files skipped.
    /// A missing or unreadable folder gives `[]`. Names only, so cheap, but call it off the main actor.
    public static func scan(folder: URL, source: VisualizationPreset.Source,
                            fileManager: FileManager = .default) -> [VisualizationPreset] {
        let root = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let rootComponents = root.pathComponents
        var found: [VisualizationPreset] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let accepted: Bool
            if ext == "milkpreset" {
                accepted = isDirectory
                if isDirectory { enumerator.skipDescendants() }
            } else {
                accepted = ext == "milk" && !isDirectory
            }
            guard accepted else { continue }
            let components = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            guard components.count > rootComponents.count,
                  Array(components.prefix(rootComponents.count)) == rootComponents else { continue }
            let relative = components.dropFirst(rootComponents.count).joined(separator: "/")
            found.append(.milk(url: url, relativePath: relative, source: source))
        }
        return found
    }

    /// The app's bundled presets (#0258): `scan(folder:source: .bundled)`, named by the folder's `gallery.json`
    /// (`categories[].presets[]` with `file` and `title`) where it names them, else by file name. A missing or
    /// unreadable gallery leaves the file names. Call it off the main actor.
    public static func bundled(in folder: URL, fileManager: FileManager = .default) -> [VisualizationPreset] {
        let presets = scan(folder: folder, source: .bundled, fileManager: fileManager)
        let titles = galleryTitles(at: folder.appending(path: "gallery.json"))
        guard !titles.isEmpty else { return presets }
        return presets.map { preset in
            guard let url = preset.url, let title = titles[url.lastPathComponent] else { return preset }
            var named = preset
            named.name = title
            return named
        }
    }

    private struct Gallery: Decodable {
        struct Category: Decodable { var presets: [Entry] }
        struct Entry: Decodable {
            var file: String
            var title: String?
        }
        var categories: [Category]
    }

    /// `file` → `title` from a MilkDropMetalKit `gallery.json`; empty when it's missing or can't be read.
    private static func galleryTitles(at url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url), let gallery = try? JSONDecoder().decode(Gallery.self, from: data)
        else { return [:] }
        var titles: [String: String] = [:]
        for entry in gallery.categories.flatMap(\.presets) {
            if let title = entry.title, !title.isEmpty { titles[entry.file] = title }
        }
        return titles
    }

    /// Classics first in style order, then by natural name order, ties by id.
    public static func ordered(_ presets: [VisualizationPreset]) -> [VisualizationPreset] {
        func rank(_ preset: VisualizationPreset) -> Int? {
            if case .classic(let style) = preset.kind { return ClassicStyle.allCases.firstIndex(of: style) }
            return nil
        }
        return presets.sorted { a, b in
            switch (rank(a), rank(b)) {
            case let (x?, y?): return x != y ? x < y : a.id < b.id
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                switch a.name.localizedStandardCompare(b.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return a.id < b.id
                }
            }
        }
    }
}

import CoreGraphics
import Foundation

/// The Quick Look preview document for a `.wsz`: an HTML page with the main window at 4x as a `cid:main` PNG
/// attachment, the skin's warnings and its readme. Pure and headless (no AppKit); never throws.
public struct SkinPreviewPage: Sendable {
    /// File name without extension.
    public let title: String
    /// Complete document.
    public let html: String
    /// "main" -> PNG; absent on the failure page.
    public let attachments: [String: Data]

    static let readmeLimit = 20 * 1024
    private static let nonReadmeNames: Set<String> = ["viscolor.txt", "pledit.txt", "region.txt"]

    /// Parses and renders; on failure returns a "Can't preview" page with the `SkinError` text.
    public static func make(url: URL, limits: SkinArchive.Limits = .default) -> SkinPreviewPage {
        let title = url.deletingPathExtension().lastPathComponent
        let archive: SkinArchive
        let skin: Skin
        do {
            archive = try SkinArchive(url: url, limits: limits)
            skin = try SkinParser.parse(archive: archive)
        } catch {
            return failure(title: title, reason: "\(error)")
        }
        let image = MainWindowRenderer.render(skin: skin, state: .idle, scale: 4)
        guard let png = PNGWriter.data(image) else { return failure(title: title, reason: "Could not render the skin") }

        var body = "<h1>\(htmlEscaped(title))</h1>\n"
        body += "<img src=\"cid:main\" width=\"550\" height=\"232\" style=\"image-rendering: pixelated\" alt=\"\">\n"
        if !skin.warnings.isEmpty {
            body += "<ul class=\"warnings\">\n" + skin.warnings.map { "<li>\(htmlEscaped($0))</li>\n" }.joined() + "</ul>\n"
        }
        if let readme = readme(in: archive) {
            body += "<pre>\(htmlEscaped(readme))</pre>\n"
        }
        return SkinPreviewPage(title: title, html: document(title: title, body: body), attachments: ["main": png])
    }

    private static func failure(title: String, reason: String) -> SkinPreviewPage {
        let body = "<h1>Can't preview \(htmlEscaped(title))</h1>\n<p>\(htmlEscaped(reason))</p>\n"
        return SkinPreviewPage(title: title, html: document(title: title, body: body), attachments: [:])
    }

    private static func document(title: String, body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(htmlEscaped(title))</title>
        <style>
        body { font: 13px -apple-system, sans-serif; margin: 20px; color: #222; background: #fff; }
        h1 { font-size: 17px; margin: 0 0 12px; }
        img { display: block; margin-bottom: 12px; }
        pre { white-space: pre-wrap; font: 12px ui-monospace, Menlo, monospace; }
        .warnings { color: #a15c00; }
        @media (prefers-color-scheme: dark) { body { color: #ddd; background: #1e1e1e; } .warnings { color: #e0a040; } }
        </style></head><body>
        \(body)</body></html>
        """
    }

    /// The first `.txt` that is not a skin data file, preferring one whose name starts with "readme".
    static func readme(in archive: SkinArchive) -> String? {
        let names = archive.files.keys.filter { $0.hasSuffix(".txt") && !nonReadmeNames.contains($0) }.sorted()
        guard let name = names.first(where: { $0.hasPrefix("readme") }) ?? names.first, let data = archive.files[name] else { return nil }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
        guard !text.isEmpty else { return nil }
        guard text.utf8.count > readmeLimit else { return text }
        var cut = String(decoding: Array(text.utf8.prefix(readmeLimit)), as: UTF8.self)
        while cut.last == "\u{FFFD}" { cut.removeLast() }
        return cut + "…"
    }

    static func htmlEscaped(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

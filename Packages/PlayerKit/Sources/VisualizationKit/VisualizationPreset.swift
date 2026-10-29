import Foundation

/// The built-in visualizations drawn without MilkDrop (design §3.3).
public enum ClassicStyle: String, CaseIterable, Sendable {
    case spectrum, oscilloscope, spectrumAndScope, mirror, stereoScope

    public var title: String {
        switch self {
        case .spectrum: "Classic Spectrum"
        case .oscilloscope: "Classic Oscilloscope"
        case .spectrumAndScope: "Classic Spectrum and Scope"
        case .mirror: "Classic Mirror"
        case .stereoScope: "Classic Stereo Scope"
        }
    }
}

/// One entry the visualization window can show: a classic style or a `.milk` preset (design §3.1).
public struct VisualizationPreset: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case classic(ClassicStyle), milk }
    public enum Source: String, Hashable, Sendable { case builtIn, bundled, user }

    public var id: String
    public var name: String
    public var kind: Kind
    public var source: Source
    public var url: URL?

    public init(id: String, name: String, kind: Kind, source: Source, url: URL?) {
        self.id = id
        self.name = name
        self.kind = kind
        self.source = source
        self.url = url
    }

    /// id `classic:<raw>`, source `.builtIn`.
    public static func classic(_ style: ClassicStyle) -> VisualizationPreset {
        VisualizationPreset(id: "classic:\(style.rawValue)", name: style.title, kind: .classic(style), source: .builtIn, url: nil)
    }

    /// id `<source>:<relativePath>`; the name is the file name without `.milk` / `.milkpreset`.
    public static func milk(url: URL, relativePath: String, source: Source) -> VisualizationPreset {
        let file = (relativePath as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension.lowercased()
        let name = (ext == "milk" || ext == "milkpreset") ? (file as NSString).deletingPathExtension : file
        return VisualizationPreset(id: "\(source.rawValue):\(relativePath)", name: name, kind: .milk, source: source, url: url)
    }
}

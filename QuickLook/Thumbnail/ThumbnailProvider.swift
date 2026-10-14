import QuickLookThumbnailing
import SkinKit

/// Finder icons and gallery thumbnails for `.wsz`: the skin's main window, pixel-exact where it fits (#0043).
/// A skin that cannot be read returns the error, so Finder keeps the generic icon.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let skin: Skin
        do { skin = try SkinParser.parse(url: request.fileURL) } catch {
            handler(nil, error)
            return
        }
        let fit = ThumbnailFit.fit(maximumSize: request.maximumSize, minimumSize: request.minimumSize, scale: request.scale)
        let image = MainWindowRenderer.render(skin: skin, state: .idle, scale: fit.renderScale)
        let reply = QLThumbnailReply(contextSize: fit.contextSize) { context in
            context.interpolationQuality = fit.smooth ? .high : .none
            context.draw(image, in: fit.imageRect)
            return true
        }
        handler(reply, nil)
    }
}

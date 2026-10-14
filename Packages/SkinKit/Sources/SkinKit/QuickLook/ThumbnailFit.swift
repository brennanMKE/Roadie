import CoreGraphics

/// The size arithmetic the Quick Look thumbnail provider applies: the largest integer number of device pixels per
/// skin pixel that fits, so pixel art stays crisp; a smooth downscale only when even 1x does not fit.
public enum ThumbnailFit {
    public struct Result: Equatable, Sendable {
        /// Integer scale to ask the renderer for (at least 1).
        public var renderScale: Int
        /// Points; what `QLThumbnailReply` is created with.
        public var contextSize: CGSize
        /// Points; where to draw the render, centred in the context.
        public var imageRect: CGRect
        /// True only on the downscale path.
        public var smooth: Bool
    }

    /// `maximumSize` and `minimumSize` are points, `scale` is the request's device scale factor.
    public static func fit(
        maximumSize: CGSize, minimumSize: CGSize, scale: CGFloat, window: CGSize = MainWindowLayout.size
    ) -> Result {
        let scale = scale.isFinite && scale > 0 ? scale : 1
        let maxW = maximumSize.width.isFinite ? max(maximumSize.width, 1) : 1
        let maxH = maximumSize.height.isFinite ? max(maximumSize.height, 1) : 1
        let fit = min(maxW / window.width, maxH / window.height)
        let pixelScale = Int((fit * scale).rounded(.down))
        let renderScale: Int
        let image: CGSize
        let smooth: Bool
        if pixelScale >= 1 {
            renderScale = pixelScale
            image = CGSize(width: window.width * CGFloat(pixelScale) / scale, height: window.height * CGFloat(pixelScale) / scale)
            smooth = false
        } else {
            renderScale = 1
            image = CGSize(
                width: max((window.width * fit).rounded(), 1), height: max((window.height * fit).rounded(), 1))
            smooth = true
        }
        let minW = minimumSize.width.isFinite ? max(minimumSize.width, 0) : 0
        let minH = minimumSize.height.isFinite ? max(minimumSize.height, 0) : 0
        let context = CGSize(width: max(image.width, minW), height: max(image.height, minH))
        let rect = CGRect(
            x: (context.width - image.width) / 2, y: (context.height - image.height) / 2, width: image.width, height: image.height)
        return Result(renderScale: renderScale, contextSize: context, imageRect: rect, smooth: smooth)
    }
}

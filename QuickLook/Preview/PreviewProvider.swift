import QuickLookUI
import SkinKit
import UniformTypeIdentifiers

/// Space-bar preview for `.wsz`: an HTML page with the main window at 4x, warnings and the readme (#0043).
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 620, height: 560)) { reply in
            let page = SkinPreviewPage.make(url: url)
            reply.title = page.title
            reply.stringEncoding = .utf8
            reply.attachments = page.attachments.mapValues { QLPreviewReplyAttachment(data: $0, contentType: .png) }
            return Data(page.html.utf8)
        }
    }
}

import Foundation
import Testing

@testable import SkinBrowser
@testable import SkinLibrary

/// #0131: Move to Trash from the Skins window. The remover is a stub: no test touches the real Trash.
@MainActor
@Suite struct SkinTrashTests {
    private func load(_ model: SkinBrowserModel) async {
        model.appeared()
        #expect(await waitFor { model.phase == .loaded })
    }

    @Test func trashRemovesFileRowAndThumbnail() async {
        let remover = StubRemover()
        let (stub, _, model, thumbs) = makeModel(numbered(3), remover: remover)
        await load(model)
        let target = model.items[1]
        var notified = 0
        model.onTrashed = { notified += 1 }
        #expect(await model.moveToTrash(path: target.primaryPath, name: target.name))
        #expect(remover.trashed == [testFolder.appending(path: target.primaryPath)])
        #expect(await stub.removedPaths == [target.primaryPath])
        #expect(thumbs.removed == [target.hash])
        #expect(!model.items.contains { $0.id == target.id })
        #expect(notified == 1)
        #expect(model.trashError == nil)
        #expect(await waitFor { model.counts?.skins == 2 && model.items.count == 2 })
    }

    @Test func linkedDuplicateKeepsTheSkinAndItsThumbnail() async {
        let remover = StubRemover()
        let (stub, _, model, thumbs) = makeModel([record(1, "dup", fileCount: 2)], remover: remover)
        await stub.addPath("Other/dup.wsz", for: 1)
        await load(model)
        #expect(await model.moveToTrash(path: "Other/dup.wsz"))
        #expect(remover.trashed == [testFolder.appending(path: "Other/dup.wsz")])
        #expect(thumbs.removed.isEmpty)
        #expect(await stub.records.count == 1)
    }

    @Test func alreadyMissingFileIsJustDroppedFromTheIndex() async {
        let remover = StubRemover()
        remover.fail(with: CocoaError(.fileNoSuchFile))
        let (stub, _, model, _) = makeModel(numbered(2), remover: remover)
        await load(model)
        let target = model.items[0]
        #expect(await model.moveToTrash(path: target.primaryPath))
        #expect(await stub.removedPaths == [target.primaryPath])
        #expect(model.trashError == nil)
    }

    @Test func removerFailureShowsErrorAndKeepsTheRow() async {
        let remover = StubRemover()
        remover.fail(with: CocoaError(.fileWriteNoPermission))
        let (stub, _, model, thumbs) = makeModel(numbered(2), remover: remover)
        await load(model)
        let target = model.items[0]
        let ok = await model.moveToTrash(path: target.primaryPath, name: target.name)
        #expect(!ok)
        #expect(model.trashError?.contains(target.name) == true)
        #expect(await stub.removedPaths.isEmpty)
        #expect(thumbs.removed.isEmpty)
        #expect(model.items.count == 2)
    }

    @Test func pathOutsideTheFolderIsRefused() async {
        let remover = StubRemover()
        let (stub, _, model, _) = makeModel(numbered(1), remover: remover)
        await load(model)
        let ok = await model.moveToTrash(path: "../elsewhere/x.wsz")
        #expect(!ok)
        #expect(remover.trashed.isEmpty)
        #expect(await stub.removedPaths.isEmpty)
        #expect(model.trashError != nil)
    }

    @Test func applyingSkinIsNotUnapplied() async {
        let (_, applier, model, _) = makeModel(numbered(2))
        await load(model)
        let target = model.items[0]
        model.apply(target)
        #expect(await model.moveToTrash(path: target.primaryPath))
        #expect(applier.applied.count == 1)
    }
}

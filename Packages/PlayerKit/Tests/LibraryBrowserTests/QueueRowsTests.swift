import MusicBackendKit
import Testing
@testable import LibraryBrowser

struct QueueRowsSelectionTests {
    let speaker = OutputDevice.ID(rawValue: "speaker")
    let ma: BackendCapabilities = [.remoteOutputs, .localOutput, .queueEditing]
    let folder: BackendCapabilities = [.localOutput]

    @Test func thisMacOnTheLocalQueueIsLocal() {
        #expect(QueueRowsSelection.choose(output: OutputDevice.thisMacID, feed: .local, remoteCapabilities: ma) == .local)
    }

    @Test func thisMacOnTheMusicAssistantFeedIsTheWrappersRemoteQueue() {
        #expect(
            QueueRowsSelection.choose(output: OutputDevice.thisMacID, feed: .musicAssistant, remoteCapabilities: ma)
                == .remote(OutputDevice.thisMacID))
    }

    @Test func speakerIsItsRemoteQueue() {
        #expect(QueueRowsSelection.choose(output: speaker, feed: .local, remoteCapabilities: ma) == .remote(speaker))
    }

    @Test func folderBackendSpeakerIsEmpty() {
        #expect(QueueRowsSelection.choose(output: speaker, feed: .local, remoteCapabilities: folder) == .none)
    }
}

struct QueueRowsTests {
    @Test func rowTextJoinsArtistAndTitle() {
        let item = RemoteQueueItem(id: "a", index: 0, title: "Song", artist: "Band")
        #expect(QueueRows.rowText(item) == "Band - Song")
    }

    @Test func rowTextWithoutArtistIsTheTitle() {
        #expect(QueueRows.rowText(RemoteQueueItem(id: "a", index: 0, title: "Radio One")) == "Radio One")
        #expect(QueueRows.rowText(RemoteQueueItem(id: "a", index: 0, title: "Song", artist: "")) == "Song")
    }

    @Test func runningTimeCountsUnknownAsZero() {
        let items = [
            RemoteQueueItem(id: "a", index: 0, title: "A", duration: 100),
            RemoteQueueItem(id: "b", index: 1, title: "B", duration: nil),
            RemoteQueueItem(id: "c", index: 2, title: "C", duration: 50),
        ]
        let time = QueueRows.runningTime(items, selected: ["c", "b"])
        #expect(time.total == 150)
        #expect(time.selected == 50)
    }

    @Test func cropRemovesTheUnselected() {
        #expect(QueueRows.indicesToRemove(cropping: [1, 3], count: 5) == [0, 2, 4])
        #expect(QueueRows.indicesToRemove(cropping: [], count: 5) == [])
    }
}

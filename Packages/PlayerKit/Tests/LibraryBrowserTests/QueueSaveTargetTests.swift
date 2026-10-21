import LibraryBrowser
import MusicBackendKit
import Testing

struct QueueSaveTargetTests {
    let speaker = OutputDevice.ID(rawValue: "kitchen")
    let ma: BackendCapabilities = [.playlists, .remoteOutputs, .queueEditing]
    let folder: BackendCapabilities = [.localOutput]

    @Test func localQueueSavesToAFile() {
        #expect(QueueSaveTarget.choose(output: OutputDevice.thisMacID, feed: .local, capabilities: ma) == .file)
        #expect(QueueSaveTarget.choose(output: OutputDevice.thisMacID, feed: .local, capabilities: folder) == .file)
    }

    @Test func speakerSavesToMusicAssistant() {
        #expect(QueueSaveTarget.choose(output: speaker, feed: .local, capabilities: ma) == .remote(speaker))
    }

    @Test func thisMacOnTheMusicAssistantFeedSavesToMusicAssistant() {
        #expect(QueueSaveTarget.choose(output: OutputDevice.thisMacID, feed: .musicAssistant, capabilities: ma)
            == .remote(OutputDevice.thisMacID))
    }

    @Test func folderBackendOnASpeakerIsRefused() {
        #expect(QueueSaveTarget.choose(output: speaker, feed: .local, capabilities: folder) == .refused)
    }
}

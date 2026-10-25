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

    @Test func loadFollowsTheSameChoice() {
        let outputs = [OutputDevice.thisMacID, speaker]
        let feeds: [ThisMacFeed] = [.local, .musicAssistant]
        for output in outputs {
            for feed in feeds {
                for capabilities in [ma, folder] {
                    #expect(QueueSaveTarget.load(output: output, feed: feed, capabilities: capabilities)
                        == QueueSaveTarget.choose(output: output, feed: feed, capabilities: capabilities))
                }
            }
        }
        #expect(QueueSaveTarget.load(output: speaker, feed: .local, capabilities: ma) == .remote(speaker))
    }

    @Test func loadChoicesOnTheLocalQueueOfferTheLibraryWhenItHasPlaylists() {
        #expect(QueueSaveTarget.loadChoices(
            output: OutputDevice.thisMacID, feed: .local, capabilities: ma, libraryHasPlaylists: true)
            == [.libraryPlaylist, .file])
    }

    @Test func loadChoicesOnTheLocalQueueWithoutLibraryPlaylistsAreFileOnly() {
        #expect(QueueSaveTarget.loadChoices(
            output: OutputDevice.thisMacID, feed: .local, capabilities: folder, libraryHasPlaylists: false)
            == [.file])
    }

    @Test func loadChoicesOnAMusicAssistantQueueAreItsPlaylists() {
        for has in [true, false] {
            #expect(QueueSaveTarget.loadChoices(
                output: OutputDevice.thisMacID, feed: .musicAssistant, capabilities: ma, libraryHasPlaylists: has)
                == [.libraryPlaylist])
            #expect(QueueSaveTarget.loadChoices(output: speaker, feed: .local, capabilities: ma, libraryHasPlaylists: has)
                == [.libraryPlaylist])
        }
    }

    @Test func loadChoicesOnAnUnlistableSpeakerAreEmpty() {
        #expect(QueueSaveTarget.loadChoices(output: speaker, feed: .local, capabilities: folder, libraryHasPlaylists: true)
            == [])
    }
}

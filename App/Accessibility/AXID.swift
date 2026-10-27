/// Accessibility identifiers shared by the app and RoadieUITests (one string per control, never typed twice). Design:
/// docs/design/test-automation.md §3.2 (#0199).
enum AXID {
    enum Main {
        static let previous = "main.previous"
        static let play = "main.play"
        static let pause = "main.pause"
        static let stop = "main.stop"
        static let next = "main.next"
        static let eject = "main.eject"
        static let shuffle = "main.shuffle"
        static let repeatAll = "main.repeat"
        static let eq = "main.eq"
        static let playlist = "main.playlist"
        static let volume = "main.volume"
        static let balance = "main.balance"
        static let position = "main.position"
        static let time = "main.time"
        static let marquee = "main.marquee"
        static let kbps = "main.kbps"
        static let khz = "main.khz"
        static let stereo = "main.stereo"
        static let state = "main.state"
        static let visualizer = "main.visualizer"
        enum Title {
            static let menu = "main.title.menu"
            static let minimize = "main.title.minimize"
            static let shade = "main.title.shade"
            static let close = "main.title.close"
            static let all = [menu, minimize, shade, close]
        }
        enum Clutter {
            static let o = "main.clutter.o"
            static let a = "main.clutter.a"
            static let i = "main.clutter.i"
            static let d = "main.clutter.d"
            static let v = "main.clutter.v"
            static let all = [o, a, i, d, v]
        }
        /// Present whatever the state (the title buttons draw only on the key window, so they are listed apart).
        static let alwaysPresent = [
            previous, play, pause, stop, next, eject, shuffle, repeatAll, eq, playlist, volume, balance, position, time,
            marquee, kbps, khz, stereo, state, visualizer,
        ] + Clutter.all
        static let all = alwaysPresent + Title.all
    }

    enum EQ {
        static let on = "eq.on"
        static let auto = "eq.auto"
        static let presets = "eq.presets"
        static let preamp = "eq.preamp"
        static func band(_ i: Int) -> String { "eq.band.\(i)" }
        static let bands = (0..<10).map(band)
        static let levelPlus = "eq.level.plus"
        static let levelZero = "eq.level.zero"
        static let levelMinus = "eq.level.minus"
        static let graph = "eq.graph"
        static let titleShade = "eq.title.shade"
        static let titleClose = "eq.title.close"
        static let alwaysPresent = [on, auto, presets, preamp] + bands + [levelPlus, levelZero, levelMinus, graph]
        static let all = alwaysPresent + [titleShade, titleClose]
    }

    enum PL {
        static func row(_ i: Int) -> String { "pl.row.\(i)" }
        static let scrollbar = "pl.scrollbar"
        static let scrollUp = "pl.scroll.up"
        static let scrollDown = "pl.scroll.down"
        static let resize = "pl.resize"
        static let runningTime = "pl.runningTime"
        static let miniTime = "pl.miniTime"
        static let titleShade = "pl.title.shade"
        static let titleClose = "pl.title.close"
        enum Transport {
            static let previous = "pl.transport.previous"
            static let play = "pl.transport.play"
            static let pause = "pl.transport.pause"
            static let stop = "pl.transport.stop"
            static let next = "pl.transport.next"
            static let eject = "pl.transport.eject"
            /// In `PlaylistLayout.actionButtons` order.
            static let all = [previous, play, pause, stop, next, eject]
        }
        enum Menu {
            static let add = "pl.menu.add"
            static let rem = "pl.menu.rem"
            static let sel = "pl.menu.sel"
            static let misc = "pl.menu.misc"
            static let list = "pl.menu.list"
            static let buttons = [add, rem, sel, misc, list]
            /// Each skinned entry's sprite name to its identifier and label.
            static let entries: [String: (id: String, label: String)] = [
                "PLAYLIST_ADD_FILE": ("pl.menu.add.file", "Add File"),
                "PLAYLIST_ADD_DIR": ("pl.menu.add.dir", "Add Folder"),
                "PLAYLIST_ADD_URL": ("pl.menu.add.url", "Add URL"),
                "PLAYLIST_REMOVE_SELECTED": ("pl.menu.rem.selected", "Remove Selected"),
                "PLAYLIST_CROP": ("pl.menu.rem.crop", "Crop"),
                "PLAYLIST_REMOVE_ALL": ("pl.menu.rem.all", "Remove All"),
                "PLAYLIST_REMOVE_MISC": ("pl.menu.rem.misc", "Remove Misc"),
                "PLAYLIST_INVERT_SELECTION": ("pl.menu.sel.invert", "Invert Selection"),
                "PLAYLIST_SELECT_ZERO": ("pl.menu.sel.zero", "Select None"),
                "PLAYLIST_SELECT_ALL": ("pl.menu.sel.all", "Select All"),
                "PLAYLIST_FILE_INFO": ("pl.menu.misc.info", "File Info"),
                "PLAYLIST_SORT_LIST": ("pl.menu.misc.sort", "Sort List"),
                "PLAYLIST_MISC_OPTIONS": ("pl.menu.misc.options", "Misc Options"),
                "PLAYLIST_NEW_LIST": ("pl.menu.list.new", "New List"),
                "PLAYLIST_SAVE_LIST": ("pl.menu.list.save", "Save List"),
                "PLAYLIST_LOAD_LIST": ("pl.menu.list.load", "Load List"),
            ]
        }
        static let alwaysPresent = [scrollbar, scrollUp, scrollDown, runningTime, miniTime] + Transport.all
            + Menu.buttons
        static let all = alwaysPresent + [resize, titleShade, titleClose] + Menu.entries.values.map { $0.id }.sorted()
    }

    enum Shade {
        enum Main {
            static let previous = "shade.main.previous"
            static let play = "shade.main.play"
            static let pause = "shade.main.pause"
            static let stop = "shade.main.stop"
            static let next = "shade.main.next"
            static let eject = "shade.main.eject"
            static let position = "shade.main.position"
            static let time = "shade.main.time"
            static let visualizer = "shade.main.visualizer"
            static let all = [previous, play, pause, stop, next, eject, position, time, visualizer]
        }
        enum EQ {
            static let volume = "shade.eq.volume"
            static let balance = "shade.eq.balance"
            static let all = [volume, balance]
        }
        enum PL {
            static let title = "shade.pl.title"
            static let shade = "shade.pl.shade"
            static let close = "shade.pl.close"
            static let all = [title, shade, close]
        }
        static let all = Main.all + EQ.all + PL.all
    }

    enum Jump {
        static let search = "jump.search"
        static let table = "jump.table"
        static func row(_ i: Int) -> String { "jump.row.\(i)" }
        static let queue = "jump.queue"
        static let empty = "jump.empty"
        static let all = [search, table, queue, empty]
    }

    enum Library {
        static func sidebar(_ section: String) -> String { "library.sidebar.\(section)" }
        /// `kind` is artist, album, track or playlist; `id` a `MediaID` raw value, sanitised to [a-z0-9].
        static func row(_ kind: String, _ id: String) -> String { "library.row.\(kind).\(sanitised(id))" }
        static let output = "library.output"
        /// A Playlists group header (#0221): `kind` is mine, builtIn or the provider's name, sanitised.
        static func playlistGroup(_ kind: String) -> String { "library.playlists.group.\(kind == "builtIn" ? kind : sanitised(kind))" }
        // No `library.search`: SwiftUI's `.searchable` toolbar field takes no identifier; UI tests find it by role
        // (`app.searchFields.firstMatch`).
        static let all = [output]

        static func sanitised(_ raw: String) -> String {
            String(raw.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        }
    }

    enum Skins {
        static let source = "skins.source"
        static let filter = "skins.filter"
        static let random = "skins.random"
        static let refresh = "skins.refresh"
        // No `skins.museum.search`: the museum's `.searchable` toolbar field takes no identifier (found by role).
        /// Prefix of the existing per-skin `skins.museum.cell.<md5>` identifiers.
        static let museumCell = "skins.museum.cell"
        static let all = [source, filter, random, refresh]
    }

    static let probe = "state.probe"

    /// Every static identifier, for the uniqueness test.
    static let all: [String] =
        Main.all + EQ.all + PL.all + Shade.all + Jump.all + Library.all + Skins.all + [probe]
}

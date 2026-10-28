import AudioCore
import LibraryBrowser
import MusicBackendKit
import os
import SkinKit
import SwiftUI

extension Color {
    init(_ rgb: SkinKit.RGBColor) {
        self.init(.sRGB, red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }
}

/// Draws a sprite repeated to fill `size`, from the top-left corner, clipped. `Image.resizable(.tile)` with nearest
/// sampling keeps the skin's pixels crisp.
struct TiledSpriteImage: View {
    let skin: Skin
    let name: String
    let size: CGSize

    var body: some View {
        if let image = skin.image(for: name) {
            Image(decorative: image, scale: 1)
                .resizable(resizingMode: .tile)
                .interpolation(.none)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipped()
        } else {
            Color.clear.frame(width: size.width, height: size.height)
        }
    }
}

/// The playlist window's content: the skin drawn at the window's scale, or the same "No Skin Loaded" placeholder as the
/// player so the window is never blank. Dropped files and skins are added to the queue like on the player.
struct PlaylistView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        let full = model.playlist.layout.size
        let size = model.isPlaylistWindowShaded ? CGSize(width: full.width, height: PlaylistLayout.shadeHeight) : full
        Group {
            if let skin = model.skin {
                PlaylistWindowView(skin: skin)
                    .scaleEffect(model.scale, anchor: .topLeading)
                    .frame(width: size.width * model.scale, height: size.height * model.scale, alignment: .topLeading)
            } else {
                ContentUnavailableView {
                    Label("No Skin Loaded", systemImage: "paintpalette")
                } description: {
                    Text(model.placeholderText)
                } actions: {
                    Button("Open Skin…") { model.openSkin() }
                }
                .frame(width: size.width * model.scale, height: size.height * model.scale)
                .background(.windowBackground, in: .rect(cornerRadius: 8))
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.open(urls, replace: false)
        }
        .sheet(isPresented: Bindable(model).isPickingPlaylist) {
            PlaylistPickerSheet(library: model.library) { playlist in
                model.isPickingPlaylist = false
                if let playlist { model.loadPlaylist(playlist) }
            }
        }
    }
}

/// The playlist window in skin pixels. Geometry comes from `PlaylistLayout` (SkinKit, tested headless). This only
/// draws; track-list mouse and keyboard input and the resize corner are AppKit views over it (`PlaylistWindowOverlays`),
/// because `scaleEffect` cannot scale an `NSView` and SwiftUI gestures carry no click count or modifier keys.
struct PlaylistWindowView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    let skin: Skin

    var body: some View {
        if model.isPlaylistWindowShaded {
            PlaylistShadeView(skin: skin)
        } else {
            normalBody
        }
    }

    private var normalBody: some View {
        let layout = model.playlist.layout
        return ZStack(alignment: .topLeading) {
            Color(skin.playlistStyle.normalBackground)
            ForEach(Array(layout.topRow(selected: activeState == .key).enumerated()), id: \.offset) { _, piece in
                PieceView(skin: skin, piece: piece)
            }
            PieceView(skin: skin, piece: layout.leftTile)
            PieceView(skin: skin, piece: layout.rightTile)
            ForEach(Array(layout.bottomRow.enumerated()), id: \.offset) { _, piece in
                PieceView(skin: skin, piece: piece)
            }
            if let vis = layout.visualizerBackground {
                SpriteImage(skin: skin, name: "PLAYLIST_VISUALIZER_BACKGROUND").offset(x: vis.minX, y: vis.minY)
            }

            PlaylistTrackListView(skin: skin)
            PlaylistScrollBarView(skin: skin)
            PlaylistBottomView(skin: skin)
            PlaylistTitleButtons(skin: skin)
            PlaylistMenusView(skin: skin)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
        .dropDestination(for: MediaIDTransfer.self) { transfers, _ in model.appendDroppedLibraryItems(transfers) }
    }
}

/// One `PlaylistLayout.Piece` at its place.
struct PieceView: View {
    let skin: Skin
    let piece: PlaylistLayout.Piece

    var body: some View {
        Group {
            if piece.tiled {
                TiledSpriteImage(skin: skin, name: piece.sprite, size: piece.rect.size)
            } else {
                SpriteImage(skin: skin, name: piece.sprite)
            }
        }
        .offset(x: piece.rect.minX, y: piece.rect.minY)
    }
}

/// Close and shade. Like Webamp, a sprite shows only while the button is pressed: the bitmap already paints them.
struct PlaylistTitleButtons: View {
    let skin: Skin
    @Environment(PlayerModel.self) private var model
    @Environment(\.skinWindow) private var window

    var body: some View {
        let layout = model.playlist.layout
        ZStack(alignment: .topLeading) {
            // Like Webamp, the sprite shows only while the button is pressed.
            Button { model.togglePlaylistWindowShade() } label: { EmptyView() }
                .buttonStyle(TitleBarButtonStyle(skin: skin, name: nil, pressedName: "PLAYLIST_COLLAPSE_SELECTED"))
                .skinControl(AXID.PL.titleShade, label: "Shade")
                .offset(x: layout.shadeButton.minX, y: layout.shadeButton.minY)
            Button { window?.close() } label: { EmptyView() }
                .buttonStyle(TitleBarButtonStyle(skin: skin, name: nil, pressedName: "PLAYLIST_CLOSE_SELECTED"))
                .skinControl(AXID.PL.titleClose, label: "Close")
                .offset(x: layout.closeButton.minX, y: layout.closeButton.minY)
        }
    }
}

/// The rows. Input is handled by `PlaylistListInputView`.
struct PlaylistTrackListView: View {
    let skin: Skin
    @Environment(PlayerModel.self) private var model

    var body: some View {
        let playlist = model.playlist
        let style = skin.playlistStyle
        let area = playlist.layout.trackArea
        let font = PlaylistFont.font(for: style.font)
        ZStack(alignment: .topLeading) {
            ForEach(playlist.rows) { row in
                HStack(spacing: 0) {
                    Text(row.number + row.name)
                        .font(font).tracking(0.5)
                        .lineLimit(1).truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !row.marker.isEmpty {
                        Text(" " + row.marker)
                            .font(font).tracking(0.5)
                            .lineLimit(1).fixedSize()
                    }
                    Text(row.duration)
                        .font(font).tracking(0.5)
                        .lineLimit(1).fixedSize()
                        .padding(.trailing, playlist.layout.durationRightInset)
                }
                .foregroundStyle(Color(row.isCurrent ? style.current : style.normal))
                .frame(width: area.width, height: PlaylistLayout.rowHeight, alignment: .leading)
                .background(row.isSelected ? Color(style.selectedBackground) : Color.clear)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(AXID.PL.row(row.index))
                .accessibilityLabel(row.number + row.name)
                .accessibilityValue(row.accessibilityValue)
                .accessibilityAddTraits(row.isSelected ? .isSelected : [])
                .offset(y: CGFloat(row.position) * PlaylistLayout.rowHeight)
            }
        }
        .frame(width: area.width, height: area.height, alignment: .topLeading)
        .background(Color(style.normalBackground))
        .clipped()
        .offset(x: area.minX, y: area.minY)
    }
}

/// The scroll handle and its track (Webamp `VerticalSlider`): a press on the handle keeps the grab point, a press on
/// the track centres the handle.
struct PlaylistScrollBarView: View {
    let skin: Skin
    @Environment(PlayerModel.self) private var model
    @State private var grabOffset: CGFloat?

    var body: some View {
        let playlist = model.playlist
        let layout = playlist.layout
        let track = layout.scrollTrack
        ZStack(alignment: .topLeading) {
            SpriteImage(skin: skin, name: playlist.isDraggingScroll ? "PLAYLIST_SCROLL_HANDLE_SELECTED" : "PLAYLIST_SCROLL_HANDLE")
                .offset(y: layout.scrollHandleY(value: playlist.handleValue) - track.minY)
            Color.clear
                .frame(width: track.width, height: track.height)
                .contentShape(Rectangle())
                .skinDisplay(AXID.PL.scrollbar, label: "Scroll bar", value: String(format: "%.2f", playlist.handleValue))
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            guard !playlist.allTracksAreVisible else { return }
                            let y = value.location.y
                            if grabOffset == nil {
                                let handleTop = layout.scrollHandleY(value: playlist.handleValue) - track.minY
                                let onHandle = y >= handleTop && y < handleTop + PlaylistLayout.scrollHandleHeight
                                grabOffset = onHandle ? y - handleTop : PlaylistLayout.scrollHandleHeight / 2
                                playlist.isDraggingScroll = true
                            }
                            playlist.setScrollValue(
                                layout.scrollValue(forPointerY: y + track.minY, grabOffset: grabOffset ?? 0))
                        }
                        .onEnded { _ in
                            grabOffset = nil
                            playlist.isDraggingScroll = false
                        })
        }
        .frame(width: track.width, height: track.height, alignment: .topLeading)
        .offset(x: track.minX, y: track.minY)
    }
}

/// The bottom-right display and buttons: running time, mini time, six transport buttons, scroll arrows.
struct PlaylistBottomView: View {
    let skin: Skin
    @Environment(PlayerModel.self) private var model

    var body: some View {
        let playlist = model.playlist
        let layout = playlist.layout
        ZStack(alignment: .topLeading) {
            if let image = skin.textImage(playlist.runningTimeText) {
                Image(decorative: image, scale: 1).interpolation(.none)
                    .offset(x: layout.runningTimeOrigin.x, y: layout.runningTimeOrigin.y)
            }
            AXMarker(
                id: AXID.PL.runningTime, label: "Running time", value: playlist.runningTimeText.trimmingCharacters(in: .whitespaces),
                frame: CGRect(origin: layout.runningTimeOrigin, size: CGSize(width: 90, height: 6)))
            PlaylistMiniTimeView(skin: skin)

            // Previous, play, pause, stop, next, eject: invisible, the corner bitmap paints them.
            let actions: [() -> Void] = [
                { model.previous() }, { model.play() }, { model.pause() }, { model.stop() }, { model.next() }, { model.eject() },
            ]
            let labels = ["Previous", "Play", "Pause", "Stop", "Next", "Eject"]
            ForEach(Array(zip(layout.actionButtons, actions).enumerated()), id: \.offset) { index, pair in
                invisibleButton(pair.0, AXID.PL.Transport.all[index], labels[index], action: pair.1)
            }
            invisibleButton(layout.scrollUpButton, AXID.PL.scrollUp, "Scroll Up") { playlist.scroll(by: -4) }
            invisibleButton(layout.scrollDownButton, AXID.PL.scrollDown, "Scroll Down") { playlist.scroll(by: 4) }
        }
    }

    private func invisibleButton(_ rect: CGRect, _ id: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Color.clear.frame(width: rect.width, height: rect.height).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .skinControl(id, label: label)
        .offset(x: rect.minX, y: rect.minY)
    }
}

/// Five 5x6 text cells (Webamp `MiniTime`): a minus in remaining mode, then minutes and seconds; blank while stopped,
/// blinking while paused; a click toggles elapsed/remaining like the main window's time.
struct PlaylistMiniTimeView: View {
    let skin: Skin
    @Environment(PlayerModel.self) private var model

    var body: some View {
        RemoteClock(anchor: model.remoteClockAnchor) { content(at: $0) }
    }

    @ViewBuilder private func content(at now: Date) -> some View {
        let status = model.mainWindowStatus(at: now)
        let layout = model.playlist.layout
        let digits = status.digits
        let known = status.duration > 0 || status.timeMode == .elapsed
        let cells: [String] = [
            status.showsMinus ? "-" : " ",
            digit(known ? digits.minutesTens : nil), digit(known ? digits.minutesOnes : nil),
            digit(known ? digits.secondsTens : nil), digit(known ? digits.secondsOnes : nil),
        ]
        ZStack(alignment: .topLeading) {
            if status.blinksTime {
                BlinkingView { time(cells, layout) }
            } else {
                time(cells, layout)
            }
            Color.clear
                .frame(width: layout.miniTimeHitArea.width, height: layout.miniTimeHitArea.height)
                .contentShape(Rectangle())
                .onTapGesture(perform: model.toggleTimeMode)
                .skinDisplay(AXID.PL.miniTime, label: "Time", value: status.accessibility.time)
                .accessibilityAddTraits(.isButton)
                .offset(x: layout.miniTimeHitArea.minX, y: layout.miniTimeHitArea.minY)
        }
    }

    private func digit(_ value: Int?) -> String { value.map(String.init) ?? " " }

    private func time(_ cells: [String], _ layout: PlaylistLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                if let image = skin.textImage(cell) {
                    Image(decorative: image, scale: 1).interpolation(.none)
                        .offset(x: layout.miniTimeOrigin.x + PlaylistLayout.miniTimeCellXs[index], y: layout.miniTimeOrigin.y)
                }
            }
        }
    }
}

/// The five pop-up menus (Webamp `PlaylistMenu`): a press on the button toggles it, the entries stack upward from the
/// button with a bar beside them, an entry highlights on hover, a click runs it and closes the menu, and any press
/// elsewhere closes it.
struct PlaylistMenusView: View {
    let skin: Skin
    @Environment(PlayerModel.self) private var model
    @State private var hovered: String?

    var body: some View {
        let playlist = model.playlist
        let layout = playlist.layout
        ZStack(alignment: .topLeading) {
            if playlist.openMenu != nil {
                Color.clear
                    .frame(width: layout.size.width, height: layout.size.height)
                    .contentShape(Rectangle())
                    .onTapGesture { playlist.openMenu = nil }
            }
            ForEach(PlaylistLayout.Menu.allCases, id: \.self) { menu in
                let button = layout.menuButton(menu)
                if playlist.openMenu == menu {
                    let bar = layout.menuBar(menu)
                    SpriteImage(skin: skin, name: bar.sprite).offset(x: bar.rect.minX, y: bar.rect.minY)
                    ForEach(layout.menuEntries(menu), id: \.sprite) { entry in
                        let ax = AXID.PL.Menu.entries[entry.sprite] ?? (id: "pl.menu.unknown", label: entry.sprite)
                        SpriteImage(skin: skin, name: hovered == entry.sprite ? entry.sprite + "_SELECTED" : entry.sprite)
                            .frame(width: entry.rect.width, height: entry.rect.height, alignment: .topLeading)
                            .contentShape(Rectangle())
                            .accessibilityElement(children: .ignore)
                            .accessibilityAddTraits(.isButton)
                            .skinControl(ax.id, label: ax.label)
                            .onHover { inside in
                                if inside { hovered = entry.sprite } else if hovered == entry.sprite { hovered = nil }
                            }
                            .onTapGesture { run(entry.sprite) }
                            .offset(x: entry.rect.minX, y: entry.rect.minY)
                    }
                } else {
                    Color.clear
                        .frame(width: button.width, height: button.height)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .skinControl(menu.accessibilityID, label: menu.accessibilityLabel)
                        .help(menu.tooltip)
                        .onTapGesture { playlist.openMenu = menu }
                        .offset(x: button.minX, y: button.minY)
                }
            }
        }
    }

    /// Runs a skinned menu entry through `PlaylistMenu` (#0226). Sort List and Misc Options pop native menus at the
    /// pointer. A sprite can't be drawn disabled, so a disabled command does what it always did: nothing, or its notice.
    private func run(_ sprite: String) {
        let playlist = model.playlist
        switch sprite {
        case "PLAYLIST_SORT_LIST": PlaylistContextMenus.sort(model)
        case "PLAYLIST_MISC_OPTIONS": PlaylistContextMenus.miscOptions(model)
        default: if let command = PlaylistMenu.command(forSprite: sprite) { model.perform(command) }
        }
        hovered = nil
        playlist.openMenu = nil
    }
}

/// The playlist in shade mode: a 14 px strip as wide as the window. Left cap, tiled middle and right cap, the current
/// track's `n. name` and length in the text.bmp font, and the shade and close buttons (the width-only resize corner is an
/// AppKit view, `PlaylistResizeView`). Geometry is `PlaylistShadeLayout`.
struct PlaylistShadeView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.skinWindow) private var window
    let skin: Skin

    var body: some View {
        let width = model.playlist.layout.size.width
        let playlist = model.playlist
        let title = PlaylistShadeLayout.title(name: playlist.shadeTrackName, width: width)
        let time = playlist.shadeTrackName == nil ? "" : PlaylistShadeLayout.timeString(playlist.shadeTrackDuration)
        ZStack(alignment: .topLeading) {
            TiledSpriteImage(skin: skin, name: "PLAYLIST_SHADE_BACKGROUND", size: CGSize(width: width, height: PlaylistShadeLayout.height))
            SpriteImage(skin: skin, name: "PLAYLIST_SHADE_BACKGROUND_LEFT")
            SpriteImage(skin: skin, name: activeState == .key ? "PLAYLIST_SHADE_BACKGROUND_RIGHT_SELECTED" : "PLAYLIST_SHADE_BACKGROUND_RIGHT")
                .offset(x: width - PlaylistShadeLayout.rightWidth)
            if let image = skin.textImage(title) {
                Image(decorative: image, scale: 1).interpolation(.none)
                    .offset(x: PlaylistShadeLayout.titleOrigin.x, y: PlaylistShadeLayout.titleOrigin.y)
            }
            AXMarker(
                id: AXID.Shade.PL.title, label: "Current track", value: [playlist.shadeTrackName ?? "", time].joined(separator: " "),
                frame: CGRect(origin: PlaylistShadeLayout.titleOrigin, size: CGSize(width: 100, height: 6)))
            if let image = skin.textImage(time) {
                Image(decorative: image, scale: 1).interpolation(.none)
                    .offset(x: PlaylistShadeLayout.timeRightEdge(width: width) - CGFloat(image.width), y: PlaylistShadeLayout.timeY)
            }
            button(PlaylistShadeLayout.shadeFrame(width: width), AXID.Shade.PL.shade, "Unshade", pressed: "PLAYLIST_EXPAND_SELECTED") {
                model.togglePlaylistWindowShade()
            }
            button(PlaylistShadeLayout.closeFrame(width: width), AXID.Shade.PL.close, "Close", pressed: "PLAYLIST_CLOSE_SELECTED") {
                window?.close()
            }
        }
        .frame(width: width, height: PlaylistShadeLayout.height, alignment: .topLeading)
        .dropDestination(for: MediaIDTransfer.self) { transfers, _ in model.appendDroppedLibraryItems(transfers) }
    }

    private func button(_ rect: CGRect, _ id: String, _ label: String, pressed: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .buttonStyle(TitleBarButtonStyle(skin: skin, name: nil, pressedName: pressed))
            .skinControl(id, label: label)
            .offset(x: rect.minX, y: rect.minY)
    }
}

extension PlayerModel {
    private static let libraryDropLog = Logger(subsystem: "co.sstools.roadie", category: "LibraryDrop")

    /// The SwiftUI fallback for Library drops outside the AppKit track list (title bar, scroll bar, bottom bar, shade):
    /// the items are appended (#0188). false when there are no ids.
    func appendDroppedLibraryItems(_ transfers: [MediaIDTransfer]) -> Bool {
        let ids = transfers.flatMap(\.ids)
        guard !ids.isEmpty else { return false }
        Self.libraryDropLog.info("drop (SwiftUI): \(ids.count) id(s), appended")
        playFromLibrary(PlayRequest(items: ids, mode: .insert(at: playlist.count)))
        return true
    }
}

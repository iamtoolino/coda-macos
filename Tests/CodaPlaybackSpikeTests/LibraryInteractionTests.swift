import AppKit
import AudioToolbox
import Combine
import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("Library interactions")
@MainActor
struct LibraryInteractionTests {
  @Test("album rating updates are globally serialized")
  func albumRatingUpdatesAreGloballySerialized() throws {
    let session = AppSession(loadCredentials: false)
    let staleRequest = SessionRequestContext(
      client: NavidromeClient(
        configuration: try NavidromeConfiguration(
          server: "https://music.example.test",
          username: "listener",
          password: "secret"
        )),
      sessionID: UUID()
    )

    #expect(!session.isUpdatingAlbumRating)
    #expect(session.beginAlbumRatingUpdate())
    #expect(session.isUpdatingAlbumRating)
    #expect(!session.beginAlbumRatingUpdate())

    session.finishAlbumRatingUpdate(for: staleRequest)
    #expect(session.isUpdatingAlbumRating)

    session.finishAlbumRatingUpdate()

    #expect(!session.isUpdatingAlbumRating)
    #expect(session.beginAlbumRatingUpdate())
    session.finishAlbumRatingUpdate()
  }

  @Test("album collection sort options")
  func albumCollectionSortOptions() {
    #expect(AlbumCollectionKind.allCases == [
      .recentlyAdded,
      .recentReleases,
      .topRated,
      .mostPlayed,
      .recentlyPlayed,
      .alphabetical,
    ])
    #expect(AlbumCollectionKind.mostPlayed.apiValue == "frequent")
  }

  @Test("root navigation does not recreate the active collection")
  func activeRootNavigationPreservesCollection() {
    let session = AppSession(loadCredentials: false)
    let initialToken = session.rootToken

    session.selectRoot(.home)
    #expect(session.rootToken == initialToken)

    session.open(.album("album-1"))
    #expect(!session.path.isEmpty)
    session.selectRoot(.home)
    #expect(session.path.isEmpty)
    #expect(session.rootToken == initialToken)

    session.selectRoot(.albums)
    #expect(session.selectedRoot == .albums)
    #expect(session.rootToken != initialToken)
  }

  @Test("selecting Search recreates its canonical empty view")
  func selectingSearchRecreatesItsRoot() {
    let session = AppSession(loadCredentials: false)

    session.selectRoot(.search)
    let searchToken = session.rootToken
    session.open(.artist("artist-1"))

    session.selectRoot(.search)

    #expect(session.path.isEmpty)
    #expect(session.rootToken != searchToken)
  }

  @Test("album pages accept a trustworthy server total")
  func albumPageAcceptsTrustworthyServerTotal() {
    #expect(
      resolvedAlbumTotalCount(
        headerValue: " 1250 ",
        offset: 100,
        returnedCount: 100,
        requestedSize: 100
      ) == 1_250
    )
  }

  @Test("album pages infer their total from a short final page")
  func albumPageInfersTotalFromShortPage() {
    #expect(
      resolvedAlbumTotalCount(
        headerValue: nil,
        offset: 300,
        returnedCount: 42,
        requestedSize: 100
      ) == 342
    )
  }

  @Test("album pages reject missing and inconsistent totals")
  func albumPageRejectsUntrustworthyTotals() {
    #expect(
      resolvedAlbumTotalCount(
        headerValue: nil,
        offset: 0,
        returnedCount: 100,
        requestedSize: 100
      ) == nil
    )
    #expect(
      resolvedAlbumTotalCount(
        headerValue: "150",
        offset: 100,
        returnedCount: 100,
        requestedSize: 100
      ) == nil
    )
    #expect(
      resolvedAlbumTotalCount(
        headerValue: "not-a-number",
        offset: 0,
        returnedCount: 100,
        requestedSize: 100
      ) == nil
    )
  }

  @Test("library queue drag payload round trip")
  func libraryQueueDragPayloadRoundTrip() throws {
    let items = [
      LibraryQueueDragItem.artist("artist/1"),
      LibraryQueueDragItem.album("album/1"),
      LibraryQueueDragItem.albumDisc("album/1", discNumber: 3),
      LibraryQueueDragItem.playlist("playlist/1"),
      LibraryQueueDragItem.song(
        "song/1",
        canonicalAlbumArtworkID: "al-album-1_version"
      ),
      LibraryQueueDragItem.songs(
        ["song/2", "song/3"],
        canonicalAlbumArtworkID: "al-album-1_version"
      ),
    ]
    let data = try JSONEncoder().encode(items)
    #expect(try JSONDecoder().decode([LibraryQueueDragItem].self, from: data) == items)
  }

  @Test("older library queue drag payloads remain decodable")
  func olderLibraryQueueDragPayloadsRemainDecodable() throws {
    let data = Data(#"{"kind":"album","id":"album/1"}"#.utf8)
    let item = try JSONDecoder().decode(LibraryQueueDragItem.self, from: data)

    #expect(item == .album("album/1"))
    #expect(item.canonicalAlbumArtworkID == nil)
  }

  @Test("queue reorder drag payload round trip")
  func queueReorderDragPayloadRoundTrip() throws {
    let items = [
      QueueReorderDragItem.albumBlock([UUID(), UUID()]),
      QueueReorderDragItem.tracks([UUID(), UUID()]),
    ]
    let data = try JSONEncoder().encode(items)
    #expect(try JSONDecoder().decode([QueueReorderDragItem].self, from: data) == items)
  }

  @Test("unified queue drop payload round trip")
  func unifiedQueueDropPayloadRoundTrip() throws {
    let items = [
      QueueDropItem.library(.album("album/1")),
      QueueDropItem.reorder(.track(UUID())),
    ]
    let data = try JSONEncoder().encode(items)
    #expect(try JSONDecoder().decode([QueueDropItem].self, from: data) == items)
  }

  @Test("track selection follows macOS modifier semantics")
  func trackSelectionFollowsMacosModifierSemantics() {
    let ids = ["one", "two", "three", "four", "five"]
    let plain = updatedTrackSelection(
      current: [], anchor: nil, clicked: "two", ordered: ids, modifiers: [])
    let shifted = updatedTrackSelection(
      current: plain.ids,
      anchor: plain.anchor,
      clicked: "four",
      ordered: ids,
      modifiers: [.shift]
    )
    let extended = updatedTrackSelection(
      current: shifted.ids,
      anchor: shifted.anchor,
      clicked: "five",
      ordered: ids,
      modifiers: [.command, .shift]
    )
    let toggled = updatedTrackSelection(
      current: extended.ids,
      anchor: extended.anchor,
      clicked: "three",
      ordered: ids,
      modifiers: [.command]
    )

    #expect(plain.ids == ["two"])
    #expect(shifted.ids == ["two", "three", "four"])
    #expect(shifted.anchor == "two")
    #expect(extended.ids == ["two", "three", "four", "five"])
    #expect(toggled.ids == ["two", "four", "five"])
    #expect(toggled.anchor == "three")
  }

  @Test("queue collection selection follows macOS modifier semantics")
  func queueCollectionSelectionFollowsMacosModifierSemantics() {
    let ordered = ["a1", "a2", "b1", "b2", "c1", "c2"]
    let albumA = ["a1", "a2"]
    let albumB = ["b1", "b2"]
    let albumC = ["c1", "c2"]

    let plain = updatedQueueSelection(
      current: [], anchorIDs: [], clickedIDs: albumB, ordered: ordered, modifiers: [])
    let extended = updatedQueueSelection(
      current: plain.ids, anchorIDs: plain.anchorIDs, clickedIDs: albumC,
      ordered: ordered, modifiers: [.command])
    let toggled = updatedQueueSelection(
      current: extended.ids, anchorIDs: extended.anchorIDs, clickedIDs: albumB,
      ordered: ordered, modifiers: [.command])
    let ranged = updatedQueueSelection(
      current: albumC, anchorIDs: albumC, clickedIDs: albumA,
      ordered: ordered, modifiers: [.shift])
    let additiveRange = updatedQueueSelection(
      current: albumA, anchorIDs: albumB, clickedIDs: albumC,
      ordered: ordered, modifiers: [.command, .shift])

    #expect(plain.ids == albumB)
    #expect(plain.anchorIDs == albumB)
    #expect(extended.ids == albumB + albumC)
    #expect(toggled.ids == albumC)
    #expect(ranged.ids == ordered)
    #expect(additiveRange.ids == ordered)
    #expect(queueSelectionContainsAll(ordered, collection: albumA))
    #expect(queueSelectionContainsAll(ordered, collection: albumB))
    #expect(!queueSelectionContainsAll(albumA, collection: albumB))
    #expect(queueCollectionDragIDs(collection: albumB, selected: ordered) == ordered)
    #expect(queueCollectionDragIDs(collection: albumB, selected: albumA) == albumB)
  }

  @Test("queue selection survives focus changes and follows queue mutations")
  func queueSelectionSurvivesFocusChangesAndFollowsQueueMutations() {
    let ids = [UUID(), UUID(), UUID()]
    let selection = QueueSelectionModel()

    selection.selectAll(ids)
    #expect(selection.selectedEntryIDs == ids)

    selection.reconcile(with: [ids[2], ids[0]])
    #expect(selection.selectedEntryIDs == [ids[2], ids[0]])

    selection.remove([ids[2]])
    #expect(selection.selectedEntryIDs == [ids[0]])

    selection.clear()
    #expect(selection.selectedEntryIDs == nil)
  }

  @Test("queue select-all routes only to a visible main-window queue")
  func queueSelectAllRoutesOnlyToVisibleMainWindowQueue() {
    let route = { (mainWindow: Bool, queueVisible: Bool, textEditing: Bool) in
      shouldRouteQueueSelectAllShortcut(
        modifiers: .command,
        charactersIgnoringModifiers: "a",
        appIsActive: true,
        mainPlaybackWindowIsKey: mainWindow,
        queueIsVisible: queueVisible,
        isTextEditing: textEditing
      )
    }

    #expect(route(true, true, false))
    #expect(!route(true, false, false))
    #expect(!route(false, true, false))
    #expect(!route(true, true, true))
    #expect(
      shouldRouteQueueSelectAllShortcut(
        modifiers: [.command, .capsLock],
        charactersIgnoringModifiers: "a",
        appIsActive: true,
        mainPlaybackWindowIsKey: true,
        queueIsVisible: true,
        isTextEditing: false
      ))
    #expect(
      !shouldRouteQueueSelectAllShortcut(
        modifiers: [.command, .shift],
        charactersIgnoringModifiers: "a",
        appIsActive: true,
        mainPlaybackWindowIsKey: true,
        queueIsVisible: true,
        isTextEditing: false
      ))
    #expect(codaQueueWidth(windowWidth: 800) == 285)
    #expect(codaQueueWidth(windowWidth: 2_000) == 330)
    #expect(codaQueueIsVisible(windowWidth: 800, hasEstablishedConnection: true))
    #expect(!codaQueueIsVisible(windowWidth: 700, hasEstablishedConnection: true))
    #expect(!codaQueueIsVisible(windowWidth: 1_440, hasEstablishedConnection: false))
  }

  @Test("queue Escape clears only a visible main-window selection")
  func queueEscapeClearsOnlyAVisibleMainWindowSelection() {
    let route = {
      (mainWindow: Bool, queueVisible: Bool, textEditing: Bool, hasSelection: Bool) in
      shouldRouteQueueClearSelectionShortcut(
        modifiers: [],
        charactersIgnoringModifiers: "\u{1B}",
        appIsActive: true,
        mainPlaybackWindowIsKey: mainWindow,
        queueIsVisible: queueVisible,
        isTextEditing: textEditing,
        hasSelection: hasSelection
      )
    }

    #expect(route(true, true, false, true))
    #expect(!route(true, true, false, false))
    #expect(!route(true, false, false, true))
    #expect(!route(false, true, false, true))
    #expect(!route(true, true, true, true))
    #expect(
      !shouldRouteQueueClearSelectionShortcut(
        modifiers: .command,
        charactersIgnoringModifiers: "\u{1B}",
        appIsActive: true,
        mainPlaybackWindowIsKey: true,
        queueIsVisible: true,
        isTextEditing: false,
        hasSelection: true
      ))
  }

  @Test("queue follows playback only while the previous track remains visible")
  func queuePlaybackFollowPolicy() {
    #expect(
      shouldAutomaticallyRevealCurrentTrack(
        previousWasVisible: true,
        currentIsVisible: false
      ))
    #expect(
      !shouldAutomaticallyRevealCurrentTrack(
        previousWasVisible: false,
        currentIsVisible: false
      ))
    #expect(
      !shouldAutomaticallyRevealCurrentTrack(
        previousWasVisible: true,
        currentIsVisible: true
      ))
  }

  @Test("queue drop targeting ignores stale offscreen row geometry")
  func queueDropTargetingIgnoresStaleOffscreenGeometry() {
    let stale = QueueEntry(
      sourceID: "stale",
      url: URL(string: "https://example.test/stale")!,
      title: "Stale Album"
    )
    let visible = QueueEntry(
      sourceID: "visible",
      url: URL(string: "https://example.test/visible")!,
      title: "Visible Album"
    )
    let measurements = visibleQueueDropMeasurements(
      entries: [stale, visible],
      frames: [
        stale.id: CGRect(x: 0, y: 100, width: 300, height: 24),
        visible.id: CGRect(x: 0, y: 102, width: 300, height: 24),
      ],
      visibleEntryIDs: [visible.id]
    )

    #expect(measurements.map { $0.0.id } == [visible.id])
  }

  @Test("queue reorder keeps one authoritative insertion result")
  func queueReorderKeepsOneAuthoritativeInsertionResult() {
    let ids = [UUID(), UUID(), UUID(), UUID()]
    #expect(
      reorderedQueueIDs(ids, moving: [ids[1]], before: nil)
        == [ids[0], ids[2], ids[3], ids[1]])
    #expect(reorderedQueueIDs(ids, moving: [ids[0], ids[1]], before: ids[2]) == nil)
    #expect(
      reorderedQueueIDs(ids, moving: [ids[2], ids[3]], before: ids[0])
        == [ids[2], ids[3], ids[0], ids[1]])
    #expect(
      reorderedQueueIDs(ids, moving: [ids[2], ids[3]], before: ids[1])
        == [ids[0], ids[2], ids[3], ids[1]])
  }

  @Test("queue grouping preserves occurrences and splits")
  func queueGroupingPreservesOccurrencesAndSplits() {
    let albumGroup = UUID()
    let otherGroup = UUID()
    let first = QueueEntry(
      sourceID: "first", url: URL(string: "https://example.test/first")!,
      title: "First", album: "Album", queueGroupID: albumGroup)
    let other = QueueEntry(
      sourceID: "other", url: URL(string: "https://example.test/other")!,
      title: "Other", album: "Other Album", queueGroupID: otherGroup)
    let second = QueueEntry(
      sourceID: "second", url: URL(string: "https://example.test/second")!,
      title: "Second", album: "Album", queueGroupID: albumGroup)

    #expect(
      queueGroups([first, other, second]).map(\.entryIDs)
        == [[first.id], [other.id], [second.id]])
  }

  @Test("empty album IDs fall back to album metadata for grouping")
  func emptyAlbumIDsFallBackToAlbumMetadataForGrouping() {
    let first = QueueEntry(
      sourceID: "first", url: URL(string: "https://example.test/first")!,
      title: "First", artist: "Artist A", album: "Album A", albumID: "")
    let second = QueueEntry(
      sourceID: "second", url: URL(string: "https://example.test/second")!,
      title: "Second", artist: "Artist A", album: "Album A", albumID: "  ")
    let other = QueueEntry(
      sourceID: "other", url: URL(string: "https://example.test/other")!,
      title: "Other", artist: "Artist B", album: "Album B", albumID: "")

    #expect(
      albumGroupingIdentity(albumID: nil, artist: " Artist A ", album: "Album A")
        == albumGroupingIdentity(albumID: "", artist: "artist a", album: " Album A "))
    #expect(
      albumGroupingIdentity(albumID: "server-id", artist: "Artist A", album: "Album A")
        != albumGroupingIdentity(albumID: nil, artist: "Artist A", album: "Album A"))
    #expect(queueGroups([first, second, other]).map(\.entryIDs) == [[first.id, second.id], [other.id]])
  }

  @Test("album chronology uses full release date")
  func albumChronologyUsesFullReleaseDate() {
    let later = RemoteAlbum(
      id: "later", name: "Later",
      originalReleaseDate: ItemDate(year: 2024, month: 11, day: 2))
    let earlier = RemoteAlbum(
      id: "earlier", name: "Earlier",
      originalReleaseDate: ItemDate(year: 2024, month: 2, day: 12))

    #expect(
      [later, earlier].sorted { $0.chronologicalReleaseKey < $1.chronologicalReleaseKey }
        .map(\.id) == ["earlier", "later"])
  }

  @Test("OpenSubsonic disc titles decode")
  func opensubsonicDiscTitlesDecode() throws {
    let data = Data(
      #"{"id":"album","name":"Three Discs","discTitles":[{"disc":2,"title":"Live"},{"disc":3,"title":"Instrumentals","coverArt":"disc-3"}]}"#
        .utf8
    )
    let album = try JSONDecoder().decode(RemoteAlbum.self, from: data)
    #expect(album.discTitles == [
      RemoteDiscTitle(disc: 2, title: "Live"),
      RemoteDiscTitle(disc: 3, title: "Instrumentals", coverArt: "disc-3"),
    ])
  }

  @Test("unlimited disc sections use local numbering and runtimes")
  func unlimitedDiscSectionsUseLocalNumberingAndRuntimes() {
    let album = RemoteAlbum(
      id: "album", name: "Three Discs",
      discTitles: [RemoteDiscTitle(disc: 3, title: "Bonus")])
    let songs = [
      RemoteSong(id: "1", title: "One", track: 1, discNumber: 1, duration: 60),
      RemoteSong(id: "2", title: "Two", track: 1, discNumber: 2, duration: 120),
      RemoteSong(
        id: "3", title: "Three", track: 1, discNumber: 3,
        discSubtitle: "Bonus", duration: 180),
    ]
    let page = AlbumPage(album: album, songs: songs)
    let queueEntries = songs.map { song in
      QueueEntry(
        sourceID: song.id,
        url: URL(string: "https://example.test/\(song.id)")!,
        title: song.title,
        trackNumber: song.track,
        discNumber: song.discNumber,
        discSubtitle: song.discSubtitle,
        durationSeconds: song.duration ?? 0
      )
    }
    let queueGroup = QueueGroup(id: queueEntries[0].id, startIndex: 0, entries: queueEntries)

    #expect(page.showsDiscHeadings)
    #expect(page.discSections.map(\.number) == [1, 2, 3])
    #expect(page.discSections.map(\.durationSeconds) == [60, 120, 180])
    #expect(page.discSections.last?.subtitle == "Bonus")
    #expect(queueGroup.showsDiscHeadings)
    #expect(queueGroup.beginsDiscSection(at: 2))
    #expect(queueGroup.discSubtitle(at: 2) == "Bonus")
    #expect(queueGroup.discDuration(at: 2) == 180)
    #expect(trackLabel(queueEntries[2]) == "1")
  }
}

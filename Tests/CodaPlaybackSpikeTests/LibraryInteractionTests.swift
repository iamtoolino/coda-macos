import AppKit
import AudioToolbox
import Combine
import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("Library interactions")
@MainActor
struct LibraryInteractionTests {
  @Test("album collection sort options")
  func albumCollectionSortOptions() throws {
    let passed = try { () throws -> Bool in
      AlbumCollectionKind.allCases == [
        .recentlyAdded,
        .recentReleases,
        .topRated,
        .mostPlayed,
        .recentlyPlayed,
        .alphabetical,
      ] && AlbumCollectionKind.mostPlayed.apiValue == "frequent"
    }()
    #expect(passed)
  }

  @Test("library queue drag payload round trip")
  func libraryQueueDragPayloadRoundTrip() throws {
    let passed = try { () throws -> Bool in
      let items = [
        LibraryQueueDragItem.artist("artist/1"),
        LibraryQueueDragItem.album("album/1"),
        LibraryQueueDragItem.albumDisc("album/1", discNumber: 3),
        LibraryQueueDragItem.playlist("playlist/1"),
        LibraryQueueDragItem.song("song/1"),
        LibraryQueueDragItem.songs(["song/2", "song/3"]),
      ]
      let data = try JSONEncoder().encode(items)
      return try JSONDecoder().decode([LibraryQueueDragItem].self, from: data) == items
    }()
    #expect(passed)
  }

  @Test("queue reorder drag payload round trip")
  func queueReorderDragPayloadRoundTrip() throws {
    let passed = try { () throws -> Bool in
      let items = [
        QueueReorderDragItem.albumBlock([UUID(), UUID()]),
        QueueReorderDragItem.tracks([UUID(), UUID()]),
      ]
      let data = try JSONEncoder().encode(items)
      return try JSONDecoder().decode([QueueReorderDragItem].self, from: data) == items
    }()
    #expect(passed)
  }

  @Test("unified queue drop payload round trip")
  func unifiedQueueDropPayloadRoundTrip() throws {
    let passed = try { () throws -> Bool in
      let items = [
        QueueDropItem.library(.album("album/1")),
        QueueDropItem.reorder(.track(UUID())),
      ]
      let data = try JSONEncoder().encode(items)
      return try JSONDecoder().decode([QueueDropItem].self, from: data) == items
    }()
    #expect(passed)
  }

  @Test("track selection follows macOS modifier semantics")
  func trackSelectionFollowsMacosModifierSemantics() throws {
    let passed = try { () throws -> Bool in
      let ids = ["one", "two", "three", "four", "five"]
      let plain = updatedTrackSelection(
        current: [],
        anchor: nil,
        clicked: "two",
        ordered: ids,
        modifiers: []
      )
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
      return plain.ids == ["two"]
        && shifted.ids == ["two", "three", "four"]
        && shifted.anchor == "two"
        && extended.ids == ["two", "three", "four", "five"]
        && toggled.ids == ["two", "four", "five"]
        && toggled.anchor == "three"
    }()
    #expect(passed)
  }

  @Test("queue reorder keeps one authoritative insertion result")
  func queueReorderKeepsOneAuthoritativeInsertionResult() throws {
    let passed = try { () throws -> Bool in
      let ids = [UUID(), UUID(), UUID(), UUID()]
      return reorderedQueueIDs(ids, moving: [ids[1]], before: nil)
        == [ids[0], ids[2], ids[3], ids[1]]
        && reorderedQueueIDs(ids, moving: [ids[0], ids[1]], before: ids[2]) == nil
        && reorderedQueueIDs(ids, moving: [ids[2], ids[3]], before: ids[0])
          == [ids[2], ids[3], ids[0], ids[1]]
        && reorderedQueueIDs(ids, moving: [ids[2], ids[3]], before: ids[1])
          == [ids[0], ids[2], ids[3], ids[1]]
    }()
    #expect(passed)
  }

  @Test("queue grouping preserves occurrences and splits")
  func queueGroupingPreservesOccurrencesAndSplits() throws {
    let passed = try { () throws -> Bool in
      let albumGroup = UUID()
      let otherGroup = UUID()
      let first = QueueEntry(
        sourceID: "first",
        url: URL(string: "https://example.test/first")!,
        title: "First",
        album: "Album",
        queueGroupID: albumGroup
      )
      let other = QueueEntry(
        sourceID: "other",
        url: URL(string: "https://example.test/other")!,
        title: "Other",
        album: "Other Album",
        queueGroupID: otherGroup
      )
      let second = QueueEntry(
        sourceID: "second",
        url: URL(string: "https://example.test/second")!,
        title: "Second",
        album: "Album",
        queueGroupID: albumGroup
      )
      return queueGroups([first, other, second]).map(\.entryIDs)
        == [[first.id], [other.id], [second.id]]
    }()
    #expect(passed)
  }

  @Test("album chronology uses full release date")
  func albumChronologyUsesFullReleaseDate() throws {
    let passed = try { () throws -> Bool in
      let later = RemoteAlbum(
        id: "later",
        name: "Later",
        originalReleaseDate: ItemDate(year: 2024, month: 11, day: 2)
      )
      let earlier = RemoteAlbum(
        id: "earlier",
        name: "Earlier",
        originalReleaseDate: ItemDate(year: 2024, month: 2, day: 12)
      )
      return [later, earlier].sorted { $0.chronologicalReleaseKey < $1.chronologicalReleaseKey }
        .map(\.id) == ["earlier", "later"]
    }()
    #expect(passed)
  }

  @Test("OpenSubsonic disc titles decode")
  func opensubsonicDiscTitlesDecode() throws {
    let passed = try { () throws -> Bool in
      let data = Data(
        #"{"id":"album","name":"Three Discs","discTitles":[{"disc":2,"title":"Live"},{"disc":3,"title":"Instrumentals","coverArt":"disc-3"}]}"#
          .utf8
      )
      let album = try JSONDecoder().decode(RemoteAlbum.self, from: data)
      return album.discTitles == [
        RemoteDiscTitle(disc: 2, title: "Live"),
        RemoteDiscTitle(disc: 3, title: "Instrumentals", coverArt: "disc-3"),
      ]
    }()
    #expect(passed)
  }

  @Test("unlimited disc sections use local numbering and runtimes")
  func unlimitedDiscSectionsUseLocalNumberingAndRuntimes() throws {
    let passed = try { () throws -> Bool in
      let album = RemoteAlbum(
        id: "album",
        name: "Three Discs",
        discTitles: [RemoteDiscTitle(disc: 3, title: "Bonus")]
      )
      let songs = [
        RemoteSong(id: "1", title: "One", track: 1, discNumber: 1, duration: 60),
        RemoteSong(id: "2", title: "Two", track: 1, discNumber: 2, duration: 120),
        RemoteSong(
          id: "3",
          title: "Three",
          track: 1,
          discNumber: 3,
          discSubtitle: "Bonus",
          duration: 180
        ),
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
      return page.showsDiscHeadings
        && page.discSections.map(\.number) == [1, 2, 3]
        && page.discSections.map(\.durationSeconds) == [60, 120, 180]
        && page.discSections.last?.subtitle == "Bonus"
        && queueGroup.showsDiscHeadings
        && queueGroup.beginsDiscSection(at: 2)
        && queueGroup.discSubtitle(at: 2) == "Bonus"
        && queueGroup.discDuration(at: 2) == 180
        && trackLabel(queueEntries[2]) == "1"
    }()
    #expect(passed)
  }
}

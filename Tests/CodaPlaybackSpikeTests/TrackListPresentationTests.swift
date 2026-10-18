import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("Track list presentation")
@MainActor
struct TrackListPresentationTests {
  @Test("Queue and playlist share boundaries without sorting or collapsing duplicate songs")
  func sharedBoundaries() {
    let albumIDs: [String?] = ["A", "A", "B", "A", "A", nil, " ", "C"]
    let entries = albumIDs.enumerated().map { entry("song-\($0.offset % 2)", albumID: $0.element) }
    let songs = albumIDs.enumerated().map {
      RemoteSong(id: "song-\($0.offset % 2)", title: "Track", albumId: $0.element)
    }
    let expected = [0..<2, 2..<3, 3..<5, 5..<6, 6..<7, 7..<8]
    let groups = AlbumSequenceResolver.groups(albumIDs: albumIDs)
    #expect(groups.map(\.range) == expected)
    #expect(groups.map(\.isAlbumSequence) == [true, false, true, false, false, false])
    let queue = queueGroups(entries)
    let playlist = playlistGroups(songs)
    #expect(queue.map { $0.startIndex..<($0.startIndex + $0.entries.count) } == expected)
    #expect(playlist.map { $0.songs.map(\.index) } == expected.map(Array.init))
    #expect(queue.map(\.isStandalone) == [false, true, false, true, true, true])
    #expect(playlist.map(\.isStandalone) == queue.map(\.isStandalone))
    #expect(queue.flatMap(\.entryIDs) == entries.map(\.id))
    #expect(playlist.flatMap(\.songs).map(\.song.id) == songs.map(\.id))
    #expect(Set(playlist.flatMap(\.songs).map(\.id)).count == songs.count)
    for index in entries.indices {
      let group = groups.first { $0.range.contains(index) }!
      #expect(group.isAlbumSequence
        == AlbumSequenceResolver.context(in: entries, at: index)?.isAlbumSequence)
    }
  }

  @Test("Separately appended copies merge and header actions cover the visible group")
  func appendedCopies() throws {
    let player = PlayerController(backend: TestPlaybackBackend())
    let first = [entry("one", albumID: "A"), entry("two", albumID: "A")]
    let second = [entry("one", albumID: "A"), entry("two", albumID: "A")]
    player.enqueue(first)
    player.enqueue(second)
    let group = try #require(queueGroups(player.queue).first)
    #expect(queueGroups(player.queue).count == 1)
    #expect(group.entryIDs == (first + second).map(\.id))
    #expect(Set(group.entryIDs).count == 4)
    let selection = QueueSelectionModel()
    selection.select(group.entryIDs, orderedBy: player.queue.map(\.id), modifiers: [])
    #expect(selection.selectedEntryIDs == group.entryIDs)
    player.remove(entryIDs: group.entryIDs)
    #expect(player.queue.isEmpty)
  }

  @Test("Moving a track out and back splits and reunites presentation without restarting playback")
  func splitAndReunite() throws {
    let backend = TestPlaybackBackend()
    let player = PlayerController(backend: backend)
    let a = entry("a", albumID: "A")
    let b = entry("b", albumID: "A")
    let other = entry("other", albumID: "B")
    player.replaceQueue([a, b, other], startsPlaying: true)
    let occurrence = player.playbackOccurrenceID
    let selection = QueueSelectionModel()
    selection.select([b.id], orderedBy: player.queue.map(\.id), modifiers: [])
    #expect(player.move(entryIDs: [b.id], before: nil))
    #expect(queueGroups(player.queue).map(\.entryIDs) == [[a.id], [other.id], [b.id]])
    #expect(player.move(entryIDs: [b.id], before: other.id))
    #expect(queueGroups(player.queue).map(\.entryIDs) == [[a.id, b.id], [other.id]])
    selection.reconcile(with: player.queue.map(\.id))
    #expect(selection.selectedEntryIDs == [b.id])
    #expect(player.playbackOccurrenceID == occurrence)
    #expect(player.currentEntry?.id == a.id)
    #expect(backend.loadCalls.count == 1)
    player.remove(entryID: b.id)
    #expect(queueGroups(player.queue).allSatisfy { $0.isStandalone })
    #expect(AlbumSequenceResolver.context(in: player.queue, at: 0)?.isAlbumSequence == false)
    #expect(player.currentAlbumSequence?.isAlbumSequence == true)
  }

  @Test("Album identity is independent of track numbering, disc boundaries, and shared titles")
  func identityRules() {
    let entries = [
      entry("later", albumID: " A ", track: 9, disc: 2),
      entry("earlier", albumID: "A", track: 1, disc: 1),
      entry("different", albumID: "B", track: 1, disc: 1),
      entry("unknown-1", albumID: nil), entry("unknown-2", albumID: nil),
    ]
    let groups = queueGroups(entries)
    #expect(groups.map(\.entryIDs) == [[entries[0].id, entries[1].id],
      [entries[2].id], [entries[3].id], [entries[4].id]])
    #expect(groups.first?.albumID == "A")
    #expect(groups.first?.entries.map(\.trackNumber) == [9, 1])
    #expect(groups.first?.showsDiscHeadings == true)
    #expect(groups.first?.beginsDiscSection(at: 1) == true)
  }

  @Test("Empty inputs and singletons keep valid boundaries and unique scroll identities")
  func boundaries() {
    #expect(AlbumSequenceResolver.groups(albumIDs: []).isEmpty)
    #expect(queueGroups([]).isEmpty)
    #expect(playlistGroups([]).isEmpty)
    let singleton = entry("one", albumID: "A")
    #expect(queueGroups([singleton]).first?.id == singleton.id)
    #expect(AlbumSequenceResolver.groups(albumIDs: ["A"]).first?.isAlbumSequence == false)
    let separated = [singleton, entry("other", albumID: "B"), entry("one", albumID: "A")]
    #expect(Set(queueGroups(separated).map(\.id)).count == 3)
  }

  @Test("Repeated multidisc albums keep disc actions scoped to each visible section")
  func repeatedDiscs() throws {
    let entries = [1, 2, 1, 2].map { entry("song", albumID: "A", disc: $0) }
    let group = try #require(queueGroups(entries).first)
    #expect(group.entries.count == 4)
    #expect(group.beginsDiscSection(at: 2))
    #expect(group.discEntryIDs(at: 0) == [entries[0].id])
    #expect(group.discEntryIDs(at: 2) == [entries[2].id])
    #expect(group.discDuration(at: 0) == 60)
    #expect(group.discDuration(at: 2) == 60)
  }

  private func entry(_ songID: String, albumID: String?, track: Int = 1, disc: Int = 1) -> QueueEntry {
    QueueEntry(sourceID: songID, url: URL(string: "https://example.test/audio")!, title: songID,
               artist: "Artist", album: "Same album title", albumID: albumID,
               trackNumber: track, discNumber: disc, durationSeconds: 60)
  }
}

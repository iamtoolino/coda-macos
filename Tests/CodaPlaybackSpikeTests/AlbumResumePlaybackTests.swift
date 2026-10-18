import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("Album resume playback eligibility")
@MainActor
struct AlbumResumePlaybackTests {
  private var page: AlbumPage {
    AlbumPage(album: RemoteAlbum(id: "A", name: "Album"), songs: [
      RemoteSong(id: "first", title: "First", albumId: "A", track: 1),
      RemoteSong(id: "final", title: "Final", albumId: "A", track: 2),
    ])
  }

  @Test("Isolated playlist tracks neither create nor clear album progress")
  func isolatedTracks() throws {
    for songID in ["first", "final"] {
      let (player, backend) = playerWith([entry(songID), entry("other", album: "B")])
      backend.emit(.automaticallyAdvanced)
      let completion = try #require(player.completedPlayback)
      #expect(albumResumeRecordingAlbumID(for: completion) == nil)
      #expect(albumResumeCompletionAction(completion: completion, album: page) == .none)
    }
  }

  @Test("An album run in a mixed playlist records progress including its final song")
  func albumRun() throws {
    let (player, backend) = playerWith([
      entry("first"), entry("final"), entry("other", album: "B"),
    ])
    backend.emit(.automaticallyAdvanced)
    #expect(albumResumeCompletionAction(completion: try #require(player.completedPlayback), album: page)
      == .upsert(anchorSongID: "first", resumeSongID: "final"))
    backend.emit(.automaticallyAdvanced)
    #expect(albumResumeCompletionAction(completion: try #require(player.completedPlayback), album: page)
      == .delete(anchorSongID: "first"))
  }

  @Test("Eligibility uses the completed occurrence rather than edited queue neighbours")
  func editedQueue() throws {
    let first = entry("first")
    let final = entry("final")
    let (player, backend) = playerWith([first, final])
    player.remove(entryID: final.id)
    backend.emit(.finished)
    #expect(albumResumeCompletionAction(completion: try #require(player.completedPlayback), album: page)
      == .upsert(anchorSongID: "first", resumeSongID: "final"))

    let (isolated, isolatedBackend) = playerWith([first])
    isolated.enqueue([final])
    isolatedBackend.emit(.automaticallyAdvanced)
    #expect(albumResumeRecordingAlbumID(for: try #require(isolated.completedPlayback)) == nil)
  }

  @Test("Explicit continuation can finish a singleton without changing ReplayGain's rule")
  func explicitFinalContinuation() throws {
    var final = entry("final")
    final.albumContinuationID = "A"
    let (player, backend) = playerWith([final])
    let context = try #require(player.currentAlbumSequence)
    #expect(context.isExplicitContinuation)
    #expect(!context.isAlbumSequence)
    #expect(ReplayGainPolicy.gainDb(enabled: true, context: context,
      metadata: ReplayGainMetadata(trackGain: -3, albumGain: -8)) == -3)
    backend.emit(.finished)
    #expect(albumResumeCompletionAction(completion: try #require(player.completedPlayback), album: page)
      == .delete(anchorSongID: "first"))
  }

  @Test("Continuation hints cannot grant membership in another or unknown album")
  func invalidContinuation() throws {
    for albumID: String? in [nil, "", "B"] {
      var final = entry("final", album: albumID)
      final.albumContinuationID = "A"
      let (player, backend) = playerWith([final])
      backend.emit(.finished)
      #expect(albumResumeRecordingAlbumID(for: try #require(player.completedPlayback)) == nil)
    }
    let completion = CompletedPlayback(sourceID: "final", albumSequence: AlbumSequenceContext(
      albumID: "B", continuesPrevious: true, continuesNext: false))
    #expect(albumResumeCompletionAction(completion: completion, album: page) == .none)
  }

  @Test("Manual skips do not publish album progress and restored runs still qualify")
  func manualAndRestoredPlayback() throws {
    let (player, backend) = playerWith([entry("first"), entry("final")], paused: true)
    #expect(player.completedPlayback == nil)
    player.play()
    player.next()
    #expect(player.completedPlayback == nil)
    player.pause()
    player.seek(to: 20)
    #expect(player.completedPlayback == nil)
    backend.emit(.finished)
    #expect(albumResumeCompletionAction(completion: try #require(player.completedPlayback), album: page)
      == .delete(anchorSongID: "first"))
  }

  @Test("Resume drag intent round-trips independently of ordinary song drags")
  func continuationDrag() throws {
    let resume = LibraryQueueDragItem.songs(["final"], albumContinuationID: "A")
    let decoded = try JSONDecoder().decode(LibraryQueueDragItem.self, from: JSONEncoder().encode(resume))
    #expect(decoded.albumContinuationID == "A")
    let ordinary = try JSONDecoder().decode(LibraryQueueDragItem.self,
      from: Data(#"{"kind":"songs","id":"final","songIDs":["final"]}"#.utf8))
    #expect(ordinary.albumContinuationID == nil)
  }

  private func entry(_ id: String, album: String? = "A") -> QueueEntry {
    QueueEntry(sourceID: id, url: URL(string: "https://example.test/\(id)")!,
               title: id, albumID: album)
  }

  private func playerWith(_ queue: [QueueEntry], paused: Bool = false)
    -> (PlayerController, TestPlaybackBackend) {
    let backend = TestPlaybackBackend()
    let player = PlayerController(backend: backend)
    player.replaceQueue(queue, startsPlaying: !paused)
    return (player, backend)
  }
}

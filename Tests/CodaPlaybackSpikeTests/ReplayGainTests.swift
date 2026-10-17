import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("ReplayGain")
@MainActor
struct ReplayGainTests {
  @Test("Gain selection preserves album levels and falls back without double gain")
  func selection() {
    let album = AlbumSequenceContext(albumID: "A", continuesPrevious: false, continuesNext: true)
    let track = AlbumSequenceContext(albumID: "A", continuesPrevious: false, continuesNext: false)
    let tags = ReplayGainMetadata(trackGain: -10, albumGain: -7, trackPeak: 1, albumPeak: 1)
    #expect(ReplayGainPolicy.gainDb(enabled: true, context: album, metadata: tags) == -7)
    #expect(ReplayGainPolicy.gainDb(enabled: true, context: track, metadata: tags) == -10)
    #expect(ReplayGainPolicy.gainDb(enabled: false, context: album, metadata: tags) == 0)
    #expect(ReplayGainPolicy.gainDb(enabled: true, context: album,
      metadata: ReplayGainMetadata(trackGain: 0)) == 0)
    #expect(ReplayGainPolicy.gainDb(enabled: true, context: track,
      metadata: ReplayGainMetadata(albumGain: -4)) == -9)
    #expect(ReplayGainPolicy.gainDb(enabled: true, context: album, metadata: nil) == -9)
    #expect(ReplayGainPolicy.gainDb(enabled: true, context: album,
      metadata: ReplayGainMetadata(trackGain: -3, albumGain: .nan)) == -3)
  }

  @Test("Peak prevention permits safe boosts and uses the selected gain's peak")
  func peaks() {
    let gain = ReplayGainPolicy.gainDb(enabled: true, context: nil,
      metadata: ReplayGainMetadata(trackGain: 5, trackPeak: 0.8))
    #expect(abs(gain - 1.93820026) < 0.000001)
    #expect(ReplayGainPolicy.gainDb(enabled: true, context: nil,
      metadata: ReplayGainMetadata(trackGain: -10, trackPeak: 1)) == -10)
    #expect(ReplayGainPolicy.gainDb(enabled: true, context: nil,
      metadata: ReplayGainMetadata(trackGain: 5, trackPeak: 0)) == 5)
    #expect(ReplayGainPolicy.gainDb(enabled: true, context: nil,
      metadata: ReplayGainMetadata(trackGain: 5, trackPeak: .infinity)) == 5)
    #expect(ReplayGainPolicy.gainDb(enabled: true, context: nil,
      metadata: ReplayGainMetadata(trackGain: 5, trackPeak: 2)) < -6)
    #expect(ReplayGainPolicy.gainDb(enabled: true, context: nil,
      metadata: ReplayGainMetadata(trackGain: .infinity)) == -9)
  }

  @Test("Malformed optional API fields never make a song unplayable")
  func decoding() throws {
    for json in [
      #"{"id":"song","title":"Song"}"#,
      #"{"id":"song","title":"Song","replayGain":null}"#,
      #"{"id":"song","title":"Song","replayGain":"bad"}"#,
    ] {
      let song = try JSONDecoder().decode(RemoteSong.self,
        from: Data(json.utf8))
      #expect(song.replayGain == nil)
    }
    let song = try JSONDecoder().decode(RemoteSong.self, from: Data(
      #"{"id":"song","title":"Song","replayGain":{"trackGain":0,"albumGain":"bad","trackPeak":1,"fallbackGain":-2}}"#.utf8))
    #expect(song.replayGain?.trackGain == 0)
    #expect(song.replayGain?.albumGain == nil)
    let queued = QueueEntry.remoteSong(song, streamURL: URL(string: "https://example.test/audio")!,
                                      artworkURL: nil, nowPlayingArtworkURL: nil)
    #expect(queued.replayGain == song.replayGain)
  }

  @Test("Off is the default; the explicit choice survives controller restoration")
  func persistence() throws {
    let name = "ReplayGainTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let backend = TestPlaybackBackend()
    let player = PlayerController(backend: backend, volumeDefaults: defaults)
    #expect(!player.replayGainEnabled)
    player.replaceQueue([entry("A")], startsPlaying: false)
    #expect(backend.loadCalls.last?.currentItem.replayGainDb == 0)
    player.setReplayGainEnabled(true)
    #expect(backend.replayGains.last == -3)
    #expect(player.volume == 1)
    #expect(PlayerController(backend: TestPlaybackBackend(), volumeDefaults: defaults).replayGainEnabled)
    player.setReplayGainEnabled(false)
    #expect(backend.replayGains.last == 0)
    #expect(!PlayerController(backend: TestPlaybackBackend(), volumeDefaults: defaults).replayGainEnabled)
  }

  @Test("Queue edits freeze the current occurrence and reprepare the same-URL next item")
  func queueEdits() throws {
    let backend = TestPlaybackBackend()
    let player = PlayerController(backend: backend)
    player.setReplayGainEnabled(true)
    let a = entry("A")
    let b = entry("B")
    let c = entry("B")
    player.replaceQueue([a, b], startsPlaying: true)
    #expect(backend.loadCalls.last?.currentItem.replayGainDb == -3)
    #expect(backend.loadCalls.last?.nextItem?.replayGainDb == -3)
    player.enqueue([c])
    #expect(backend.updatedNextItems.last??.url == b.url)
    #expect(backend.updatedNextItems.last??.replayGainDb == -8)
    #expect(player.currentReplayGainDb == -3)
    #expect(backend.replayGains.isEmpty)
    backend.emit(.automaticallyAdvanced)
    #expect(player.currentReplayGainDb == -8)
    #expect(player.currentAlbumSequence?.isAlbumSequence == true)
    player.remove(entryID: c.id)
    #expect(player.currentReplayGainDb == -8)
    #expect(player.currentAlbumSequence?.isAlbumSequence == true)
    player.seek(to: 1)
    player.pause()
    #expect(player.currentReplayGainDb == -8)
    backend.emit(.finished)
    #expect(player.completedPlayback?.albumSequence?.isAlbumSequence == true)
  }

  @Test("Untagged transitions and explicit toggles update current and prepared gain")
  func transitions() {
    let backend = TestPlaybackBackend()
    let player = PlayerController(backend: backend)
    player.setReplayGainEnabled(true)
    player.replaceQueue([entry("A"), entry("B", tagged: false), entry("C")])
    #expect(backend.loadCalls.last?.nextItem?.replayGainDb == -9)
    backend.emit(.automaticallyAdvanced)
    #expect(player.currentReplayGainDb == -9)
    #expect(backend.updatedNextItems.last??.replayGainDb == -3)
    player.setReplayGainEnabled(false)
    #expect(backend.replayGains.last == 0)
    #expect(backend.updatedNextItems.last??.replayGainDb == 0)
    backend.emit(.automaticallyAdvanced)
    #expect(player.currentReplayGainDb == 0)
  }

  @Test("Queue edits before first playback can update current album membership")
  func pausedPreparation() {
    let backend = TestPlaybackBackend()
    let player = PlayerController(backend: backend)
    player.setReplayGainEnabled(true)
    player.replaceQueue([entry("A")], startsPlaying: false)
    #expect(player.currentReplayGainDb == -3)
    player.enqueue([entry("A")])
    #expect(player.currentReplayGainDb == -8)
    player.play()
    player.pause()
    player.remove(entryID: player.queue[1].id)
    #expect(player.currentReplayGainDb == -8)
  }

  private func entry(_ album: String, tagged: Bool = true) -> QueueEntry {
    QueueEntry(sourceID: UUID().uuidString, url: URL(string: "https://example.test/\(album)")!,
               title: "Song", albumID: album,
               replayGain: tagged ? ReplayGainMetadata(trackGain: -3, albumGain: -8) : nil)
  }
}

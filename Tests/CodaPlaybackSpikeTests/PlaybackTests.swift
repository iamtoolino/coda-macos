import AppKit
import AudioToolbox
import Combine
import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("Playback")
@MainActor
struct PlaybackTests {
  @Test("mpv next refresh never removes a numeric playlist position")
  func mpvNextRefreshNeverRemovesANumericPlaylistPosition() throws {
    let passed = try { () throws -> Bool in
      let next = URL(string: "https://example.test/next.flac")!
      return mpvExpectedNextCommands(next) == [
        ["playlist-clear"],
        ["loadfile", next.absoluteString, "insert-next"],
      ] && mpvExpectedNextCommands(nil) == [["playlist-clear"]]
    }()
    #expect(passed)
  }

  @Test("mpv advances Coda on the incoming file start")
  func mpvAdvancesCodaOnTheIncomingFileStart() throws {
    let passed = try { () throws -> Bool in
      var tracker = MPVFileStartAdvanceTracker()
      let initialDidAdvance = tracker.observeStart(hasExpectedNext: true)
      let incomingDidAdvance = tracker.observeStart(hasExpectedNext: true)
      tracker.reset()
      let replacementDidAdvance = tracker.observeStart(hasExpectedNext: true)
      return !initialDidAdvance && incomingDidAdvance && !replacementDidAdvance
    }()
    #expect(passed)
  }

  @Test("late mpv end event cannot finish the incoming file")
  func lateMpvEndEventCannotFinishTheIncomingFile() throws {
    let passed = try { () throws -> Bool in
      mpvEndEventMatchesActiveFile(activeID: 12, endedID: 12)
        && !mpvEndEventMatchesActiveFile(activeID: 12, endedID: 11)
        && !mpvEndEventMatchesActiveFile(activeID: nil, endedID: 11)
    }()
    #expect(passed)
  }

  @Test("automatic backend advance publishes the next queue entry")
  func automaticBackendAdvancePublishesTheNextQueueEntry() throws {
    let passed = try { () throws -> Bool in
      let backend = TestPlaybackBackend()
      let first = QueueEntry(
        sourceID: "album-one-last",
        url: URL(string: "https://example.test/album-one-last")!,
        title: "Album One Last",
        album: "Album One"
      )
      let second = QueueEntry(
        sourceID: "album-two-first",
        url: URL(string: "https://example.test/album-two-first")!,
        title: "Album Two First",
        album: "Album Two"
      )
      let player = PlayerController(backend: backend)
      player.replaceQueue([first, second], startAt: 0, startsPlaying: true)
      let firstOccurrence = player.playbackOccurrenceID
      backend.emit(.automaticallyAdvanced)

      return player.currentIndex == 1
        && player.currentEntry?.id == second.id
        && player.playbackOccurrenceID != firstOccurrence
        && player.currentEntry?.album == "Album Two"
        && player.position == 0
        && player.duration == 0
        && backend.updatedNextURLs == [nil]
    }()
    #expect(passed)
  }

  @Test("queue replacement can explicitly request the top")
  func queueReplacementCanExplicitlyRequestTheTop() throws {
    let passed = try { () throws -> Bool in
      let backend = TestPlaybackBackend()
      let first = QueueEntry(
        sourceID: "first-queue",
        url: URL(string: "https://example.test/first-queue")!,
        title: "First Queue"
      )
      let second = QueueEntry(
        sourceID: "second-queue",
        url: URL(string: "https://example.test/second-queue")!,
        title: "Second Queue"
      )
      let player = PlayerController(backend: backend)
      let initialRequest = player.queueTopScrollRequest

      player.replaceQueue([first])
      guard player.queueTopScrollRequest == initialRequest else { return false }

      player.replaceQueue([second], scrollQueueToTop: true)
      return player.queueTopScrollRequest == initialRequest + 1
    }()
    #expect(passed)
  }

  @Test("finishing the queue retains it without an active track")
  func finishingTheQueueRetainsItWithoutAnActiveTrack() throws {
    let passed = try { () throws -> Bool in
      let backend = TestPlaybackBackend()
      let entry = QueueEntry(
        sourceID: "finished-track",
        url: URL(string: "https://example.test/finished-track")!,
        title: "Finished Track"
      )
      let player = PlayerController(backend: backend)
      player.replaceQueue([entry], startsPlaying: true)
      backend.emit(
        .snapshot(
          PlaybackBackendSnapshot(position: 120, duration: 120, isPlaying: true)
        )
      )
      backend.emit(.finished)

      return player.queue.map(\.id) == [entry.id]
        && player.currentIndex == nil
        && player.currentEntry == nil
        && player.playbackOccurrenceID == nil
        && !player.isPlaying
        && player.position == 0
        && player.duration == 0
        && player.status == "Finished"
    }()
    #expect(passed)
  }

  @Test("restored queue loads paused at its saved position")
  func restoredQueueLoadsPausedAtItsSavedPosition() throws {
    let passed = try { () throws -> Bool in
      let backend = TestPlaybackBackend()
      let entry = QueueEntry(
        sourceID: "restored-track",
        url: URL(string: "https://example.test/restored-track")!,
        title: "Restored Track"
      )
      let player = PlayerController(backend: backend)
      player.replaceQueue(
        [entry],
        positionSeconds: 83.25,
        startsPlaying: false
      )

      guard let load = backend.loadCalls.last else { return false }
      return load.url == entry.url
        && load.position == 83.25
        && !load.autoplay
        && player.position == 83.25
        && !player.isPlaying
    }()
    #expect(passed)
  }

  @Test("volume level survives player recreation")
  func volumeLevelSurvivesPlayerRecreation() throws {
    let passed = try { () throws -> Bool in
      let suiteName = "Coda.Tests.Volume.\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let firstPlayer = PlayerController(
        backend: TestPlaybackBackend(),
        volumeDefaults: defaults
      )
      firstPlayer.setVolume(0.37)

      let restoredPlayer = PlayerController(
        backend: TestPlaybackBackend(),
        volumeDefaults: defaults
      )
      return abs(restoredPlayer.volume - 0.37) < 0.000_001
        && !restoredPlayer.isMuted
    }()
    #expect(passed)
  }

  @Test("playback clock does not invalidate stable player state")
  func playbackClockDoesNotInvalidateStablePlayerState() throws {
    let passed = try { () throws -> Bool in
      let backend = TestPlaybackBackend()
      let player = PlayerController(backend: backend)
      let entry = QueueEntry(
        sourceID: "clock-test",
        url: URL(string: "https://example.test/clock-test")!,
        title: "Clock Test"
      )
      player.replaceQueue([entry], startsPlaying: true)

      var playerUpdates = 0
      var timelineUpdates = 0
      let playerToken = player.objectWillChange.sink { playerUpdates += 1 }
      let timelineToken = player.timeline.objectWillChange.sink { timelineUpdates += 1 }
      defer {
        playerToken.cancel()
        timelineToken.cancel()
      }

      backend.emit(
        .snapshot(
          PlaybackBackendSnapshot(
            position: 1,
            duration: 100,
            bufferedUntil: 30,
            isPlaying: true
          )))
      backend.emit(
        .snapshot(
          PlaybackBackendSnapshot(
            position: 1.25,
            duration: 100,
            bufferedUntil: 31,
            isPlaying: true
          )))

      return playerUpdates == 0
        && timelineUpdates == 1
        && player.position == 1.25
        && player.duration == 100
        && player.bufferedUntil == 31
    }()
    #expect(passed)
  }

  @Test("playback clock adapts its publication rate to window visibility")
  func playbackClockAdaptsItsPublicationRateToWindowVisibility() throws {
    let passed = try { () throws -> Bool in
      playbackTimelinePublicationInterval(windowIsVisible: true) == .milliseconds(250)
        && playbackTimelinePublicationInterval(windowIsVisible: false) == .seconds(1)
    }()
    #expect(passed)
  }

  @Test("reordering the playing album preserves playback identity")
  func reorderingThePlayingAlbumPreservesPlaybackIdentity() throws {
    let passed = try { () throws -> Bool in
      let backend = TestPlaybackBackend()
      let player = PlayerController(backend: backend)
      let albumGroup = UUID()
      let first = QueueEntry(
        sourceID: "first",
        url: URL(string: "https://example.test/first")!,
        title: "First",
        queueGroupID: albumGroup
      )
      let playing = QueueEntry(
        sourceID: "playing",
        url: URL(string: "https://example.test/playing")!,
        title: "Playing",
        queueGroupID: albumGroup
      )
      let other = QueueEntry(
        sourceID: "other",
        url: URL(string: "https://example.test/other")!,
        title: "Other"
      )
      player.replaceQueue([first, playing, other], startAt: 1, startsPlaying: true)
      let playbackOccurrence = player.playbackOccurrenceID
      backend.emit(
        .snapshot(
          PlaybackBackendSnapshot(
            position: 31,
            duration: 120,
            bufferedUntil: 80,
            isPlaying: true
          )))

      let didMove = player.move(entryIDs: [first.id, playing.id], before: nil)
      return didMove
        && player.queue.map(\.id) == [other.id, first.id, playing.id]
        && player.currentEntry?.id == playing.id
        && player.currentIndex == 2
        && player.position == 31
        && player.duration == 120
        && player.isPlaying
        && player.playbackOccurrenceID == playbackOccurrence
        && backend.loadCalls.count == 1
        && backend.updatedNextURLs == [nil]
    }()
    #expect(passed)
  }

  @Test("inserting library entries preserves playback identity")
  func insertingLibraryEntriesPreservesPlaybackIdentity() throws {
    let passed = try { () throws -> Bool in
      let backend = TestPlaybackBackend()
      let player = PlayerController(backend: backend)
      let playing = QueueEntry(
        sourceID: "playing",
        url: URL(string: "https://example.test/playing")!,
        title: "Playing"
      )
      let last = QueueEntry(
        sourceID: "last",
        url: URL(string: "https://example.test/last")!,
        title: "Last"
      )
      let inserted = QueueEntry(
        sourceID: "inserted",
        url: URL(string: "https://example.test/inserted")!,
        title: "Inserted"
      )
      player.replaceQueue([playing, last], startAt: 0, startsPlaying: true)
      backend.emit(
        .snapshot(
          PlaybackBackendSnapshot(position: 22, duration: 90, isPlaying: true)))

      player.insert([inserted], before: last.id)
      return player.queue.map(\.id) == [playing.id, inserted.id, last.id]
        && player.currentEntry?.id == playing.id
        && player.currentIndex == 0
        && player.position == 22
        && player.isPlaying
        && backend.loadCalls.count == 1
        && backend.updatedNextURLs.last == inserted.url
    }()
    #expect(passed)
  }

  @Test("unexpected mpv idle reloads a playing item once")
  func unexpectedMpvIdleReloadsAPlayingItemOnce() throws {
    let passed = try { () throws -> Bool in
      let backend = TestPlaybackBackend()
      let player = PlayerController(backend: backend)
      let entry = QueueEntry(
        sourceID: "one",
        url: URL(string: "https://example.test/one")!,
        title: "One"
      )
      player.replaceQueue([entry], positionSeconds: 12, startsPlaying: true)
      let playbackOccurrence = player.playbackOccurrenceID
      backend.emit(
        .snapshot(
          PlaybackBackendSnapshot(position: 18, duration: 100, isPlaying: true)))
      backend.hasLoadedItem = false
      backend.emit(.unexpectedlyBecameIdle(position: 18, wasPlaying: true))

      return backend.loadCalls.count == 2
        && backend.loadCalls.last?.url == entry.url
        && backend.loadCalls.last?.position == 18
        && backend.loadCalls.last?.autoplay == true
        && player.currentEntry?.id == entry.id
        && player.playbackOccurrenceID == playbackOccurrence
        && player.isPlaying
    }()
    #expect(passed)
  }
}

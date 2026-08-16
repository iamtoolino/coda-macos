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
  func mpvNextRefreshNeverRemovesANumericPlaylistPosition() {
    let next = URL(string: "https://example.test/next.flac")!
    #expect(mpvExpectedNextCommands(next) == [
      ["playlist-clear"],
      ["loadfile", next.absoluteString, "insert-next"],
    ])
    #expect(mpvExpectedNextCommands(nil) == [["playlist-clear"]])
  }

  @Test("mpv advances Coda on the incoming file start")
  func mpvAdvancesCodaOnTheIncomingFileStart() {
    var tracker = MPVFileStartAdvanceTracker()
    tracker.reset(currentEntryID: 10, nextEntryID: 11)

    #expect(tracker.observeStart(entryID: 10) == .startedCurrent)
    #expect(tracker.observeStart(entryID: 11) == .automaticallyAdvanced)
    tracker.updateNext(entryID: 12)
    #expect(tracker.observeStart(entryID: 12) == .automaticallyAdvanced)
  }

  @Test("mpv ignores file starts from a replaced load")
  func mpvIgnoresFileStartsFromAReplacedLoad() {
    var tracker = MPVFileStartAdvanceTracker()
    tracker.reset(currentEntryID: 10, nextEntryID: 11)
    tracker.reset(currentEntryID: 20, nextEntryID: 21)

    #expect(tracker.observeStart(entryID: 10) == .ignored)
    #expect(tracker.observeStart(entryID: 20) == .startedCurrent)
    #expect(tracker.observeStart(entryID: 21) == .automaticallyAdvanced)
  }

  @Test("late mpv end event cannot finish the incoming file")
  func lateMpvEndEventCannotFinishTheIncomingFile() {
    #expect(mpvEndEventMatchesActiveFile(activeID: 12, endedID: 12))
    #expect(!mpvEndEventMatchesActiveFile(activeID: 12, endedID: 11))
    #expect(!mpvEndEventMatchesActiveFile(activeID: nil, endedID: 11))
  }

  @Test("automatic backend advance publishes the next queue entry")
  func automaticBackendAdvancePublishesTheNextQueueEntry() {
    let backend = TestPlaybackBackend()
    let first = QueueEntry(
      sourceID: "album-one-last",
      url: URL(string: "https://example.test/album-one-last")!,
      title: "Album One Last", album: "Album One")
    let second = QueueEntry(
      sourceID: "album-two-first",
      url: URL(string: "https://example.test/album-two-first")!,
      title: "Album Two First", album: "Album Two")
    let player = PlayerController(backend: backend)
    player.replaceQueue([first, second], startAt: 0, startsPlaying: true)
    let firstOccurrence = player.playbackOccurrenceID
    backend.emit(.automaticallyAdvanced)

    #expect(player.currentIndex == 1)
    #expect(player.currentEntry?.id == second.id)
    #expect(player.playbackOccurrenceID != firstOccurrence)
    #expect(player.currentEntry?.album == "Album Two")
    #expect(player.position == 0)
    #expect(player.duration == 0)
    #expect(backend.updatedNextURLs == [nil])
  }

  @Test("queue replacement can explicitly request the top")
  func queueReplacementCanExplicitlyRequestTheTop() {
    let backend = TestPlaybackBackend()
    let first = QueueEntry(
      sourceID: "first-queue", url: URL(string: "https://example.test/first-queue")!,
      title: "First Queue")
    let second = QueueEntry(
      sourceID: "second-queue", url: URL(string: "https://example.test/second-queue")!,
      title: "Second Queue")
    let player = PlayerController(backend: backend)
    let initialRequest = player.queueTopScrollRequest

    player.replaceQueue([first])
    #expect(player.queueTopScrollRequest == initialRequest)

    player.replaceQueue([second], scrollQueueToTop: true)
    #expect(player.queueTopScrollRequest == initialRequest + 1)
  }

  @Test("finishing the queue retains it without an active track")
  func finishingTheQueueRetainsItWithoutAnActiveTrack() {
    let backend = TestPlaybackBackend()
    let entry = QueueEntry(
      sourceID: "finished-track", url: URL(string: "https://example.test/finished-track")!,
      title: "Finished Track")
    let player = PlayerController(backend: backend)
    player.replaceQueue([entry], startsPlaying: true)
    backend.emit(.snapshot(PlaybackBackendSnapshot(position: 120, duration: 120, isPlaying: true)))
    backend.emit(.finished)

    #expect(player.queue.map(\.id) == [entry.id])
    #expect(player.currentIndex == nil)
    #expect(player.currentEntry == nil)
    #expect(player.playbackOccurrenceID == nil)
    #expect(!player.isPlaying)
    #expect(player.position == 0)
    #expect(player.duration == 0)
    #expect(player.status == "Finished")
  }

  @Test("restored queue loads paused at its saved position")
  func restoredQueueLoadsPausedAtItsSavedPosition() throws {
    let backend = TestPlaybackBackend()
    let entry = QueueEntry(
      sourceID: "restored-track", url: URL(string: "https://example.test/restored-track")!,
      title: "Restored Track")
    let player = PlayerController(backend: backend)
    player.replaceQueue([entry], positionSeconds: 83.25, startsPlaying: false)

    let load = try #require(backend.loadCalls.last)
    #expect(load.url == entry.url)
    #expect(load.position == 83.25)
    #expect(!load.autoplay)
    #expect(player.position == 83.25)
    #expect(!player.isPlaying)
  }

  @Test("volume level survives player recreation")
  func volumeLevelSurvivesPlayerRecreation() throws {
    let suiteName = "Coda.Tests.Volume.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let firstPlayer = PlayerController(backend: TestPlaybackBackend(), volumeDefaults: defaults)
    firstPlayer.setVolume(0.37)

    let restoredPlayer = PlayerController(backend: TestPlaybackBackend(), volumeDefaults: defaults)
    #expect(abs(restoredPlayer.volume - 0.37) < 0.000_001)
    #expect(!restoredPlayer.isMuted)
  }

  @Test("playback clock does not invalidate stable player state")
  func playbackClockDoesNotInvalidateStablePlayerState() {
    let backend = TestPlaybackBackend()
    let player = PlayerController(backend: backend)
    let entry = QueueEntry(
      sourceID: "clock-test", url: URL(string: "https://example.test/clock-test")!,
      title: "Clock Test")
    player.replaceQueue([entry], startsPlaying: true)

    var playerUpdates = 0
    var timelineUpdates = 0
    let playerToken = player.objectWillChange.sink { playerUpdates += 1 }
    let timelineToken = player.timeline.objectWillChange.sink { timelineUpdates += 1 }
    defer {
      playerToken.cancel()
      timelineToken.cancel()
    }

    backend.emit(.snapshot(PlaybackBackendSnapshot(
      position: 1, duration: 100, bufferedUntil: 30, isPlaying: true)))
    backend.emit(.snapshot(PlaybackBackendSnapshot(
      position: 1.25, duration: 100, bufferedUntil: 31, isPlaying: true)))

    #expect(playerUpdates == 0)
    #expect(timelineUpdates == 1)
    #expect(player.position == 1.25)
    #expect(player.duration == 100)
    #expect(player.bufferedUntil == 31)
  }

  @Test("playback clock adapts its publication rate to window visibility")
  func playbackClockAdaptsItsPublicationRateToWindowVisibility() {
    #expect(playbackTimelinePublicationInterval(windowIsVisible: true) == .milliseconds(250))
    #expect(playbackTimelinePublicationInterval(windowIsVisible: false) == .seconds(1))
  }

  @Test("reordering the playing album preserves playback identity")
  func reorderingThePlayingAlbumPreservesPlaybackIdentity() {
    let backend = TestPlaybackBackend()
    let player = PlayerController(backend: backend)
    let albumGroup = UUID()
    let first = QueueEntry(
      sourceID: "first", url: URL(string: "https://example.test/first")!,
      title: "First", queueGroupID: albumGroup)
    let playing = QueueEntry(
      sourceID: "playing", url: URL(string: "https://example.test/playing")!,
      title: "Playing", queueGroupID: albumGroup)
    let other = QueueEntry(
      sourceID: "other", url: URL(string: "https://example.test/other")!, title: "Other")
    player.replaceQueue([first, playing, other], startAt: 1, startsPlaying: true)
    let playbackOccurrence = player.playbackOccurrenceID
    backend.emit(.snapshot(PlaybackBackendSnapshot(
      position: 31, duration: 120, bufferedUntil: 80, isPlaying: true)))

    #expect(player.move(entryIDs: [first.id, playing.id], before: nil))
    #expect(player.queue.map(\.id) == [other.id, first.id, playing.id])
    #expect(player.currentEntry?.id == playing.id)
    #expect(player.currentIndex == 2)
    #expect(player.position == 31)
    #expect(player.duration == 120)
    #expect(player.isPlaying)
    #expect(player.playbackOccurrenceID == playbackOccurrence)
    #expect(backend.loadCalls.count == 1)
    #expect(backend.updatedNextURLs == [nil])
  }

  @Test("inserting library entries preserves playback identity")
  func insertingLibraryEntriesPreservesPlaybackIdentity() {
    let backend = TestPlaybackBackend()
    let player = PlayerController(backend: backend)
    let playing = QueueEntry(
      sourceID: "playing", url: URL(string: "https://example.test/playing")!, title: "Playing")
    let last = QueueEntry(
      sourceID: "last", url: URL(string: "https://example.test/last")!, title: "Last")
    let inserted = QueueEntry(
      sourceID: "inserted", url: URL(string: "https://example.test/inserted")!, title: "Inserted")
    player.replaceQueue([playing, last], startAt: 0, startsPlaying: true)
    backend.emit(.snapshot(PlaybackBackendSnapshot(position: 22, duration: 90, isPlaying: true)))

    player.insert([inserted], before: last.id)
    #expect(player.queue.map(\.id) == [playing.id, inserted.id, last.id])
    #expect(player.currentEntry?.id == playing.id)
    #expect(player.currentIndex == 0)
    #expect(player.position == 22)
    #expect(player.isPlaying)
    #expect(backend.loadCalls.count == 1)
    #expect(backend.updatedNextURLs.last == inserted.url)
  }

  @Test("unexpected mpv idle reloads a playing item once")
  func unexpectedMpvIdleReloadsAPlayingItemOnce() {
    let backend = TestPlaybackBackend()
    let player = PlayerController(backend: backend)
    let entry = QueueEntry(
      sourceID: "one", url: URL(string: "https://example.test/one")!, title: "One")
    player.replaceQueue([entry], positionSeconds: 12, startsPlaying: true)
    let playbackOccurrence = player.playbackOccurrenceID
    backend.emit(.snapshot(PlaybackBackendSnapshot(position: 18, duration: 100, isPlaying: true)))
    backend.hasLoadedItem = false
    backend.emit(.unexpectedlyBecameIdle(position: 18, wasPlaying: true))

    #expect(backend.loadCalls.count == 2)
    #expect(backend.loadCalls.last?.url == entry.url)
    #expect(backend.loadCalls.last?.position == 18)
    #expect(backend.loadCalls.last?.autoplay == true)
    #expect(player.currentEntry?.id == entry.id)
    #expect(player.playbackOccurrenceID == playbackOccurrence)
    #expect(player.isPlaying)
  }
}

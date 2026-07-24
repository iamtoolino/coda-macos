import CMpv
import Foundation

struct PlaybackBackendSnapshot: Sendable {
  var position: Double = 0
  var duration: Double = 0
  var bufferedUntil: Double = 0
  var isPlaying = false
  var isBuffering = false
}

enum PlaybackBackendEvent: Sendable {
  case snapshot(PlaybackBackendSnapshot)
  case automaticallyAdvanced
  case unexpectedlyBecameIdle(position: Double, wasPlaying: Bool)
  case finished
  case failed(String)
}

func mpvExpectedNextCommands(_ next: URL?) -> [[String]] {
  var commands = [["playlist-clear"]]
  if let next {
    commands.append(["loadfile", next.absoluteString, "insert-next"])
  }
  return commands
}

struct MPVFileStartAdvanceTracker {
  private(set) var hasStartedCurrentItem = false

  mutating func reset() {
    hasStartedCurrentItem = false
  }

  mutating func observeStart(hasExpectedNext: Bool) -> Bool {
    let didAdvance = hasStartedCurrentItem && hasExpectedNext
    hasStartedCurrentItem = true
    return didAdvance
  }
}

func mpvEndEventMatchesActiveFile(activeID: Int64?, endedID: Int64) -> Bool {
  guard let activeID else { return false }
  return activeID == endedID
}

@MainActor
protocol PlaybackBackend: AnyObject {
  var name: String { get }
  var hasLoadedItem: Bool { get }
  var eventHandler: ((PlaybackBackendEvent) -> Void)? { get set }

  func load(current: URL, next: URL?, position: Double, autoplay: Bool)
  func updateNext(_ next: URL?)
  func promoteAutomaticallyAdvancedItem(following: URL?)
  func play()
  func pause()
  func seek(to seconds: Double)
  func clear()
  func setVolume(_ volume: Double)
  func setMuted(_ muted: Bool)
  func shutdown()
}

extension PlaybackBackend {
  func shutdown() {}
}

@MainActor
enum PlaybackBackendFactory {
  static func make() -> any PlaybackBackend {
    guard let backend = LibMPVPlaybackBackend() else {
      fatalError("Coda could not initialize its embedded libmpv playback engine.")
    }
    return backend
  }
}

@MainActor
private final class LibMPVPlaybackBackend: PlaybackBackend {
  let name = "Embedded libmpv / CoreAudio"
  var eventHandler: ((PlaybackBackendEvent) -> Void)?
  private(set) var hasLoadedItem = false

  private let engine: OpaquePointer
  private var snapshot = PlaybackBackendSnapshot()
  private var fileStartAdvanceTracker = MPVFileStartAdvanceTracker()
  private var activePlaylistEntryID: Int64?
  private var hasExpectedNext = false
  private var isLoadingItem = false
  private var intentionallyStopping = false
  private var eventDrainScheduled = false

  private nonisolated static let wakeupCallback: CodaMPVWakeupCallback = { context in
    guard let context else { return }
    let backend = Unmanaged<LibMPVPlaybackBackend>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
      backend.drainEvents()
    }
  }

  init?() {
    guard let engine = coda_mpv_create() else { return nil }
    self.engine = engine
    coda_mpv_set_wakeup_callback(
      engine,
      Self.wakeupCallback,
      Unmanaged.passUnretained(self).toOpaque()
    )
    drainEvents()
  }

  func shutdown() {
    intentionallyStopping = true
    coda_mpv_set_wakeup_callback(engine, nil, nil)
    coda_mpv_destroy(engine)
  }

  func load(current: URL, next: URL?, position: Double, autoplay: Bool) {
    hasLoadedItem = true
    hasExpectedNext = next != nil
    isLoadingItem = true
    fileStartAdvanceTracker.reset()
    activePlaylistEntryID = nil
    snapshot = PlaybackBackendSnapshot(position: max(0, position), isPlaying: autoplay)
    eventHandler?(.snapshot(snapshot))

    current.absoluteString.withCString { currentURL in
      if let next {
        next.absoluteString.withCString { nextURL in
          coda_mpv_load(engine, currentURL, nextURL, max(0, position), autoplay)
        }
      } else {
        coda_mpv_load(engine, currentURL, nil, max(0, position), autoplay)
      }
    }
  }

  func updateNext(_ next: URL?) {
    withOptionalCString(next?.absoluteString) { nextURL in
      coda_mpv_update_next(engine, nextURL)
    }
    hasExpectedNext = next != nil
  }

  func promoteAutomaticallyAdvancedItem(following: URL?) {
    updateNext(following)
  }

  func play() {
    coda_mpv_set_paused(engine, false)
  }

  func pause() {
    coda_mpv_set_paused(engine, true)
  }

  func seek(to seconds: Double) {
    snapshot.position = max(0, seconds)
    eventHandler?(.snapshot(snapshot))
    coda_mpv_seek(engine, max(0, seconds))
  }

  func clear() {
    intentionallyStopping = true
    coda_mpv_stop(engine)
    intentionallyStopping = false
    hasLoadedItem = false
    hasExpectedNext = false
    isLoadingItem = false
    fileStartAdvanceTracker.reset()
    activePlaylistEntryID = nil
    snapshot = PlaybackBackendSnapshot()
    eventHandler?(.snapshot(snapshot))
  }

  func setVolume(_ volume: Double) {
    coda_mpv_set_volume(engine, min(max(volume, 0), 1))
  }

  func setMuted(_ muted: Bool) {
    coda_mpv_set_muted(engine, muted)
  }

  private func drainEvents() {
    var event = CodaMPVEvent(
      type: CODA_MPV_EVENT_NONE,
      playlist_entry_id: 0,
      position: 0,
      duration: 0,
      buffered_until: 0,
      is_playing: false,
      is_buffering: false,
      is_idle: false
    )
    while coda_mpv_next_event(engine, &event) {
      handle(event)
    }
  }

  private func handle(_ event: CodaMPVEvent) {
    switch event.type {
    case CODA_MPV_EVENT_SNAPSHOT:
      updateSnapshot(from: event)
    case CODA_MPV_EVENT_START_FILE:
      activePlaylistEntryID = event.playlist_entry_id
      if fileStartAdvanceTracker.observeStart(hasExpectedNext: hasExpectedNext) {
        eventHandler?(.automaticallyAdvanced)
      }
    case CODA_MPV_EVENT_END_FILE_EOF:
      guard mpvEndEventMatchesActiveFile(
        activeID: activePlaylistEntryID,
        endedID: event.playlist_entry_id
      ) else { return }
      if !hasExpectedNext {
        hasLoadedItem = false
        isLoadingItem = false
        activePlaylistEntryID = nil
        eventHandler?(.finished)
      }
    case CODA_MPV_EVENT_END_FILE_ERROR:
      guard mpvEndEventMatchesActiveFile(
        activeID: activePlaylistEntryID,
        endedID: event.playlist_entry_id
      ) else { return }
      hasLoadedItem = false
      isLoadingItem = false
      activePlaylistEntryID = nil
      eventHandler?(.failed("libmpv could not play the stream."))
    case CODA_MPV_EVENT_PLAYBACK_READY:
      hasLoadedItem = true
      isLoadingItem = false
    case CODA_MPV_EVENT_IDLE_CHANGED:
      updateSnapshot(from: event)
      if !event.is_idle {
        hasLoadedItem = true
        return
      }

      let wasLoaded = hasLoadedItem
      let wasPlaying = snapshot.isPlaying
      snapshot.isPlaying = false
      if !isLoadingItem {
        hasLoadedItem = false
      }
      eventHandler?(.snapshot(snapshot))
      if wasLoaded, !isLoadingItem, !intentionallyStopping {
        eventHandler?(
          .unexpectedlyBecameIdle(position: snapshot.position, wasPlaying: wasPlaying)
        )
      }
    case CODA_MPV_EVENT_SHUTDOWN:
      if !intentionallyStopping {
        eventHandler?(.failed("The embedded libmpv engine shut down unexpectedly."))
      }
    default:
      break
    }
  }

  private func updateSnapshot(from event: CodaMPVEvent) {
    snapshot = PlaybackBackendSnapshot(
      position: event.position.isFinite ? max(0, event.position) : 0,
      duration: event.duration.isFinite ? max(0, event.duration) : 0,
      bufferedUntil: event.buffered_until.isFinite ? max(0, event.buffered_until) : 0,
      isPlaying: hasLoadedItem && event.is_playing,
      isBuffering: event.is_buffering
    )
    eventHandler?(.snapshot(snapshot))
  }

  private func withOptionalCString<Result>(
    _ value: String?,
    body: (UnsafePointer<CChar>?) -> Result
  ) -> Result {
    guard let value else { return body(nil) }
    return value.withCString(body)
  }
}

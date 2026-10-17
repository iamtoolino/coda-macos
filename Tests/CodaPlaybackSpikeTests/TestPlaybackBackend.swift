import Foundation

@testable import CodaPlaybackSpike

@MainActor
final class TestPlaybackBackend: PlaybackBackend {
  struct LoadCall {
    let url: URL
    let next: URL?
    let position: Double
    let autoplay: Bool
    let currentItem: PlaybackBackendItem
    let nextItem: PlaybackBackendItem?
  }

  let name = "Test"
  var hasLoadedItem = false
  var eventHandler: ((PlaybackBackendEvent) -> Void)?
  private(set) var loadCalls: [LoadCall] = []
  private(set) var updatedNextURLs: [URL?] = []
  private(set) var updatedNextItems: [PlaybackBackendItem?] = []
  private(set) var replayGains: [Double] = []

  func load(current: PlaybackBackendItem, next: PlaybackBackendItem?, position: Double, autoplay: Bool) {
    hasLoadedItem = true
    loadCalls.append(LoadCall(url: current.url, next: next?.url, position: position,
                              autoplay: autoplay, currentItem: current, nextItem: next))
  }

  func updateNext(_ next: PlaybackBackendItem?) {
    updatedNextURLs.append(next?.url)
    updatedNextItems.append(next)
  }

  func promoteAutomaticallyAdvancedItem(following: PlaybackBackendItem?) {
    updateNext(following)
  }

  func play() {}
  func pause() {}
  func seek(to seconds: Double) {}

  func clear() {
    hasLoadedItem = false
  }

  func setVolume(_ volume: Double) {}
  func setMuted(_ muted: Bool) {}
  func setReplayGain(_ gainDb: Double) { replayGains.append(gainDb) }

  func emit(_ event: PlaybackBackendEvent) {
    eventHandler?(event)
  }
}

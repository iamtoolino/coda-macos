import Foundation

@testable import CodaPlaybackSpike

@MainActor
final class TestPlaybackBackend: PlaybackBackend {
  struct LoadCall {
    let url: URL
    let next: URL?
    let position: Double
    let autoplay: Bool
  }

  let name = "Test"
  var hasLoadedItem = false
  var eventHandler: ((PlaybackBackendEvent) -> Void)?
  private(set) var loadCalls: [LoadCall] = []
  private(set) var updatedNextURLs: [URL?] = []

  func load(current: URL, next: URL?, position: Double, autoplay: Bool) {
    hasLoadedItem = true
    loadCalls.append(LoadCall(url: current, next: next, position: position, autoplay: autoplay))
  }

  func updateNext(_ next: URL?) {
    updatedNextURLs.append(next)
  }

  func promoteAutomaticallyAdvancedItem(following: URL?) {
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

  func emit(_ event: PlaybackBackendEvent) {
    eventHandler?(event)
  }
}

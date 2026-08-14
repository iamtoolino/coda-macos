import Combine
import Foundation
import MediaPlayer

func playbackTimelinePublicationInterval(windowIsVisible: Bool) -> Duration {
  windowIsVisible ? .milliseconds(250) : .seconds(1)
}

@MainActor
final class PlaybackTimeline: ObservableObject {
  struct Snapshot: Equatable {
    var position: Double = 0
    var duration: Double = 0
  }

  @Published private(set) var snapshot = Snapshot()
  private var latestSnapshot = Snapshot()

  var position: Double { latestSnapshot.position }
  var duration: Double { latestSnapshot.duration }

  func update(position: Double, duration: Double, publish: Bool = true) {
    let replacement = Snapshot(
      position: position,
      duration: duration
    )
    latestSnapshot = replacement
    if publish {
      publishLatest()
    }
  }

  func publishLatest() {
    guard latestSnapshot != snapshot else { return }
    snapshot = latestSnapshot
  }

  func setPosition(_ position: Double) {
    update(
      position: position,
      duration: latestSnapshot.duration
    )
  }

  func reset(position: Double = 0) {
    update(position: position, duration: 0)
  }
}

@MainActor
final class PlayerController: ObservableObject {
  private static let storedVolumeKey = "playback-volume"

  @Published private(set) var queue: [QueueEntry] = []
  @Published private(set) var currentIndex: Int?
  @Published private(set) var playbackOccurrenceID: UUID?
  @Published private(set) var isPlaying = false
  @Published private(set) var status = "Nothing queued"
  @Published private(set) var errorMessage: String?
  @Published private(set) var volume: Double = 1
  @Published private(set) var isMuted = false
  @Published private(set) var playbackEngineName = "Unknown"
  @Published private(set) var queueTopScrollRequest = 0
  private(set) var bufferedUntil: Double = 0

  let timeline = PlaybackTimeline()

  private var backend: any PlaybackBackend
  private let volumeDefaults: UserDefaults?
  private var remoteCommandTokens: [(MPRemoteCommand, Any)] = []
  private var lastAudibleVolume: Double = 1
  private var automaticIdleRecoveryAttempts = 0
  private var automaticIdleRecoveryPosition: Double?
  private var timelinePublicationTask: Task<Void, Never>?
  private var isPlaybackWindowVisible = true

  var position: Double { timeline.position }
  var duration: Double { timeline.duration }

  var currentEntry: QueueEntry? {
    guard let currentIndex, queue.indices.contains(currentIndex) else { return nil }
    return queue[currentIndex]
  }

  var nextEntry: QueueEntry? {
    guard let currentIndex, queue.indices.contains(currentIndex + 1) else { return nil }
    return queue[currentIndex + 1]
  }

  var canGoPrevious: Bool {
    guard let currentIndex else { return false }
    return currentIndex > 0 || position > 3
  }

  var canGoNext: Bool {
    guard let currentIndex else { return false }
    return queue.indices.contains(currentIndex + 1)
  }

  var audibleVolume: Double {
    isMuted ? 0 : volume
  }

  var isEffectivelyMuted: Bool {
    isMuted || volume <= 0.001
  }

  func setPlaybackWindowVisible(_ isVisible: Bool) {
    guard isPlaybackWindowVisible != isVisible else { return }
    isPlaybackWindowVisible = isVisible
    restartTimelinePublicationTask()
  }

  convenience init() {
    self.init(
      backend: PlaybackBackendFactory.make(),
      volumeDefaults: .standard
    )
  }

  init(
    backend: any PlaybackBackend,
    volumeDefaults: UserDefaults? = nil
  ) {
    self.backend = backend
    self.volumeDefaults = volumeDefaults
    if let savedVolume = volumeDefaults?.object(forKey: Self.storedVolumeKey) as? NSNumber {
      let restoredVolume = savedVolume.doubleValue
      if restoredVolume.isFinite {
        volume = min(max(restoredVolume, 0), 1)
      }
    }
    lastAudibleVolume = volume > 0.001 ? volume : 0.25
    playbackEngineName = backend.name
    backend.eventHandler = { [weak self] event in
      self?.handleBackendEvent(event)
    }
    backend.setVolume(volume)
    backend.setMuted(isMuted)
    configureRemoteCommands()
  }

  func enqueue(_ entries: [QueueEntry], startPlayingIfEmpty: Bool = false) {
    guard !entries.isEmpty else { return }
    let oldCount = queue.count
    let wasEmpty = queue.isEmpty
    queue.append(contentsOf: entries)

    if wasEmpty {
      load(index: 0, position: 0, autoplay: startPlayingIfEmpty)
      return
    }

    if !backend.hasLoadedItem {
      load(index: oldCount, position: 0, autoplay: startPlayingIfEmpty)
      return
    }

    synchronizeNextItem()
  }

  func insert(_ entries: [QueueEntry], before targetID: UUID?) {
    guard !entries.isEmpty else { return }
    guard !queue.isEmpty else {
      enqueue(entries)
      return
    }

    var updatedQueue = queue
    let insertionIndex = targetID.flatMap { target in
      updatedQueue.firstIndex(where: { $0.id == target })
    } ?? updatedQueue.endIndex
    updatedQueue.insert(contentsOf: entries, at: insertionIndex)
    applyReorderedQueue(updatedQueue)
  }

  func replaceQueue(
    _ entries: [QueueEntry],
    startAt index: Int = 0,
    positionSeconds: Double = 0,
    startsPlaying: Bool = true,
    scrollQueueToTop: Bool = false
  ) {
    backend.clear()
    queue = entries
    if scrollQueueToTop, !entries.isEmpty {
      queueTopScrollRequest &+= 1
    }
    guard !entries.isEmpty else {
      resetPublishedState()
      return
    }

    let boundedIndex = max(0, min(index, entries.count - 1))
    load(
      index: boundedIndex,
      position: max(0, positionSeconds),
      autoplay: startsPlaying
    )
  }

  func report(error: Error) {
    errorMessage = error.localizedDescription
    status = "Playback failed"
  }

  func play(index: Int) {
    guard queue.indices.contains(index) else { return }
    load(index: index, position: 0, autoplay: true)
  }

  func play() {
    guard let currentIndex, queue.indices.contains(currentIndex) else { return }
    errorMessage = nil
    if backend.hasLoadedItem {
      backend.play()
      isPlaying = true
      status = "Playing"
      restartTimelinePublicationTask()
      updateNowPlayingInfo()
    } else {
      load(index: currentIndex, position: position, autoplay: true)
    }
  }

  func pause() {
    backend.pause()
    isPlaying = false
    status = currentEntry == nil ? "Nothing queued" : "Paused"
    restartTimelinePublicationTask()
    updateNowPlayingInfo()
  }

  func togglePlayback() {
    isPlaying ? pause() : play()
  }

  func setVolume(_ newValue: Double) {
    guard newValue.isFinite else { return }
    let bounded = min(max(newValue, 0), 1)
    volume = bounded
    if bounded > 0.001 {
      lastAudibleVolume = bounded
    }
    isMuted = false
    backend.setMuted(false)
    backend.setVolume(bounded)
    persistVolume()
  }

  func toggleMute() {
    if isEffectivelyMuted {
      if volume <= 0.001 {
        volume = max(lastAudibleVolume, 0.25)
        backend.setVolume(volume)
        persistVolume()
      }
      isMuted = false
      backend.setMuted(false)
    } else {
      lastAudibleVolume = volume
      isMuted = true
      backend.setMuted(true)
    }
  }

  func next() {
    guard let currentIndex, queue.indices.contains(currentIndex + 1) else { return }
    load(index: currentIndex + 1, position: 0, autoplay: isPlaying)
  }

  func previous() {
    guard let currentIndex else { return }
    if position > 3 || currentIndex == 0 {
      seek(to: 0)
    } else {
      load(index: currentIndex - 1, position: 0, autoplay: isPlaying)
    }
  }

  func seek(to seconds: Double) {
    guard seconds.isFinite else { return }
    let bounded = max(0, duration > 0 ? min(seconds, duration) : seconds)
    backend.seek(to: bounded)
    timeline.setPosition(bounded)
    updateNowPlayingInfo()
  }

  func remove(entryID: UUID) {
    remove(entryIDs: [entryID])
  }

  func remove(entryIDs: [UUID]) {
    let removedIDs = Set(entryIDs)
    guard !removedIDs.isEmpty, queue.contains(where: { removedIDs.contains($0.id) }) else {
      return
    }

    let oldQueue = queue
    let oldCurrentEntry = currentEntry
    let newQueue = oldQueue.filter { !removedIDs.contains($0.id) }

    guard let oldCurrentEntry, removedIDs.contains(oldCurrentEntry.id) else {
      applyReorderedQueue(newQueue)
      return
    }

    let wasPlaying = isPlaying
    let oldCurrentIndex = oldQueue.firstIndex(where: { $0.id == oldCurrentEntry.id }) ?? 0
    let replacement = oldQueue.dropFirst(oldCurrentIndex + 1).first {
      !removedIDs.contains($0.id)
    } ?? oldQueue.prefix(oldCurrentIndex).last { !removedIDs.contains($0.id) }

    queue = newQueue
    guard let replacement,
      let replacementIndex = newQueue.firstIndex(where: { $0.id == replacement.id })
    else {
      clear()
      return
    }

    load(index: replacementIndex, position: 0, autoplay: wasPlaying)
  }

  @discardableResult
  func move(entryIDs: [UUID], before targetID: UUID?) -> Bool {
    guard let reorderedIDs = reorderedQueueIDs(
      queue.map(\.id), moving: entryIDs, before: targetID)
    else { return false }
    let entriesByID = Dictionary(uniqueKeysWithValues: queue.map { ($0.id, $0) })
    let reordered = reorderedIDs.compactMap { entriesByID[$0] }
    guard reordered.count == queue.count else { return false }
    applyReorderedQueue(reordered)
    return true
  }

  func clear() {
    backend.clear()
    queue.removeAll()
    resetPublishedState()
  }

  private func load(
    index: Int,
    position: Double,
    autoplay: Bool,
    isAutomaticIdleRecovery: Bool = false
  ) {
    guard queue.indices.contains(index) else { return }
    if !isAutomaticIdleRecovery {
      automaticIdleRecoveryAttempts = 0
      automaticIdleRecoveryPosition = nil
    }
    currentIndex = index
    if !isAutomaticIdleRecovery || playbackOccurrenceID == nil {
      playbackOccurrenceID = UUID()
    }
    timeline.reset(position: max(0, position))
    bufferedUntil = 0
    errorMessage = nil
    isPlaying = autoplay
    status = autoplay ? "Playing" : "Ready"
    restartTimelinePublicationTask()
    backend.load(
      current: queue[index].url,
      next: queue.indices.contains(index + 1) ? queue[index + 1].url : nil,
      position: timeline.position,
      autoplay: autoplay
    )
    updateNowPlayingInfo()
  }

  private func synchronizeNextItem() {
    guard let currentIndex, backend.hasLoadedItem else { return }
    let next = queue.indices.contains(currentIndex + 1) ? queue[currentIndex + 1].url : nil
    backend.updateNext(next)
  }

  private func applyReorderedQueue(_ reordered: [QueueEntry]) {
    guard let currentEntry,
      let newCurrentIndex = reordered.firstIndex(where: { $0.id == currentEntry.id })
    else {
      queue = reordered
      if reordered.isEmpty { clear() }
      return
    }

    queue = reordered
    currentIndex = newCurrentIndex
    synchronizeNextItem()
    updateNowPlayingInfo()
  }

  private func handleBackendEvent(_ event: PlaybackBackendEvent) {
    switch event {
    case .snapshot(let snapshot):
      guard currentEntry != nil else { return }
      let previousDuration = duration
      let playingChanged = isPlaying != snapshot.isPlaying
      timeline.update(
        position: snapshot.position,
        duration: snapshot.duration,
        publish: playingChanged || abs(previousDuration - snapshot.duration) > 0.5
      )
      bufferedUntil = snapshot.bufferedUntil
      if playingChanged {
        isPlaying = snapshot.isPlaying
        restartTimelinePublicationTask()
      }
      let newStatus: String
      if snapshot.isBuffering {
        newStatus = "Buffering"
      } else if snapshot.isPlaying {
        newStatus = "Playing"
      } else if errorMessage == nil {
        newStatus = "Paused"
      } else {
        newStatus = status
      }
      if status != newStatus {
        status = newStatus
      }
      if snapshot.isPlaying,
        let recoveryPosition = automaticIdleRecoveryPosition,
        snapshot.position >= recoveryPosition + 1
      {
        automaticIdleRecoveryAttempts = 0
        automaticIdleRecoveryPosition = nil
      }
      if playingChanged || abs(previousDuration - snapshot.duration) > 0.5 {
        updateNowPlayingInfo()
      }

    case .automaticallyAdvanced:
      guard let currentIndex, queue.indices.contains(currentIndex + 1) else {
        handleBackendEvent(.finished)
        return
      }
      let nextIndex = currentIndex + 1
      automaticIdleRecoveryAttempts = 0
      automaticIdleRecoveryPosition = nil
      self.currentIndex = nextIndex
      playbackOccurrenceID = UUID()
      timeline.reset()
      bufferedUntil = 0
      errorMessage = nil
      let following = queue.indices.contains(nextIndex + 1) ? queue[nextIndex + 1].url : nil
      backend.promoteAutomaticallyAdvancedItem(following: following)
      status = isPlaying ? "Playing" : "Ready"
      restartTimelinePublicationTask()
      updateNowPlayingInfo()

    case .unexpectedlyBecameIdle(let lastPosition, let wasPlaying):
      guard let currentIndex, queue.indices.contains(currentIndex) else { return }
      isPlaying = false
      timeline.setPosition(max(position, lastPosition))
      status = "Playback interrupted"
      restartTimelinePublicationTask()
      updateNowPlayingInfo()

      guard wasPlaying, automaticIdleRecoveryAttempts == 0 else { return }
      automaticIdleRecoveryAttempts = 1
      let wasAtTrackEnd = duration > 0 && position >= duration - 1
        && queue.indices.contains(currentIndex + 1)
      let recoveryIndex = wasAtTrackEnd ? currentIndex + 1 : currentIndex
      let recoveryPosition = wasAtTrackEnd ? 0 : position
      automaticIdleRecoveryPosition = recoveryPosition
      load(
        index: recoveryIndex,
        position: recoveryPosition,
        autoplay: true,
        isAutomaticIdleRecovery: true
      )

    case .finished:
      currentIndex = nil
      playbackOccurrenceID = nil
      isPlaying = false
      timeline.reset()
      bufferedUntil = 0
      status = "Finished"
      restartTimelinePublicationTask()
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      MPNowPlayingInfoCenter.default().playbackState = .stopped

    case .failed(let message):
      isPlaying = false
      errorMessage = message
      status = "Playback failed"
      restartTimelinePublicationTask()
      updateNowPlayingInfo()
    }
  }

  private func resetPublishedState() {
    currentIndex = nil
    playbackOccurrenceID = nil
    isPlaying = false
    restartTimelinePublicationTask()
    timeline.reset()
    bufferedUntil = 0
    status = "Nothing queued"
    errorMessage = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    MPNowPlayingInfoCenter.default().playbackState = .stopped
  }

  private func persistVolume() {
    volumeDefaults?.set(volume, forKey: Self.storedVolumeKey)
  }

  private func restartTimelinePublicationTask() {
    timelinePublicationTask?.cancel()
    timelinePublicationTask = nil
    timeline.publishLatest()
    guard isPlaying else { return }

    timelinePublicationTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        let interval = playbackTimelinePublicationInterval(
          windowIsVisible: self.isPlaybackWindowVisible
        )
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled, self.isPlaying else { return }
        self.timeline.publishLatest()
      }
    }
  }

  private func configureRemoteCommands() {
    let commands = MPRemoteCommandCenter.shared()

    commands.playCommand.isEnabled = true
    remoteCommandTokens.append(
      (
        commands.playCommand,
        commands.playCommand.addTarget { [weak self] _ in
          Task { @MainActor [weak self] in self?.play() }
          return .success
        }
      ))

    commands.pauseCommand.isEnabled = true
    remoteCommandTokens.append(
      (
        commands.pauseCommand,
        commands.pauseCommand.addTarget { [weak self] _ in
          Task { @MainActor [weak self] in self?.pause() }
          return .success
        }
      ))

    commands.togglePlayPauseCommand.isEnabled = true
    remoteCommandTokens.append(
      (
        commands.togglePlayPauseCommand,
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
          Task { @MainActor [weak self] in self?.togglePlayback() }
          return .success
        }
      ))

    commands.nextTrackCommand.isEnabled = true
    remoteCommandTokens.append(
      (
        commands.nextTrackCommand,
        commands.nextTrackCommand.addTarget { [weak self] _ in
          Task { @MainActor [weak self] in self?.next() }
          return .success
        }
      ))

    commands.previousTrackCommand.isEnabled = true
    remoteCommandTokens.append(
      (
        commands.previousTrackCommand,
        commands.previousTrackCommand.addTarget { [weak self] _ in
          Task { @MainActor [weak self] in self?.previous() }
          return .success
        }
      ))

    commands.changePlaybackPositionCommand.isEnabled = true
    remoteCommandTokens.append(
      (
        commands.changePlaybackPositionCommand,
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
          guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
            return .commandFailed
          }
          Task { @MainActor [weak self] in self?.seek(to: positionEvent.positionTime) }
          return .success
        }
      ))
  }

  private func updateNowPlayingInfo() {
    guard let entry = currentEntry else { return }
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: entry.title,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
    ]
    if !entry.artist.isEmpty { info[MPMediaItemPropertyArtist] = entry.artist }
    if !entry.album.isEmpty { info[MPMediaItemPropertyAlbumTitle] = entry.album }
    if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
  }
}

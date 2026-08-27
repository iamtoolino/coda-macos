import AppKit
import Combine
import Foundation

struct QueueHandoffSnapshot: Equatable, Sendable {
  let songIDs: [String]
  let currentIndex: Int
  let positionMilliseconds: Int64

  init(queue: [QueueEntry], currentIndex: Int?, positionSeconds: Double) {
    guard !queue.isEmpty, let currentIndex else {
      songIDs = []
      self.currentIndex = 0
      positionMilliseconds = 0
      return
    }

    songIDs = queue.map(\.sourceID)
    self.currentIndex = max(0, min(currentIndex, songIDs.count - 1))

    let milliseconds = max(0, positionSeconds.isFinite ? positionSeconds : 0) * 1_000
    positionMilliseconds =
      milliseconds >= Double(Int64.max) ? Int64.max : Int64(milliseconds.rounded())
  }
}

enum QueueHandoffDisposition: Equatable {
  case restore
  case offer
  case ignore
}

func queueHandoffDisposition(
  for queue: RemotePlayQueue?,
  allowsOwnedQueueRestore: Bool,
  localQueueIsEmpty: Bool,
  localPlaybackIsPlaying: Bool,
  queueWasHandled: Bool
) -> QueueHandoffDisposition {
  guard let queue, !queue.songs.isEmpty, !queueWasHandled, !localPlaybackIsPlaying else {
    return .ignore
  }
  if queue.wasWrittenByThisCoda {
    return allowsOwnedQueueRestore && localQueueIsEmpty ? .restore : .ignore
  }
  return .offer
}

@MainActor
private final class FirstAsyncCompletion {
  private var continuation: CheckedContinuation<Void, Never>?

  init(_ continuation: CheckedContinuation<Void, Never>) {
    self.continuation = continuation
  }

  func finish() {
    guard let continuation else { return }
    self.continuation = nil
    continuation.resume()
  }
}

@MainActor
func awaitOperationUntilDeadline(
  _ timeout: Duration,
  operation: @escaping @Sendable () async -> Void
) async {
  await withCheckedContinuation { continuation in
    let completion = FirstAsyncCompletion(continuation)
    let operationTask = Task {
      await operation()
      completion.finish()
    }
    Task {
      try? await Task.sleep(for: timeout)
      operationTask.cancel()
      completion.finish()
    }
  }
}

@MainActor
final class QueueHandoffCoordinator: ObservableObject {
  private enum Ownership: Equatable {
    case none
    case awaitingInitialQueue(UUID)
    case local
  }

  private enum RefreshResult: Sendable {
    case success(RemotePlayQueue?)
    case failure
  }

  private struct SaveRequest: Sendable {
    let generation: UUID
    let sessionID: UUID
    let client: NavidromeClient
    let snapshot: QueueHandoffSnapshot
    let isPauseBoundary: Bool
  }

  private let session: AppSession
  private let player: PlayerController
  private var cancellables: Set<AnyCancellable> = []
  private var scheduledSaveTask: Task<Void, Never>?
  private var saveWorkerTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var periodicSaveTask: Task<Void, Never>?
  private var periodicRefreshTask: Task<Void, Never>?
  private var lifecycleRefreshTask: Task<Void, Never>?
  private var pendingRequest: SaveRequest?
  private var saveGeneration = UUID()
  private var saveWorkerID: UUID?
  private var refreshID: UUID?
  private var ownership: Ownership = .none
  private var pauseSavePending = false

  @Published private(set) var continueQueue: RemotePlayQueue?

  init(session: AppSession, player: PlayerController) {
    self.session = session
    self.player = player
    observePlayback()
    observeApplicationLifecycle()
    startPeriodicSaves()
    startPeriodicRefreshes()
  }

  func saveBeforeTermination(timeout: Duration = .seconds(1)) async {
    guard ownership == .local, let client = session.client,
      session.activeSessionID != nil
    else { return }

    cancelSavePipeline()

    let snapshot = QueueHandoffSnapshot(
      queue: player.queue,
      currentIndex: player.currentIndex,
      positionSeconds: player.position
    )

    await awaitOperationUntilDeadline(timeout) {
      try? await client.savePlayQueue(
        songIDs: snapshot.songIDs,
        currentIndex: snapshot.currentIndex,
        positionMilliseconds: snapshot.positionMilliseconds
      )
    }
  }

  func observeRemoteQueue(_ queue: RemotePlayQueue?) {
    applyRemoteQueue(queue, allowsOwnedQueueRestore: false)
  }

  func continuePlaying() {
    guard let queue = continueQueue else { return }
    session.markPlayQueueHandled(queue)
    takeLocalQueueOwnership()
    session.play(
      songs: queue.songs,
      startAt: queue.resolvedCurrentIndex,
      positionMilliseconds: queue.position ?? 0,
      scrollQueueToCurrent: true,
      with: player
    )
  }

  func refreshRemoteQueue() async {
    if let refreshTask {
      await refreshTask.value
      return
    }
    guard !player.isPlaying, !pauseSavePending, let client = session.client,
      let sessionID = session.activeSessionID
    else { return }

    let id = UUID()
    let allowsOwnedQueueRestore = ownership == .awaitingInitialQueue(sessionID)
    refreshID = id
    let task = Task { @MainActor [weak self] in
      let result: RefreshResult
      do {
        result = .success(try await client.playQueue())
      } catch {
        result = .failure
      }
      guard let self, self.refreshID == id, self.session.activeSessionID == sessionID else {
        return
      }
      self.refreshID = nil
      self.refreshTask = nil
      if allowsOwnedQueueRestore, self.ownership == .awaitingInitialQueue(sessionID) {
        self.ownership = .none
      }
      guard case .success(let queue) = result, !self.player.isPlaying,
        !self.pauseSavePending
      else { return }
      self.applyRemoteQueue(queue, allowsOwnedQueueRestore: allowsOwnedQueueRestore)
    }
    refreshTask = task
    await task.value
  }

  private func observePlayback() {
    player.$queue
      .map { $0.map(\.sourceID) }
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.takeLocalQueueOwnership()
          self.scheduleSave(
            after: self.player.isPlaying ? .milliseconds(250) : .zero,
            isPauseBoundary: !self.player.isPlaying
          )
        }
      }
      .store(in: &cancellables)

    player.$currentIndex
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.ownership == .local, self.player.isPlaying else { return }
          self.scheduleSave(after: .milliseconds(500))
        }
      }
      .store(in: &cancellables)

    player.$isPlaying
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] isPlaying in
        Task { @MainActor [weak self] in
          guard let self else { return }
          if isPlaying {
            self.pauseSavePending = false
            self.takeLocalQueueOwnership()
            self.scheduleSave(after: .milliseconds(500))
          } else if self.ownership == .local {
            // One final handoff snapshot at the pause boundary. No later paused-state
            // event is permitted to write to the shared server queue.
            self.scheduleSave(after: .zero, isPauseBoundary: true)
          }
        }
      }
      .store(in: &cancellables)

    session.$activeSessionID
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in self?.invalidateForSessionChange() }
      }
      .store(in: &cancellables)
  }

  private func observeApplicationLifecycle() {
    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.scheduleRefresh(after: .milliseconds(250))
        }
      }
      .store(in: &cancellables)

    let workspaceNotifications = NSWorkspace.shared.notificationCenter
    workspaceNotifications.publisher(for: NSWorkspace.didWakeNotification)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          // Give networking a moment to recover after system wake.
          self?.scheduleRefresh(after: .seconds(2))
        }
      }
      .store(in: &cancellables)

    workspaceNotifications.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.scheduleRefresh(after: .seconds(1))
        }
      }
      .store(in: &cancellables)
  }

  private func startPeriodicSaves() {
    periodicSaveTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled, let self else { return }
        if self.ownership == .local, self.player.isPlaying {
          self.scheduleSave(after: .zero)
        }
      }
    }
  }

  private func startPeriodicRefreshes() {
    periodicRefreshTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        guard !Task.isCancelled, let self else { return }
        if !self.player.isPlaying {
          await self.refreshRemoteQueue()
        }
      }
    }
  }

  private func scheduleSave(after delay: Duration, isPauseBoundary: Bool = false) {
    guard ownership == .local else { return }
    if isPauseBoundary {
      pauseSavePending = true
    }
    scheduledSaveTask?.cancel()
    scheduledSaveTask = Task { @MainActor [weak self] in
      if delay > .zero {
        try? await Task.sleep(for: delay)
      }
      guard !Task.isCancelled, let self, self.ownership == .local,
        isPauseBoundary || self.player.isPlaying
      else { return }
      self.enqueueSave(isPauseBoundary: isPauseBoundary)
    }
  }

  private func scheduleRefresh(after delay: Duration) {
    guard !player.isPlaying else { return }
    lifecycleRefreshTask?.cancel()
    lifecycleRefreshTask = Task { @MainActor [weak self] in
      if delay > .zero {
        try? await Task.sleep(for: delay)
      }
      guard !Task.isCancelled, let self, !self.player.isPlaying else { return }
      await self.refreshRemoteQueue()
    }
  }

  private func enqueueSave(isPauseBoundary: Bool) {
    guard let client = session.client, let sessionID = session.activeSessionID else {
      if isPauseBoundary {
        pauseSavePending = false
      }
      return
    }
    pendingRequest = SaveRequest(
      generation: saveGeneration,
      sessionID: sessionID,
      client: client,
      snapshot: QueueHandoffSnapshot(
        queue: player.queue,
        currentIndex: player.currentIndex,
        positionSeconds: player.position
      ),
      isPauseBoundary: isPauseBoundary
    )
    guard saveWorkerTask == nil else { return }
    let workerID = UUID()
    saveWorkerID = workerID
    saveWorkerTask = Task { @MainActor [weak self] in
      await self?.drainPendingSaves(workerID: workerID)
    }
  }

  private func drainPendingSaves(workerID: UUID) async {
    while saveWorkerID == workerID, let request = pendingRequest {
      pendingRequest = nil
      await save(request)
      if request.isPauseBoundary, pendingRequest == nil {
        pauseSavePending = false
      }
    }
    if saveWorkerID == workerID {
      saveWorkerID = nil
      saveWorkerTask = nil
    }
  }

  private func save(_ request: SaveRequest) async {
    var retryDelay = Duration.seconds(1)
    for attempt in 0..<3 {
      guard request.generation == saveGeneration,
        request.sessionID == session.activeSessionID,
        ownership == .local
      else { return }

      do {
        try await request.client.savePlayQueue(
          songIDs: request.snapshot.songIDs,
          currentIndex: request.snapshot.currentIndex,
          positionMilliseconds: request.snapshot.positionMilliseconds
        )
        return
      } catch is CancellationError {
        return
      } catch {
        guard attempt < 2 else { return }
      }

      guard pendingRequest == nil else { return }
      try? await Task.sleep(for: retryDelay)
      retryDelay *= 2
    }
  }

  private func invalidateForSessionChange() {
    cancelSavePipeline()
    cancelRefresh()
    continueQueue = nil
    guard let sessionID = session.activeSessionID else {
      ownership = .none
      return
    }
    ownership = .awaitingInitialQueue(sessionID)
    scheduleRefresh(after: .milliseconds(250))
  }

  private func applyRemoteQueue(_ queue: RemotePlayQueue?, allowsOwnedQueueRestore: Bool) {
    switch queueHandoffDisposition(
      for: queue,
      allowsOwnedQueueRestore: allowsOwnedQueueRestore,
      localQueueIsEmpty: player.queue.isEmpty,
      localPlaybackIsPlaying: player.isPlaying,
      queueWasHandled: queue.map(session.hasHandledPlayQueue) ?? false
    ) {
    case .restore:
      guard let queue else { return }
      session.markPlayQueueHandled(queue)
      ownership = .local
      session.restore(
        songs: queue.songs,
        startAt: queue.resolvedCurrentIndex,
        positionMilliseconds: queue.position ?? 0,
        with: player
      )
    case .offer:
      cancelSavePipeline()
      ownership = .none
      continueQueue = queue
    case .ignore:
      continueQueue = nil
    }
  }

  private func takeLocalQueueOwnership() {
    ownership = .local
    cancelRefresh()
    continueQueue = nil
  }

  private func cancelSavePipeline() {
    saveGeneration = UUID()
    scheduledSaveTask?.cancel()
    scheduledSaveTask = nil
    pendingRequest = nil
    saveWorkerTask?.cancel()
    saveWorkerTask = nil
    saveWorkerID = nil
    pauseSavePending = false
  }

  private func cancelRefresh() {
    refreshID = nil
    refreshTask?.cancel()
    refreshTask = nil
  }
}

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

@MainActor
final class QueueHandoffCoordinator: ObservableObject {
  private enum RefreshResult: Sendable {
    case success(RemotePlayQueue?)
    case failure
  }

  private struct RefreshRequest {
    let sequence: UInt64
    let sessionID: UUID
    let task: Task<RefreshResult, Never>
  }

  private struct SaveRequest: Sendable {
    let sequence: UInt64
    let sessionID: UUID
    let client: NavidromeClient
    let snapshot: QueueHandoffSnapshot
  }

  private let session: AppSession
  private let player: PlayerController
  private var cancellables: Set<AnyCancellable> = []
  private var scheduledSaveTask: Task<Void, Never>?
  private var saveWorkerTask: Task<Void, Never>?
  private var periodicSaveTask: Task<Void, Never>?
  private var periodicRefreshTask: Task<Void, Never>?
  private var lifecycleRefreshTask: Task<Void, Never>?
  private var pendingRequest: SaveRequest?
  private var latestSequence: UInt64 = 0
  private var latestRefreshSequence: UInt64 = 0
  private var refreshRequest: RefreshRequest?
  private var pauseSnapshotSequence: UInt64?
  private var ownsLocalQueueState = false

  @Published private(set) var remoteQueue: RemotePlayQueue?

  init(session: AppSession, player: PlayerController) {
    self.session = session
    self.player = player
    observePlayback()
    observeApplicationLifecycle()
    startPeriodicSaves()
    startPeriodicRefreshes()
  }

  func saveBeforeTermination(timeout: Duration = .seconds(4)) async {
    guard ownsLocalQueueState, let client = session.client,
      session.activeSessionID != nil
    else { return }

    latestSequence &+= 1
    scheduledSaveTask?.cancel()
    scheduledSaveTask = nil
    pendingRequest = nil
    saveWorkerTask?.cancel()
    saveWorkerTask = nil

    let snapshot = QueueHandoffSnapshot(
      queue: player.queue,
      currentIndex: player.currentIndex,
      positionSeconds: player.position
    )

    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        try? await client.savePlayQueue(
          songIDs: snapshot.songIDs,
          currentIndex: snapshot.currentIndex,
          positionMilliseconds: snapshot.positionMilliseconds
        )
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
      }
      await group.next()
      group.cancelAll()
    }
  }

  func observeRemoteQueue(_ queue: RemotePlayQueue?) {
    remoteQueue = queue
    guard !player.isPlaying, let queue, !queue.songs.isEmpty,
      !queue.wasWrittenByThisCoda
    else { return }
    relinquishServerQueueOwnership()
  }

  @discardableResult
  func refreshRemoteQueue() async -> RemotePlayQueue? {
    guard !player.isPlaying, pauseSnapshotSequence == nil, let client = session.client,
      let sessionID = session.activeSessionID
    else { return nil }

    let request: RefreshRequest
    if let activeRequest = refreshRequest, activeRequest.sessionID == sessionID {
      request = activeRequest
    } else {
      latestRefreshSequence &+= 1
      let sequence = latestRefreshSequence
      request = RefreshRequest(
        sequence: sequence,
        sessionID: sessionID,
        task: Task {
          do {
            return .success(try await client.playQueue())
          } catch {
            return .failure
          }
        }
      )
      refreshRequest = request
    }

    let result = await request.task.value
    if refreshRequest?.sequence == request.sequence {
      refreshRequest = nil
    }
    guard request.sequence == latestRefreshSequence, !player.isPlaying,
      pauseSnapshotSequence == nil, request.sessionID == session.activeSessionID
    else { return nil }

    guard case .success(let queue) = result else {
      // Handoff refreshes are opportunistic. The next lifecycle event or timer retries.
      return nil
    }
    observeRemoteQueue(queue)
    return queue
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
          if self.player.isPlaying {
            self.scheduleSave(after: .milliseconds(250))
          }
        }
      }
      .store(in: &cancellables)

    player.$currentIndex
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.ownsLocalQueueState, self.player.isPlaying else { return }
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
            self.pauseSnapshotSequence = nil
            self.takeLocalQueueOwnership()
            self.scheduleSave(after: .milliseconds(500))
          } else if self.ownsLocalQueueState {
            // One final handoff snapshot at the pause boundary. No later paused-state
            // event is permitted to write to the shared server queue.
            self.scheduleSave(after: .zero, permitsPausedSnapshot: true)
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
          self?.scheduleLifecycleRefresh(after: .milliseconds(250))
        }
      }
      .store(in: &cancellables)

    let workspaceNotifications = NSWorkspace.shared.notificationCenter
    workspaceNotifications.publisher(for: NSWorkspace.didWakeNotification)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          // Give networking a moment to recover after system wake.
          self?.scheduleLifecycleRefresh(after: .seconds(2))
        }
      }
      .store(in: &cancellables)

    workspaceNotifications.publisher(for: NSWorkspace.sessionDidBecomeActiveNotification)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.scheduleLifecycleRefresh(after: .seconds(1))
        }
      }
      .store(in: &cancellables)
  }

  private func startPeriodicSaves() {
    periodicSaveTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard !Task.isCancelled, let self else { return }
        if self.ownsLocalQueueState, self.player.isPlaying {
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

  private func scheduleSave(after delay: Duration, permitsPausedSnapshot: Bool = false) {
    guard ownsLocalQueueState else { return }
    latestSequence &+= 1
    let sequence = latestSequence
    if permitsPausedSnapshot {
      pauseSnapshotSequence = sequence
    }
    scheduledSaveTask?.cancel()
    scheduledSaveTask = Task { @MainActor [weak self] in
      if delay > .zero {
        try? await Task.sleep(for: delay)
      }
      guard !Task.isCancelled, let self, sequence == self.latestSequence,
        permitsPausedSnapshot || self.player.isPlaying
      else { return }
      self.enqueueSave(sequence: sequence)
    }
  }

  private func scheduleLifecycleRefresh(after delay: Duration) {
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

  private func enqueueSave(sequence: UInt64) {
    guard let client = session.client, let sessionID = session.activeSessionID else { return }
    pendingRequest = SaveRequest(
      sequence: sequence,
      sessionID: sessionID,
      client: client,
      snapshot: QueueHandoffSnapshot(
        queue: player.queue,
        currentIndex: player.currentIndex,
        positionSeconds: player.position
      )
    )
    guard saveWorkerTask == nil else { return }
    saveWorkerTask = Task { @MainActor [weak self] in
      await self?.drainPendingSaves()
    }
  }

  private func drainPendingSaves() async {
    while let request = pendingRequest {
      pendingRequest = nil
      await save(request)
      if pauseSnapshotSequence == request.sequence {
        pauseSnapshotSequence = nil
      }
    }
    saveWorkerTask = nil
  }

  private func save(_ request: SaveRequest) async {
    var retryDelay = Duration.seconds(1)
    for attempt in 0..<3 {
      guard request.sequence == latestSequence,
        request.sessionID == session.activeSessionID
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

      try? await Task.sleep(for: retryDelay)
      retryDelay *= 2
    }
  }

  private func invalidateForSessionChange() {
    latestSequence &+= 1
    latestRefreshSequence &+= 1
    scheduledSaveTask?.cancel()
    scheduledSaveTask = nil
    pendingRequest = nil
    pauseSnapshotSequence = nil
    refreshRequest?.task.cancel()
    refreshRequest = nil
    ownsLocalQueueState = false
    remoteQueue = nil
    scheduleLifecycleRefresh(after: .milliseconds(250))
  }

  private func takeLocalQueueOwnership() {
    ownsLocalQueueState = true
    latestRefreshSequence &+= 1
    refreshRequest?.task.cancel()
    refreshRequest = nil
    remoteQueue = nil
  }

  private func relinquishServerQueueOwnership() {
    latestSequence &+= 1
    scheduledSaveTask?.cancel()
    scheduledSaveTask = nil
    pendingRequest = nil
    pauseSnapshotSequence = nil
    saveWorkerTask?.cancel()
    ownsLocalQueueState = false
  }
}

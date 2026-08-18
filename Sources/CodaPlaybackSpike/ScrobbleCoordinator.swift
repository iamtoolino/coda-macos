import Combine
import Foundation

func playedSubmissionPoint(durationSeconds: Double) -> Double {
  max(0, durationSeconds) * 0.95
}

func restoredOccurrenceIsPastScrobblePoint(
  positionSeconds: Double,
  durationSeconds: Double
) -> Bool {
  durationSeconds > 0
    && positionSeconds >= playedSubmissionPoint(durationSeconds: durationSeconds)
}

func scrobbleRetryDelays(
  maxAttempts: Int = 6,
  initialDelayMilliseconds: Int64 = 1_000
) -> [Int64] {
  guard maxAttempts > 1 else { return [] }
  var delay = max(0, initialDelayMilliseconds)
  return (0..<(maxAttempts - 1)).map { _ in
    defer { delay = min(delay * 2, 30_000) }
    return delay
  }
}

private func retryScrobble(
  maxAttempts: Int = 6,
  initialDelayMilliseconds: Int64 = 1_000,
  operation: @escaping @Sendable () async throws -> Void
) async throws {
  precondition(maxAttempts > 0)
  let delays = scrobbleRetryDelays(
    maxAttempts: maxAttempts,
    initialDelayMilliseconds: initialDelayMilliseconds
  )

  for attempt in 0..<maxAttempts {
    try Task.checkCancellation()
    do {
      try await operation()
      return
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      guard attempt < delays.count else { return }
      try await Task.sleep(for: .milliseconds(delays[attempt]))
    }
  }
}

@MainActor
final class ScrobbleCoordinator: ObservableObject {
  private let session: AppSession
  private let player: PlayerController
  private var cancellables: Set<AnyCancellable> = []
  private var activeOccurrenceID: UUID?
  private var submittedOccurrenceID: UUID?
  private var nowPlayingTask: Task<Void, Never>?
  private var progressTask: Task<Void, Never>?
  private var submissionTasks: [UUID: Task<Void, Never>] = [:]

  init(session: AppSession, player: PlayerController) {
    self.session = session
    self.player = player
    observePlayback()
  }

  private func observePlayback() {
    player.$playbackOccurrenceID
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] occurrenceID in
        Task { @MainActor [weak self] in
          self?.beginOccurrence(occurrenceID)
        }
      }
      .store(in: &cancellables)

    session.$activeSessionID
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.invalidateForSessionChange()
        }
      }
      .store(in: &cancellables)
  }

  private func beginOccurrence(_ occurrenceID: UUID?) {
    nowPlayingTask?.cancel()
    nowPlayingTask = nil
    progressTask?.cancel()
    progressTask = nil
    activeOccurrenceID = occurrenceID
    submittedOccurrenceID = nil

    guard let occurrenceID, let entry = player.currentEntry,
      let request = requestContext(songID: entry.sourceID)
    else { return }

    let duration = player.duration > 0
      ? player.duration
      : Double(max(0, entry.durationSeconds))
    if player.restoredPlaybackOccurrenceID == occurrenceID,
      restoredOccurrenceIsPastScrobblePoint(
        positionSeconds: player.position,
        durationSeconds: duration
      )
    {
      submittedOccurrenceID = occurrenceID
    }

    nowPlayingTask = launchScrobble(
      request: request,
      submission: false,
      timeMilliseconds: currentTimeMilliseconds()
    )

    progressTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, let self,
          self.activeOccurrenceID == occurrenceID,
          self.player.currentEntry?.id == entry.id
        else { return }
        self.submitIfPlayed(occurrenceID: occurrenceID, entry: entry)
      }
    }
  }

  private func submitIfPlayed(occurrenceID: UUID, entry: QueueEntry) {
    guard submittedOccurrenceID != occurrenceID else { return }
    let duration = player.duration > 0
      ? player.duration
      : Double(max(0, entry.durationSeconds))
    guard duration > 0, player.position >= playedSubmissionPoint(durationSeconds: duration),
      let request = requestContext(songID: entry.sourceID)
    else { return }

    submittedOccurrenceID = occurrenceID
    let taskID = UUID()
    let task = launchScrobble(
      request: request,
      submission: true,
      timeMilliseconds: currentTimeMilliseconds()
    ) { [weak self] in
      self?.submissionTasks[taskID] = nil
    }
    submissionTasks[taskID] = task
  }

  private func launchScrobble(
    request: RequestContext,
    submission: Bool,
    timeMilliseconds: Int64,
    completion: (@MainActor () -> Void)? = nil
  ) -> Task<Void, Never> {
    Task { @MainActor [weak self] in
      defer { completion?() }
      do {
        try await retryScrobble {
          guard await MainActor.run(body: {
            self?.session.activeSessionID == request.sessionID
          }) else {
            throw CancellationError()
          }
          try await request.client.scrobble(
            songID: request.songID,
            submission: submission,
            timeMilliseconds: timeMilliseconds
          )
        }
      } catch is CancellationError {
        return
      } catch {
        return
      }
    }
  }

  private func requestContext(songID: String) -> RequestContext? {
    guard let sessionID = session.activeSessionID, let client = session.client else { return nil }
    return RequestContext(sessionID: sessionID, client: client, songID: songID)
  }

  private func invalidateForSessionChange() {
    activeOccurrenceID = nil
    submittedOccurrenceID = nil
    nowPlayingTask?.cancel()
    nowPlayingTask = nil
    progressTask?.cancel()
    progressTask = nil
    submissionTasks.values.forEach { $0.cancel() }
    submissionTasks.removeAll()
  }

  private func currentTimeMilliseconds() -> Int64 {
    let milliseconds = Date().timeIntervalSince1970 * 1_000
    return Int64(max(0, min(milliseconds, Double(Int64.max))).rounded())
  }

  private struct RequestContext: Sendable {
    let sessionID: UUID
    let client: NavidromeClient
    let songID: String
  }
}

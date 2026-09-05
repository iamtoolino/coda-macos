import AppKit
import Combine
import Foundation

private let albumResumeProtocolName = "album-resume-bookmark"
private let albumResumeProtocolVersion = 1
private let albumResumeCommentByteLimit = 255
private let albumResumeRetentionLimit = 20

struct AlbumResumeWriter: Encodable, Sendable {
  let client: String?
  let platform: String?
  let appVersion: String?
}

struct AlbumResumeMarker: Decodable, Equatable, Sendable {
  let protocolName: String
  let protocolVersion: Int
  let resumeSongID: String

  enum CodingKeys: String, CodingKey {
    case protocolName = "protocol"
    case protocolVersion
    case resumeSongID = "resumeSongId"
  }

  var isSupported: Bool {
    protocolName == albumResumeProtocolName
      && protocolVersion == albumResumeProtocolVersion
      && !resumeSongID.isEmpty
  }
}

private struct AlbumResumeComment: Encodable {
  let `protocol`: String
  let protocolVersion: Int
  let resumeSongId: String
  let writer: AlbumResumeWriter?
}

struct AlbumResumeItem: Identifiable, Hashable, Sendable {
  let album: RemoteAlbum
  let anchorSongID: String
  let resumeSongID: String
  let changed: String

  var id: String { album.id }
}

enum AlbumResumeCompletionAction: Equatable {
  case upsert(anchorSongID: String, resumeSongID: String)
  case delete(anchorSongID: String)
  case none
}

func albumResumeMarker(from comment: String?) -> AlbumResumeMarker? {
  guard let comment, let data = comment.data(using: .utf8),
    let marker = try? JSONDecoder().decode(AlbumResumeMarker.self, from: data),
    marker.isSupported
  else { return nil }
  return marker
}

func albumResumeComment(
  resumeSongID: String,
  writer: AlbumResumeWriter? = AlbumResumeWriter(
    client: NavidromeConfiguration.clientName,
    platform: "macOS",
    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
      ?? "0"
  )
) -> String? {
  let trimmedID = resumeSongID.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmedID.isEmpty else { return nil }

  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  for candidateWriter in [writer, nil] {
    let marker = AlbumResumeComment(
      protocol: albumResumeProtocolName,
      protocolVersion: albumResumeProtocolVersion,
      resumeSongId: trimmedID,
      writer: candidateWriter
    )
    guard let data = try? encoder.encode(marker), data.count <= albumResumeCommentByteLimit,
      let comment = String(data: data, encoding: .utf8)
    else { continue }
    return comment
  }
  return nil
}

func albumResumeCompletionAction(
  completedSongID: String,
  album: AlbumPage
) -> AlbumResumeCompletionAction {
  guard let completedIndex = album.songs.firstIndex(where: { $0.id == completedSongID }),
    let anchorSongID = album.songs.first?.id.nonEmptyValue
  else { return .none }

  let nextIndex = album.songs.index(after: completedIndex)
  if album.songs.indices.contains(nextIndex) {
    return .upsert(
      anchorSongID: anchorSongID,
      resumeSongID: album.songs[nextIndex].id
    )
  }
  return .delete(anchorSongID: anchorSongID)
}

func isEligibleAlbumResumeSong(_ song: RemoteSong) -> Bool {
  let type = song.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  let mediaType = song.mediaType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  let albumID = song.albumId?.trimmingCharacters(in: .whitespacesAndNewlines)
  return (type == nil || type?.isEmpty == true || type == "music")
    && (mediaType == nil || mediaType?.isEmpty == true || mediaType == "song")
    && albumID?.isEmpty == false
}

func albumResumeItems(from bookmarks: [RemoteBookmark], limit: Int = 20) -> [AlbumResumeItem] {
  albumResumeBuckets(from: bookmarks)
    .prefix(max(0, limit))
    .map(\.item)
}

private struct AlbumResumeBucket {
  let item: AlbumResumeItem
  let bookmarks: [RemoteBookmark]
}

private func albumResumeBuckets(from bookmarks: [RemoteBookmark]) -> [AlbumResumeBucket] {
  let owned: [(RemoteBookmark, AlbumResumeItem, String)] = bookmarks.compactMap { bookmark in
    guard let marker = albumResumeMarker(from: bookmark.comment),
      let song = bookmark.entry,
      let albumID = song.albumId?.trimmingCharacters(in: .whitespacesAndNewlines),
      !albumID.isEmpty,
      !song.albumName.isEmpty
    else { return nil }
    let changed = bookmark.changed ?? bookmark.created ?? ""
    let album = RemoteAlbum(
      id: albumID,
      name: song.albumName,
      artist: song.artistName.nonEmptyValue,
      coverArt: song.albumArtworkID,
      year: song.year
    )
    let identity = albumGroupingIdentity(
      albumID: albumID,
      artist: song.artistName,
      album: song.albumName
    )
    return (
      bookmark,
      AlbumResumeItem(
        album: album,
        anchorSongID: song.id,
        resumeSongID: marker.resumeSongID,
        changed: changed
      ),
      identity
    )
  }

  return Dictionary(grouping: owned, by: { $0.2 })
    .values
    .compactMap { group -> AlbumResumeBucket? in
      guard let representative = group.max(by: { left, right in
        if left.1.changed != right.1.changed { return left.1.changed < right.1.changed }
        return left.1.anchorSongID < right.1.anchorSongID
      }) else { return nil }
      return AlbumResumeBucket(item: representative.1, bookmarks: group.map(\.0))
    }
    .sorted { left, right in
      if left.item.changed != right.item.changed {
        return left.item.changed > right.item.changed
      }
      return left.item.anchorSongID > right.item.anchorSongID
    }
}

@MainActor
final class AlbumResumeCoordinator: ObservableObject {
  @Published private(set) var items: [AlbumResumeItem] = []

  private let session: AppSession
  private let player: PlayerController
  private var cancellables: Set<AnyCancellable> = []
  private var refreshTask: Task<Void, Never>?
  private var refreshID: UUID?
  private var mutationTask: Task<Void, Never>?
  private var publicationGeneration = UUID()

  init(session: AppSession, player: PlayerController) {
    self.session = session
    self.player = player
    observePlaybackAndSession()
  }

  func refresh() async {
    if let refreshTask {
      await refreshTask.value
      return
    }
    guard let request = session.sessionRequestContext() else { return }
    let id = UUID()
    let generation = beginPublication()
    refreshID = id
    let task = Task { @MainActor [weak self] in
      defer {
        if let self, self.refreshID == id {
          self.refreshID = nil
          self.refreshTask = nil
        }
      }
      guard let bookmarks = try? await request.client.bookmarks(),
        let self,
        self.refreshID == id,
        self.session.isCurrent(request),
        self.publicationGeneration == generation
      else { return }
      await self.reconcile(bookmarks, request: request, generation: generation)
    }
    refreshTask = task
    await task.value
  }

  private func observePlaybackAndSession() {
    player.$completedPlayback
      .dropFirst()
      .compactMap { $0 }
      .sink { [weak self] completion in
        Task { @MainActor [weak self] in
          self?.enqueue(completion)
        }
      }
      .store(in: &cancellables)

    session.$activeSessionID
      .removeDuplicates()
      .dropFirst()
      .sink { [weak self] activeSessionID in
        Task { @MainActor [weak self] in
          guard let self else { return }
          self.invalidateForSessionChange()
          if activeSessionID != nil {
            await self.refresh()
          }
        }
      }
      .store(in: &cancellables)

    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          try? await Task.sleep(for: .milliseconds(250))
          guard !Task.isCancelled else { return }
          await self?.refresh()
        }
      }
      .store(in: &cancellables)
  }

  private func enqueue(_ completion: CompletedPlayback) {
    guard let request = session.sessionRequestContext() else { return }
    let previous = mutationTask
    mutationTask = Task { @MainActor [weak self] in
      await previous?.value
      guard !Task.isCancelled, let self, self.session.isCurrent(request) else { return }
      await self.process(completedSongID: completion.sourceID, request: request)
    }
  }

  private func process(completedSongID: String, request: SessionRequestContext) async {
    do {
      let song = try await request.client.song(id: completedSongID)
      guard session.isCurrent(request), isEligibleAlbumResumeSong(song),
        let albumID = song.albumId?.trimmingCharacters(in: .whitespacesAndNewlines),
        !albumID.isEmpty
      else { return }
      let page = try await request.client.album(id: albumID)
      guard session.isCurrent(request) else { return }

      switch albumResumeCompletionAction(
        completedSongID: completedSongID,
        album: page
      ) {
      case .upsert(let anchorSongID, let resumeSongID):
        guard let comment = albumResumeComment(resumeSongID: resumeSongID) else { return }
        try await request.client.createBookmark(
          songID: anchorSongID,
          positionMilliseconds: 0,
          comment: comment
        )
        guard session.isCurrent(request) else { return }
        publishLocalUpsert(
          album: page.album,
          anchorSongID: anchorSongID,
          resumeSongID: resumeSongID
        )
      case .delete(let anchorSongID):
        try await request.client.deleteBookmark(songID: anchorSongID)
        guard session.isCurrent(request) else { return }
        publishLocalDeletion(albumID: page.album.id, anchorSongID: anchorSongID)
      case .none:
        return
      }
    } catch {
      return
    }
  }

  private func reconcile(
    _ bookmarks: [RemoteBookmark],
    request: SessionRequestContext,
    generation: UUID
  ) async {
    guard session.isCurrent(request), publicationGeneration == generation else { return }
    let buckets = albumResumeBuckets(from: bookmarks)
    items = buckets.prefix(albumResumeRetentionLimit).map(\.item)

    for bucket in buckets.dropFirst(albumResumeRetentionLimit) {
      for bookmark in bucket.bookmarks {
        guard session.isCurrent(request), publicationGeneration == generation,
          let songID = bookmark.entry?.id
        else { return }
        try? await request.client.deleteBookmark(songID: songID)
      }
    }
  }

  private func publishLocalUpsert(
    album: RemoteAlbum,
    anchorSongID: String,
    resumeSongID: String
  ) {
    _ = beginPublication()
    items.removeAll { $0.album.id == album.id || $0.anchorSongID == anchorSongID }
    items.insert(
      AlbumResumeItem(
        album: album,
        anchorSongID: anchorSongID,
        resumeSongID: resumeSongID,
        changed: Date().ISO8601Format()
      ),
      at: 0
    )
    items = Array(items.prefix(albumResumeRetentionLimit))
  }

  private func publishLocalDeletion(albumID: String, anchorSongID: String) {
    _ = beginPublication()
    items.removeAll { $0.album.id == albumID || $0.anchorSongID == anchorSongID }
  }

  private func beginPublication() -> UUID {
    let generation = UUID()
    publicationGeneration = generation
    return generation
  }

  private func invalidateForSessionChange() {
    publicationGeneration = UUID()
    refreshID = nil
    refreshTask?.cancel()
    refreshTask = nil
    mutationTask?.cancel()
    mutationTask = nil
    items = []
  }
}

private extension String {
  var nonEmptyValue: String? { isEmpty ? nil : self }
}

import AudioToolbox
import Combine
import Foundation

enum SelfTests {
  @MainActor
  static func run() -> Bool {
    var failures: [String] = []

    check("server URL normalization", failures: &failures) {
      let config = try NavidromeConfiguration(
        server: " music.example.test/navidrome/// ",
        username: "listener",
        password: "secret"
      )
      return config.serverURL.absoluteString == "https://music.example.test/navidrome"
    }

    check("known MD5 vector", failures: &failures) {
      NavidromeConfiguration.md5("passwordsalt") == "b305cadbb3bce54f3aa59c64fec00dea"
    }

    check("original stream policy", failures: &failures) {
      let config = try NavidromeConfiguration(
        server: "https://music.example.test/navidrome/",
        username: "listener name",
        password: "secret"
      )
      let url = try config.originalStreamURL(songID: "song/1", salt: "abc123")
      guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let items = components.queryItems
      else { return false }
      let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
      return components.path == "/navidrome/rest/stream.view"
        && query["id"] == "song/1"
        && query["format"] == "raw"
        && query["u"] == "listener name"
        && query["s"] == "abc123"
        && query["t"] == NavidromeConfiguration.md5("secretabc123")
        && query["maxBitRate"] == nil
        && query["estimateContentLength"] == nil
    }

    check("album rating request", failures: &failures) {
      let config = try NavidromeConfiguration(
        server: "https://music.example.test/navidrome",
        username: "listener",
        password: "secret"
      )
      let url = try config.ratingURL(id: " album/1 ", rating: 4, salt: "abc123")
      guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let items = components.queryItems
      else { return false }
      let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
      return components.path == "/navidrome/rest/setRating.view"
        && query["id"] == "album/1"
        && query["rating"] == "4"
        && query["u"] == "listener"
        && query["s"] == "abc123"
    }

    check("scrobble request", failures: &failures) {
      let config = try NavidromeConfiguration(
        server: "https://music.example.test/navidrome",
        username: "listener",
        password: "secret"
      )
      let url = try config.scrobbleURL(
        songID: " song/1 ",
        submission: true,
        timeMilliseconds: 1_721_234_567_890,
        salt: "abc123"
      )
      guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let items = components.queryItems
      else { return false }
      let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
      return components.path == "/navidrome/rest/scrobble.view"
        && query["id"] == "song/1"
        && query["submission"] == "true"
        && query["time"] == "1721234567890"
        && query["u"] == "listener"
        && query["s"] == "abc123"
    }

    check("Android-compatible scrobble threshold and retry schedule", failures: &failures) {
      playedSubmissionPoint(durationSeconds: 240) == 228
        && playedSubmissionPoint(durationSeconds: -1) == 0
        && scrobbleRetryDelays() == [1_000, 2_000, 4_000, 8_000, 16_000]
        && scrobbleRetryDelays(maxAttempts: 1).isEmpty
    }

    check("album collection sort options", failures: &failures) {
      AlbumCollectionKind.allCases == [
        .recentlyAdded,
        .recentReleases,
        .topRated,
        .mostPlayed,
        .recentlyPlayed,
        .alphabetical,
      ] && AlbumCollectionKind.mostPlayed.apiValue == "frequent"
    }

    check("artist search excludes participation-only artists", failures: &failures) {
      let results = [
        RemoteArtist(id: "album-artist", name: "Avantasia", albumCount: 8),
        RemoteArtist(id: "performer", name: "Avantasia, Jorn", albumCount: 0),
        RemoteArtist(id: "legacy", name: "Legacy Server Artist"),
      ].filter(\.isAlbumArtistSearchResult)
      return results.map(\.id) == ["album-artist", "legacy"]
    }

    check("source metadata formatting", failures: &failures) {
      let song = RemoteSong(
        id: "1",
        title: "Track",
        suffix: "flac",
        bitRate: 2_350,
        bitDepth: 24,
        samplingRate: 96_000
      )
      return song.technicalSummary == "FLAC · 24-bit · 96 kHz · 2350 kbps"
    }

    check("album artwork overrides embedded track artwork", failures: &failures) {
      let song = RemoteSong(
        id: "1",
        title: "Track",
        albumId: "album-artwork",
        coverArt: "embedded-track-artwork"
      )
      return song.albumArtworkID == "album-artwork"
    }

    check("library queue drag payload round trip", failures: &failures) {
      let items = [
        LibraryQueueDragItem.artist("artist/1"),
        LibraryQueueDragItem.album("album/1"),
        LibraryQueueDragItem.albumDisc("album/1", discNumber: 3),
        LibraryQueueDragItem.song("song/1"),
      ]
      let data = try JSONEncoder().encode(items)
      return try JSONDecoder().decode([LibraryQueueDragItem].self, from: data) == items
    }

    check("queue reorder drag payload round trip", failures: &failures) {
      let item = QueueReorderDragItem.albumBlock([UUID(), UUID()])
      let data = try JSONEncoder().encode(item)
      return try JSONDecoder().decode(QueueReorderDragItem.self, from: data) == item
    }

    check("unified queue drop payload round trip", failures: &failures) {
      let items = [
        QueueDropItem.library(.album("album/1")),
        QueueDropItem.reorder(.track(UUID())),
      ]
      let data = try JSONEncoder().encode(items)
      return try JSONDecoder().decode([QueueDropItem].self, from: data) == items
    }

    check("queue reorder keeps one authoritative insertion result", failures: &failures) {
      let ids = [UUID(), UUID(), UUID(), UUID()]
      return reorderedQueueIDs(ids, moving: [ids[1]], before: nil)
        == [ids[0], ids[2], ids[3], ids[1]]
        && reorderedQueueIDs(ids, moving: [ids[0], ids[1]], before: ids[2]) == nil
        && reorderedQueueIDs(ids, moving: [ids[2], ids[3]], before: ids[0])
          == [ids[2], ids[3], ids[0], ids[1]]
        && reorderedQueueIDs(ids, moving: [ids[2], ids[3]], before: ids[1])
          == [ids[0], ids[2], ids[3], ids[1]]
    }

    check("mpv next refresh never removes a numeric playlist position", failures: &failures) {
      let next = URL(string: "https://example.test/next.flac")!
      return mpvExpectedNextCommands(next) == [
        ["playlist-clear"],
        ["loadfile", next.absoluteString, "insert-next"],
      ] && mpvExpectedNextCommands(nil) == [["playlist-clear"]]
    }

    check("mpv advances Coda on the incoming file start", failures: &failures) {
      var tracker = MPVFileStartAdvanceTracker()
      let initialDidAdvance = tracker.observeStart(hasExpectedNext: true)
      let incomingDidAdvance = tracker.observeStart(hasExpectedNext: true)
      tracker.reset()
      let replacementDidAdvance = tracker.observeStart(hasExpectedNext: true)
      return !initialDidAdvance && incomingDidAdvance && !replacementDidAdvance
    }

    check("late mpv end event cannot finish the incoming file", failures: &failures) {
      mpvEndEventMatchesActiveFile(activeID: 12, endedID: 12)
        && !mpvEndEventMatchesActiveFile(activeID: 12, endedID: 11)
        && !mpvEndEventMatchesActiveFile(activeID: nil, endedID: 11)
    }

    check("automatic backend advance publishes the next queue entry", failures: &failures) {
      let backend = SelfTestPlaybackBackend()
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
    }

    check("restored queue loads paused at its saved position", failures: &failures) {
      let backend = SelfTestPlaybackBackend()
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
    }

    check("playback clock does not invalidate stable player state", failures: &failures) {
      let backend = SelfTestPlaybackBackend()
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
    }

    check("playback clock adapts its publication rate to window visibility", failures: &failures) {
      playbackTimelinePublicationInterval(windowIsVisible: true) == .milliseconds(250)
        && playbackTimelinePublicationInterval(windowIsVisible: false) == .seconds(1)
    }

    check("reordering the playing album preserves playback identity", failures: &failures) {
      let backend = SelfTestPlaybackBackend()
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
    }

    check("inserting library entries preserves playback identity", failures: &failures) {
      let backend = SelfTestPlaybackBackend()
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
    }

    check("unexpected mpv idle reloads a playing item once", failures: &failures) {
      let backend = SelfTestPlaybackBackend()
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
    }

    check("queue grouping preserves occurrences and splits", failures: &failures) {
      let albumGroup = UUID()
      let otherGroup = UUID()
      let first = QueueEntry(
        sourceID: "first",
        url: URL(string: "https://example.test/first")!,
        title: "First",
        album: "Album",
        queueGroupID: albumGroup
      )
      let other = QueueEntry(
        sourceID: "other",
        url: URL(string: "https://example.test/other")!,
        title: "Other",
        album: "Other Album",
        queueGroupID: otherGroup
      )
      let second = QueueEntry(
        sourceID: "second",
        url: URL(string: "https://example.test/second")!,
        title: "Second",
        album: "Album",
        queueGroupID: albumGroup
      )
      return queueGroups([first, other, second]).map(\.entryIDs)
        == [[first.id], [other.id], [second.id]]
    }

    check("album chronology uses full release date", failures: &failures) {
      let later = RemoteAlbum(
        id: "later",
        name: "Later",
        originalReleaseDate: ItemDate(year: 2024, month: 11, day: 2)
      )
      let earlier = RemoteAlbum(
        id: "earlier",
        name: "Earlier",
        originalReleaseDate: ItemDate(year: 2024, month: 2, day: 12)
      )
      return [later, earlier].sorted { $0.chronologicalReleaseKey < $1.chronologicalReleaseKey }
        .map(\.id) == ["earlier", "later"]
    }

    check("OpenSubsonic disc titles decode", failures: &failures) {
      let data = Data(
        #"{"id":"album","name":"Three Discs","discTitles":[{"disc":2,"title":"Live"},{"disc":3,"title":"Instrumentals","coverArt":"disc-3"}]}"#
          .utf8
      )
      let album = try JSONDecoder().decode(RemoteAlbum.self, from: data)
      return album.discTitles == [
        RemoteDiscTitle(disc: 2, title: "Live"),
        RemoteDiscTitle(disc: 3, title: "Instrumentals", coverArt: "disc-3"),
      ]
    }

    check("unlimited disc sections use local numbering and runtimes", failures: &failures) {
      let album = RemoteAlbum(
        id: "album",
        name: "Three Discs",
        discTitles: [RemoteDiscTitle(disc: 3, title: "Bonus")]
      )
      let songs = [
        RemoteSong(id: "1", title: "One", track: 1, discNumber: 1, duration: 60),
        RemoteSong(id: "2", title: "Two", track: 1, discNumber: 2, duration: 120),
        RemoteSong(
          id: "3",
          title: "Three",
          track: 1,
          discNumber: 3,
          discSubtitle: "Bonus",
          duration: 180
        ),
      ]
      let page = AlbumPage(album: album, songs: songs)
      let queueEntries = songs.map { song in
        QueueEntry(
          sourceID: song.id,
          url: URL(string: "https://example.test/\(song.id)")!,
          title: song.title,
          trackNumber: song.track,
          discNumber: song.discNumber,
          discSubtitle: song.discSubtitle,
          durationSeconds: song.duration ?? 0
        )
      }
      let queueGroup = QueueGroup(id: queueEntries[0].id, startIndex: 0, entries: queueEntries)
      return page.showsDiscHeadings
        && page.discSections.map(\.number) == [1, 2, 3]
        && page.discSections.map(\.durationSeconds) == [60, 120, 180]
        && page.discSections.last?.subtitle == "Bonus"
        && queueGroup.showsDiscHeadings
        && queueGroup.beginsDiscSection(at: 2)
        && queueGroup.discSubtitle(at: 2) == "Bonus"
        && queueGroup.discDuration(at: 2) == 180
        && trackLabel(queueEntries[2]) == "1"
    }

    check("invalid URL rejection", failures: &failures) {
      do {
        _ = try NavidromeConfiguration(
          server: "ftp://music.example.test",
          username: "listener",
          password: "secret"
        )
        return false
      } catch {
        return true
      }
    }

    check("stored login configuration", failures: &failures) {
      let stored = StoredLogin(
        serverURL: "https://music.example.test",
        username: "listener",
        password: "secret"
      )
      let data = try JSONEncoder().encode(stored)
      let decoded = try JSONDecoder().decode(StoredLogin.self, from: data)
      let config = try decoded.configuration
      return config.serverURL.absoluteString == "https://music.example.test"
        && config.username == "listener"
        && config.password == "secret"
        && decoded == stored
    }

    check("saved queue form request", failures: &failures) {
      let config = try NavidromeConfiguration(
        server: "https://music.example.test/navidrome",
        username: "listener name",
        password: "secret"
      )
      let request = try config.playQueueSaveRequest(
        songIDs: ["song/1", "song 2", "song&3"],
        currentIndex: 1,
        positionMilliseconds: 12_345,
        salt: "abc123"
      )
      let items = try formItems(in: request)
      return request.httpMethod == "POST"
        && request.url?.path == "/navidrome/rest/savePlayQueue.view"
        && request.url?.query == nil
        && request.value(forHTTPHeaderField: "Content-Type")
          == "application/x-www-form-urlencoded"
        && items.filter { $0.name == "id" }.compactMap(\.value)
          == ["song/1", "song 2", "song&3"]
        && items.first { $0.name == "current" }?.value == "song 2"
        && items.first { $0.name == "position" }?.value == "12345"
        && items.first { $0.name == "u" }?.value == "listener name"
        && items.first { $0.name == "s" }?.value == "abc123"
        && items.first { $0.name == "t" }?.value
          == NavidromeConfiguration.md5("secretabc123")
    }

    check("empty saved queue clears server queue", failures: &failures) {
      let config = try NavidromeConfiguration(
        server: "https://music.example.test",
        username: "listener",
        password: "secret"
      )
      let request = try config.playQueueSaveRequest(
        songIDs: [],
        currentIndex: 99,
        positionMilliseconds: 99_999,
        salt: "abc123"
      )
      let names = try formItems(in: request).map(\.name)
      return !names.contains("id") && !names.contains("current") && !names.contains("position")
    }

    check("queue handoff snapshot", failures: &failures) {
      let entries = [
        QueueEntry(sourceID: "one", url: URL(string: "https://example.test/one")!, title: "One"),
        QueueEntry(sourceID: "two", url: URL(string: "https://example.test/two")!, title: "Two"),
      ]
      let snapshot = QueueHandoffSnapshot(
        queue: entries,
        currentIndex: 9,
        positionSeconds: 12.345
      )
      return snapshot.songIDs == ["one", "two"]
        && snapshot.currentIndex == 1
        && snapshot.positionMilliseconds == 12_345
    }

    check("Coda Mac queue recognition", failures: &failures) {
      let song = RemoteSong(id: "two", title: "Two")
      let ownQueue = RemotePlayQueue(
        current: "two",
        changedBy: NavidromeConfiguration.clientName.lowercased(),
        currentIndex: 99,
        entry: [song]
      )
      let externalQueue = RemotePlayQueue(changedBy: "Coda", entry: [song])
      return ownQueue.wasWrittenByThisCoda
        && ownQueue.resolvedCurrentIndex == 0
        && !externalQueue.wasWrittenByThisCoda
    }

    check("human-readable device client identity", failures: &failures) {
      NavidromeConfiguration.makeClientName(deviceName: " su ") == "Coda on su"
        && NavidromeConfiguration.makeClientName(deviceName: nil) == "Coda on Mac"
    }

    if failures.isEmpty {
      print("Coda playback spike self-tests passed (33 checks).")
      return true
    }

    for failure in failures {
      print("FAILED: \(failure)")
    }
    return false
  }

  @MainActor
  static func runMPVLocalTransitionTest() async -> Bool {
    let urls = ["Glass.aiff", "Ping.aiff"].map {
      URL(fileURLWithPath: "/System/Library/Sounds/\($0)")
    }
    guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
      print("FAILED: macOS test sounds are unavailable.")
      return false
    }

    let player = PlayerController()
    guard player.playbackEngineName.contains("mpv") else {
      print("FAILED: mpv was not selected; active engine is \(player.playbackEngineName).")
      return false
    }
    let entries = urls.enumerated().map { index, url in
      QueueEntry(sourceID: "local-\(index)", url: url, title: url.deletingPathExtension().lastPathComponent)
    }
    player.setVolume(0)
    player.replaceQueue(
      entries,
      positionSeconds: 0.2,
      startsPlaying: false
    )

    for _ in 0..<40 {
      if !player.isPlaying, player.duration > 0, player.position >= 0.15 {
        break
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard !player.isPlaying, player.duration > 0, player.position >= 0.15 else {
      player.clear()
      print("FAILED: mpv did not restore a paused local item at its saved position.")
      return false
    }

    player.play()

    for _ in 0..<40 {
      if player.currentIndex == 0, player.isPlaying, player.position >= 0.25 {
        break
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    guard player.currentIndex == 0, player.isPlaying, player.position >= 0.25 else {
      player.clear()
      print("FAILED: mpv did not begin the first local playlist item.")
      return false
    }

    player.play(index: 1)
    for _ in 0..<80 {
      if let message = player.errorMessage {
        player.clear()
        print("FAILED: \(message)")
        return false
      }
      if player.currentIndex == 1, player.isPlaying, player.position >= 0.1 {
        player.clear()
        print("mpv directly started and remained synchronized with the final playlist item.")
        return true
      }
      try? await Task.sleep(for: .milliseconds(100))
    }

    player.clear()
    print("FAILED: mpv did not remain synchronized after directly starting the final item.")
    return false
  }

  @MainActor
  static func runMPVStreamTest() async -> Bool {
    do {
      let configuration = try CredentialStore.loadForDevelopmentTest()
      let client = NavidromeClient(configuration: configuration)
      _ = try await client.ping()
      guard let album = try await client.albums(.recentlyAdded, size: 1).first else {
        print("FAILED: Navidrome returned no albums for the mpv stream test.")
        return false
      }
      let page = try await client.album(id: album.id)
      guard let song = page.songs.first else {
        print("FAILED: Navidrome returned an album without tracks.")
        return false
      }

      let player = PlayerController()
      guard player.playbackEngineName.contains("mpv") else {
        print("FAILED: mpv was not selected; active engine is \(player.playbackEngineName).")
        return false
      }

      let entries = try page.songs.prefix(2).map { candidate in
        QueueEntry(
          sourceID: candidate.id,
          url: try configuration.originalStreamURL(songID: candidate.id),
          title: candidate.title,
          artist: candidate.artist ?? "",
          album: candidate.album ?? album.name,
          albumID: candidate.albumId,
          durationSeconds: candidate.duration ?? 0,
          formatDescription: candidate.technicalSummary
        )
      }
      player.setVolume(0)
      player.replaceQueue(entries, startsPlaying: true)

      for _ in 0..<200 {
        if let message = player.errorMessage {
          print("FAILED: \(message)")
          player.clear()
          return false
        }
        if player.position >= 0.2, player.duration > 1 {
          break
        }
        try await Task.sleep(for: .milliseconds(100))
      }

      guard player.position >= 0.2, player.duration > 1 else {
        player.clear()
        print("FAILED: mpv did not begin the original-format stream within 20 seconds.")
        return false
      }

      player.clear()
      print(
        "\(player.playbackEngineName) decoded a Navidrome original-format \(song.suffix?.uppercased() ?? "audio") stream successfully."
      )
      return true
    } catch {
      print("FAILED: \(error.localizedDescription)")
      return false
    }
  }

  private static func check(
    _ name: String,
    failures: inout [String],
    operation: () throws -> Bool
  ) {
    do {
      if try !operation() {
        failures.append(name)
      }
    } catch {
      failures.append("\(name): \(error.localizedDescription)")
    }
  }

  private static func formItems(in request: URLRequest) throws -> [URLQueryItem] {
    guard let body = request.httpBody,
      let encoded = String(data: body, encoding: .utf8),
      let components = URLComponents(string: "https://form.invalid/?\(encoded)"),
      let items = components.queryItems
    else {
      throw NavidromeError.invalidResponse
    }
    return items
  }
}

@MainActor
private final class SelfTestPlaybackBackend: PlaybackBackend {
  struct LoadCall {
    let url: URL
    let next: URL?
    let position: Double
    let autoplay: Bool
  }

  let name = "Self-test"
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

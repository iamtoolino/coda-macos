import AppKit
import AudioToolbox
import Combine
import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("Navidrome and models")
@MainActor
struct NavidromeTests {
  @Test("server URL normalization")
  func serverUrlNormalization() throws {
    let passed = try { () throws -> Bool in
      let config = try NavidromeConfiguration(
        server: " music.example.test/navidrome/// ",
        username: "listener",
        password: "secret"
      )
      return config.serverURL.absoluteString == "https://music.example.test/navidrome"
    }()
    #expect(passed)
  }

  @Test("known MD5 vector")
  func knownMd5Vector() throws {
    let passed = try { () throws -> Bool in
      NavidromeConfiguration.md5("passwordsalt") == "b305cadbb3bce54f3aa59c64fec00dea"
    }()
    #expect(passed)
  }

  @Test("original stream policy")
  func originalStreamPolicy() throws {
    let passed = try { () throws -> Bool in
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
    }()
    #expect(passed)
  }

  @Test("album rating request")
  func albumRatingRequest() throws {
    let passed = try { () throws -> Bool in
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
    }()
    #expect(passed)
  }

  @Test("scrobble request")
  func scrobbleRequest() throws {
    let passed = try { () throws -> Bool in
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
    }()
    #expect(passed)
  }

  @Test("Android-compatible scrobble threshold and retry schedule")
  func androidCompatibleScrobbleThresholdAndRetrySchedule() throws {
    let passed = try { () throws -> Bool in
      playedSubmissionPoint(durationSeconds: 240) == 228
        && playedSubmissionPoint(durationSeconds: -1) == 0
        && scrobbleRetryDelays() == [1_000, 2_000, 4_000, 8_000, 16_000]
        && scrobbleRetryDelays(maxAttempts: 1).isEmpty
    }()
    #expect(passed)
  }

  @Test("artist search excludes participation-only artists")
  func artistSearchExcludesParticipationOnlyArtists() throws {
    let passed = try { () throws -> Bool in
      let results = [
        RemoteArtist(id: "album-artist", name: "Avantasia", albumCount: 8),
        RemoteArtist(id: "performer", name: "Avantasia, Jorn", albumCount: 0),
        RemoteArtist(id: "legacy", name: "Legacy Server Artist"),
      ].filter(\.isAlbumArtistSearchResult)
      return results.map(\.id) == ["album-artist", "legacy"]
    }()
    #expect(passed)
  }

  @Test("source metadata formatting")
  func sourceMetadataFormatting() throws {
    let passed = try { () throws -> Bool in
      let song = RemoteSong(
        id: "1",
        title: "Track",
        suffix: "flac",
        bitRate: 2_350,
        bitDepth: 24,
        samplingRate: 96_000
      )
      return song.technicalSummary == "FLAC · 24-bit · 96 kHz · 2350 kbps"
    }()
    #expect(passed)
  }

  @Test("invalid URL rejection")
  func invalidUrlRejection() throws {
    let passed = try { () throws -> Bool in
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
    }()
    #expect(passed)
  }

  @Test("stored login configuration")
  func storedLoginConfiguration() throws {
    let passed = try { () throws -> Bool in
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
    }()
    #expect(passed)
  }

  @Test("saved queue form request")
  func savedQueueFormRequest() throws {
    let passed = try { () throws -> Bool in
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
    }()
    #expect(passed)
  }

  @Test("empty saved queue clears server queue")
  func emptySavedQueueClearsServerQueue() throws {
    let passed = try { () throws -> Bool in
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
    }()
    #expect(passed)
  }

  @Test("queue handoff snapshot")
  func queueHandoffSnapshot() throws {
    let passed = try { () throws -> Bool in
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
    }()
    #expect(passed)
  }

  @Test("Coda Mac queue recognition")
  func codaMacQueueRecognition() throws {
    let passed = try { () throws -> Bool in
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
    }()
    #expect(passed)
  }

  @Test("human-readable device client identity")
  func humanReadableDeviceClientIdentity() throws {
    let passed = try { () throws -> Bool in
      NavidromeConfiguration.makeClientName(deviceName: " su ") == "Coda on su"
        && NavidromeConfiguration.makeClientName(deviceName: nil) == "Coda on Mac"
    }()
    #expect(passed)
  }

  private func formItems(in request: URLRequest) throws -> [URLQueryItem] {
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

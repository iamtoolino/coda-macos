import AppKit
import Foundation

enum PlaybackDiagnostics {
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

    let rapidSelectionEntries = [urls[1], urls[0], urls[1]].enumerated().map { index, url in
      QueueEntry(
        sourceID: "rapid-local-\(index)",
        url: url,
        title: url.deletingPathExtension().lastPathComponent
      )
    }
    player.setVolume(0)
    for attempt in 1...10 {
      player.replaceQueue(rapidSelectionEntries, startsPlaying: false)
      player.play(index: 1)
      player.pause()

      for _ in 0..<20 {
        try? await Task.sleep(for: .milliseconds(5))
        guard player.currentIndex == 1 else {
          let observedIndex = player.currentIndex
          player.clear()
          print(
            "FAILED: rapid manual selection advanced to index \(observedIndex.map(String.init) ?? "nil") on attempt \(attempt)."
          )
          return false
        }
      }
      player.clear()
      try? await Task.sleep(for: .milliseconds(5))
    }
    try? await Task.sleep(for: .milliseconds(250))

    let entries = urls.enumerated().map { index, url in
      QueueEntry(
        sourceID: "local-\(index)", url: url, title: url.deletingPathExtension().lastPathComponent)
    }
    player.replaceQueue(entries, startsPlaying: true)
    for _ in 0..<500 {
      if let message = player.errorMessage {
        player.clear()
        print("FAILED: \(message)")
        return false
      }
      if player.currentIndex == 1 {
        player.pause()
        break
      }
      try? await Task.sleep(for: .milliseconds(10))
    }
    guard player.currentIndex == 1 else {
      player.clear()
      print("FAILED: mpv did not automatically advance to the preloaded local item.")
      return false
    }
    player.clear()
    try? await Task.sleep(for: .milliseconds(250))

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

}

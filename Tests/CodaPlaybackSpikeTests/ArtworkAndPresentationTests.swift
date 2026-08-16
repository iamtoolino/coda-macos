import AppKit
import AudioToolbox
import Combine
import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("Artwork and presentation")
@MainActor
struct ArtworkAndPresentationTests {
  @Test("artwork purposes use one browsing size and one Retina presentation size")
  func artworkPurposesUseOneBrowsingSizeAndOneRetinaPresentationSize() throws {
    let passed = try { () throws -> Bool in
      ArtworkPurpose.standard.rawValue == 500
        && ArtworkPurpose.nowPlaying.rawValue == 1_200
    }()
    #expect(passed)
  }

  @Test("artwork invalidation advances the shared cache generation")
  func artworkInvalidationAdvancesTheSharedCacheGeneration() throws {
    let passed = try { () throws -> Bool in
      let cache = ArtworkImageCache.shared
      let previousGeneration = cache.generation
      cache.invalidateAll()
      return cache.generation == previousGeneration + 1
    }()
    #expect(passed)
  }

  @Test("queue entries keep browsing and now playing artwork separate")
  func queueEntriesKeepBrowsingAndNowPlayingArtworkSeparate() throws {
    let passed = try { () throws -> Bool in
      let browsingURL = URL(string: "https://example.test/cover?size=500")!
      let nowPlayingURL = URL(string: "https://example.test/cover?size=1200")!
      let entry = QueueEntry(
        sourceID: "song",
        url: URL(string: "https://example.test/song")!,
        artworkURL: browsingURL,
        nowPlayingArtworkURL: nowPlayingURL,
        title: "Song"
      )
      return entry.artworkURL == browsingURL
        && entry.nowPlayingArtworkURL == nowPlayingURL
    }()
    #expect(passed)
  }

  @Test("same album identity can repair stale artwork treatment")
  func sameAlbumIdentityCanRepairStaleArtworkTreatment() throws {
    let passed = try { () throws -> Bool in
      let treatments = ArtworkTreatmentSettings()
      let staleImage = NSImage(size: NSSize(width: 1, height: 1))
      let currentImage = NSImage(size: NSSize(width: 2, height: 2))
      let staleAccent = ArtworkColor(red: 0.7, green: 0.2, blue: 0.1)
      let currentAccent = ArtworkColor(red: 0.1, green: 0.6, blue: 0.9)

      treatments.rememberAlbumArtwork(staleImage, accent: staleAccent, identity: "album")
      treatments.applyDisplayContext(.album("album"))
      treatments.rememberAlbumArtwork(currentImage, accent: currentAccent, identity: "album")
      treatments.applyDisplayContext(.album("album"))

      return treatments.artwork === currentImage
        && treatments.accent == currentAccent
    }()
    #expect(passed)
  }

  @Test("remembering hidden playback artwork preserves displayed album")
  func rememberingHiddenPlaybackArtworkPreservesDisplayedAlbum() throws {
    let passed = try { () throws -> Bool in
      let treatments = ArtworkTreatmentSettings()
      let displayedImage = NSImage(size: NSSize(width: 1, height: 1))
      let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
      let displayedAccent = ArtworkColor(red: 0.1, green: 0.3, blue: 0.8)
      let playbackAccent = ArtworkColor(red: 0.8, green: 0.2, blue: 0.1)

      treatments.rememberAlbumArtwork(
        displayedImage,
        accent: displayedAccent,
        identity: "displayed"
      )
      treatments.applyDisplayContext(.album("displayed"))
      treatments.rememberPlaybackArtwork(
        playbackImage,
        accent: playbackAccent,
        identity: "playing"
      )

      guard treatments.artwork === displayedImage, treatments.accent == displayedAccent else {
        return false
      }

      treatments.applyDisplayContext(
        .standard(activePlaybackIdentity: "playing")
      )
      return treatments.artwork === playbackImage
        && treatments.accent == playbackAccent
    }()
    #expect(passed)
  }

  @Test("non-album navigation centrally restores matching playback theme")
  func nonAlbumNavigationCentrallyRestoresMatchingPlaybackTheme() throws {
    let passed = try { () throws -> Bool in
      let treatments = ArtworkTreatmentSettings()
      let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
      let albumImage = NSImage(size: NSSize(width: 3, height: 3))
      let playbackAccent = ArtworkColor(red: 0.1, green: 0.3, blue: 0.9)
      let albumAccent = ArtworkColor(red: 0.9, green: 0.2, blue: 0.1)

      treatments.rememberPlaybackArtwork(
        playbackImage,
        accent: playbackAccent,
        identity: "blue-playing"
      )
      treatments.rememberAlbumArtwork(
        albumImage,
        accent: albumAccent,
        identity: "red-album"
      )
      treatments.applyDisplayContext(.album("red-album"))
      guard treatments.artwork === albumImage else { return false }

      treatments.applyDisplayContext(
        .standard(activePlaybackIdentity: "blue-playing")
      )
      return treatments.artwork === playbackImage
        && treatments.accent == playbackAccent
        && treatments.displayedIdentity == "blue-playing"
    }()
    #expect(passed)
  }

  @Test("pending themes hold the previous valid treatment")
  func pendingThemesHoldThePreviousValidTreatment() throws {
    let passed = try { () throws -> Bool in
      let treatments = ArtworkTreatmentSettings()
      let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
      let playbackAccent = ArtworkColor(red: 0.1, green: 0.3, blue: 0.9)
      treatments.rememberPlaybackArtwork(
        playbackImage,
        accent: playbackAccent,
        identity: "playing"
      )
      treatments.applyDisplayContext(
        .standard(activePlaybackIdentity: "playing")
      )
      treatments.applyDisplayContext(
        .standard(activePlaybackIdentity: "stale")
      )
      guard treatments.artwork === playbackImage,
        treatments.accent == playbackAccent,
        treatments.displayedIdentity == "playing"
      else { return false }

      treatments.applyDisplayContext(
        .resolve(
          hasEstablishedConnection: true,
          displayedAlbumID: nil,
          playbackIdentity: "playing"
        )
      )
      guard treatments.artwork === playbackImage, treatments.accent == playbackAccent else {
        return false
      }

      treatments.applyDisplayContext(.album("red-pending"))
      guard treatments.artwork === playbackImage else { return false }

      let albumImage = NSImage(size: NSSize(width: 3, height: 3))
      let albumAccent = ArtworkColor(red: 0.9, green: 0.2, blue: 0.1)
      treatments.rememberAlbumArtwork(
        albumImage,
        accent: albumAccent,
        identity: "red-pending"
      )
      treatments.applyDisplayContext(.album("red-pending"))
      return treatments.artwork === albumImage && treatments.accent == albumAccent
    }()
    #expect(passed)
  }

  @Test("late playback artwork cannot replace the disconnected brand theme")
  func latePlaybackArtworkCannotReplaceTheDisconnectedBrandTheme() {
    let treatments = ArtworkTreatmentSettings()
    let initialArtwork = NSImage(size: NSSize(width: 2, height: 2))
    let lateArtwork = NSImage(size: NSSize(width: 3, height: 3))

    treatments.rememberPlaybackArtwork(
      initialArtwork,
      accent: ArtworkColor(red: 0.2, green: 0.4, blue: 0.8),
      identity: "playing"
    )
    treatments.applyDisplayContext(.standard(activePlaybackIdentity: "playing"))
    treatments.applyDisplayContext(.brand)

    treatments.rememberPlaybackArtwork(
      lateArtwork,
      accent: ArtworkColor(red: 0.7, green: 0.2, blue: 0.1),
      identity: "playing"
    )
    treatments.applyDisplayContext(
      .resolve(
        hasEstablishedConnection: false,
        displayedAlbumID: nil,
        playbackIdentity: "playing"
      )
    )

    #expect(treatments.artwork == nil)
    #expect(treatments.accent == .fallback)
    #expect(treatments.displayedIdentity == nil)
  }

  @Test("empty playback context uses the static Coda brand theme")
  func emptyPlaybackContextUsesTheStaticCodaBrandTheme() throws {
    let passed = try { () throws -> Bool in
      let treatments = ArtworkTreatmentSettings()
      let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
      treatments.rememberPlaybackArtwork(
        playbackImage,
        accent: ArtworkColor(red: 0.1, green: 0.3, blue: 0.9),
        identity: "playing"
      )
      treatments.applyDisplayContext(.standard(activePlaybackIdentity: "playing"))
      treatments.applyDisplayContext(.standard(activePlaybackIdentity: nil))
      return treatments.artwork == nil
        && treatments.accent == .fallback
        && treatments.displayedIdentity == nil
    }()
    #expect(passed)
  }

  @Test("generated Coda cover extracts a warm accent")
  func generatedCodaCoverExtractsAWarmAccent() throws {
    let passed = try { () throws -> Bool in
      let accent = AlbumArtworkLoader.extractAccent(from: CodaPlaceholderArtwork.image)
      return accent.red > accent.green
        && accent.green > accent.blue
        && accent.red - accent.blue > 0.12
    }()
    #expect(passed)
  }

  @Test("pausing keeps an active now playing presentation visible")
  func pausingKeepsAnActiveNowPlayingPresentationVisible() throws {
    let passed = try { () throws -> Bool in
      let presentation = NowPlayingPresentationController()
      presentation.prepare(
        playbackKey: "album:playing",
        artwork: NSImage(size: NSSize(width: 2, height: 2)),
        accent: ArtworkColor(red: 0.7, green: 0.3, blue: 0.2)
      )
      presentation.updateContext(
        window: nil,
        hasEstablishedConnection: true,
        playbackKey: "album:playing",
        isPlaying: true
      )
      presentation.present()
      guard presentation.isPresented else { return false }
      presentation.updateContext(
        window: nil,
        hasEstablishedConnection: true,
        playbackKey: "album:playing",
        isPlaying: false
      )
      return presentation.isPresented
    }()
    #expect(passed)
  }

  @Test("now playing automatic presentation preference persists")
  func nowPlayingAutomaticPresentationPreferencePersists() throws {
    let passed = try { () throws -> Bool in
      let suiteName = "CodaTests-NowPlaying-\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let presentation = NowPlayingPresentationController(defaults: defaults)
      guard presentation.automaticallyPresents else { return false }
      presentation.automaticallyPresents = false

      return !NowPlayingPresentationController(defaults: defaults).automaticallyPresents
    }()
    #expect(passed)
  }

  @Test("now playing preference migrates the experimental key")
  func nowPlayingPreferenceMigratesTheExperimentalKey() throws {
    let passed = try { () throws -> Bool in
      let suiteName = "CodaTests-NowPlayingMigration-\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
      defer { defaults.removePersistentDomain(forName: suiteName) }
      defaults.set(false, forKey: "automatically-shows-now-playing")

      let presentation = NowPlayingPresentationController(defaults: defaults)
      return !presentation.automaticallyPresents
        && defaults.object(forKey: "automatically-show-now-playing") as? Bool == false
        && defaults.object(forKey: "automatically-shows-now-playing") == nil
    }()
    #expect(passed)
  }

  @Test("manual now playing remains available when automatic presentation is off")
  func manualNowPlayingRemainsAvailableWhenAutomaticPresentationIsOff() throws {
    let passed = try { () throws -> Bool in
      let suiteName = "CodaTests-ManualNowPlaying-\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
      defer { defaults.removePersistentDomain(forName: suiteName) }

      let presentation = NowPlayingPresentationController(defaults: defaults)
      presentation.automaticallyPresents = false
      presentation.prepare(
        playbackKey: "album:manual",
        artwork: NSImage(size: NSSize(width: 2, height: 2)),
        accent: ArtworkColor(red: 0.7, green: 0.3, blue: 0.2)
      )
      presentation.updateContext(
        window: nil,
        hasEstablishedConnection: true,
        playbackKey: "album:manual",
        isPlaying: true
      )
      presentation.present()
      return presentation.isPresented
    }()
    #expect(passed)
  }

  @Test("album artwork overrides embedded track artwork")
  func albumArtworkOverridesEmbeddedTrackArtwork() throws {
    let passed = try { () throws -> Bool in
      let song = RemoteSong(
        id: "1",
        title: "Track",
        albumId: "album-artwork",
        coverArt: "embedded-track-artwork"
      )
      return song.albumArtworkID == "album-artwork"
    }()
    #expect(passed)
  }
}

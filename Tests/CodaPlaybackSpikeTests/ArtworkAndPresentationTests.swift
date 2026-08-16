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
  func artworkPurposesUseOneBrowsingSizeAndOneRetinaPresentationSize() {
    #expect(ArtworkPurpose.standard.rawValue == 500)
    #expect(ArtworkPurpose.nowPlaying.rawValue == 1_200)
  }

  @Test("artwork invalidation advances the shared cache generation")
  func artworkInvalidationAdvancesTheSharedCacheGeneration() {
    let cache = ArtworkImageCache.shared
    let previousGeneration = cache.generation
    cache.invalidateAll()
    #expect(cache.generation == previousGeneration + 1)
  }

  @Test("queue entries keep browsing and now playing artwork separate")
  func queueEntriesKeepBrowsingAndNowPlayingArtworkSeparate() {
    let browsingURL = URL(string: "https://example.test/cover?size=500")!
    let nowPlayingURL = URL(string: "https://example.test/cover?size=1200")!
    let entry = QueueEntry(
      sourceID: "song",
      url: URL(string: "https://example.test/song")!,
      artworkURL: browsingURL,
      nowPlayingArtworkURL: nowPlayingURL,
      title: "Song"
    )
    #expect(entry.artworkURL == browsingURL)
    #expect(entry.nowPlayingArtworkURL == nowPlayingURL)
  }

  @Test("same album identity can repair stale artwork treatment")
  func sameAlbumIdentityCanRepairStaleArtworkTreatment() {
    let treatments = ArtworkTreatmentSettings()
    let staleImage = NSImage(size: NSSize(width: 1, height: 1))
    let currentImage = NSImage(size: NSSize(width: 2, height: 2))
    let staleAccent = ArtworkColor(red: 0.7, green: 0.2, blue: 0.1)
    let currentAccent = ArtworkColor(red: 0.1, green: 0.6, blue: 0.9)

    treatments.rememberAlbumArtwork(staleImage, accent: staleAccent, identity: "album")
    treatments.applyDisplayContext(.album("album"))
    treatments.rememberAlbumArtwork(currentImage, accent: currentAccent, identity: "album")
    treatments.applyDisplayContext(.album("album"))

    #expect(treatments.artwork === currentImage)
    #expect(treatments.accent == currentAccent)
  }

  @Test("remembering hidden playback artwork preserves displayed album")
  func rememberingHiddenPlaybackArtworkPreservesDisplayedAlbum() {
    let treatments = ArtworkTreatmentSettings()
    let displayedImage = NSImage(size: NSSize(width: 1, height: 1))
    let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
    let displayedAccent = ArtworkColor(red: 0.1, green: 0.3, blue: 0.8)
    let playbackAccent = ArtworkColor(red: 0.8, green: 0.2, blue: 0.1)

    treatments.rememberAlbumArtwork(
      displayedImage, accent: displayedAccent, identity: "displayed")
    treatments.applyDisplayContext(.album("displayed"))
    treatments.rememberPlaybackArtwork(
      playbackImage, accent: playbackAccent, identity: "playing")

    #expect(treatments.artwork === displayedImage)
    #expect(treatments.accent == displayedAccent)

    treatments.applyDisplayContext(.standard(activePlaybackIdentity: "playing"))
    #expect(treatments.artwork === playbackImage)
    #expect(treatments.accent == playbackAccent)
  }

  @Test("non-album navigation centrally restores matching playback theme")
  func nonAlbumNavigationCentrallyRestoresMatchingPlaybackTheme() {
    let treatments = ArtworkTreatmentSettings()
    let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
    let albumImage = NSImage(size: NSSize(width: 3, height: 3))
    let playbackAccent = ArtworkColor(red: 0.1, green: 0.3, blue: 0.9)
    let albumAccent = ArtworkColor(red: 0.9, green: 0.2, blue: 0.1)

    treatments.rememberPlaybackArtwork(
      playbackImage, accent: playbackAccent, identity: "blue-playing")
    treatments.rememberAlbumArtwork(
      albumImage, accent: albumAccent, identity: "red-album")
    treatments.applyDisplayContext(.album("red-album"))
    #expect(treatments.artwork === albumImage)

    treatments.applyDisplayContext(.standard(activePlaybackIdentity: "blue-playing"))
    #expect(treatments.artwork === playbackImage)
    #expect(treatments.accent == playbackAccent)
    #expect(treatments.displayedIdentity == "blue-playing")
  }

  @Test("pending themes hold the previous valid treatment")
  func pendingThemesHoldThePreviousValidTreatment() {
    let treatments = ArtworkTreatmentSettings()
    let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
    let playbackAccent = ArtworkColor(red: 0.1, green: 0.3, blue: 0.9)
    treatments.rememberPlaybackArtwork(
      playbackImage, accent: playbackAccent, identity: "playing")
    treatments.applyDisplayContext(.standard(activePlaybackIdentity: "playing"))
    treatments.applyDisplayContext(.standard(activePlaybackIdentity: "stale"))

    #expect(treatments.artwork === playbackImage)
    #expect(treatments.accent == playbackAccent)
    #expect(treatments.displayedIdentity == "playing")

    treatments.applyDisplayContext(
      .resolve(
        hasEstablishedConnection: true,
        displayedAlbumID: nil,
        playbackIdentity: "playing"
      ))
    #expect(treatments.artwork === playbackImage)
    #expect(treatments.accent == playbackAccent)

    treatments.applyDisplayContext(.album("red-pending"))
    #expect(treatments.artwork === playbackImage)

    let albumImage = NSImage(size: NSSize(width: 3, height: 3))
    let albumAccent = ArtworkColor(red: 0.9, green: 0.2, blue: 0.1)
    treatments.rememberAlbumArtwork(
      albumImage, accent: albumAccent, identity: "red-pending")
    treatments.applyDisplayContext(.album("red-pending"))
    #expect(treatments.artwork === albumImage)
    #expect(treatments.accent == albumAccent)
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
  func emptyPlaybackContextUsesTheStaticCodaBrandTheme() {
    let treatments = ArtworkTreatmentSettings()
    let playbackImage = NSImage(size: NSSize(width: 2, height: 2))
    treatments.rememberPlaybackArtwork(
      playbackImage,
      accent: ArtworkColor(red: 0.1, green: 0.3, blue: 0.9),
      identity: "playing"
    )
    treatments.applyDisplayContext(.standard(activePlaybackIdentity: "playing"))
    treatments.applyDisplayContext(.standard(activePlaybackIdentity: nil))
    #expect(treatments.artwork == nil)
    #expect(treatments.accent == .fallback)
    #expect(treatments.displayedIdentity == nil)
  }

  @Test("generated Coda cover extracts a warm accent")
  func generatedCodaCoverExtractsAWarmAccent() {
    let accent = AlbumArtworkLoader.extractAccent(from: CodaPlaceholderArtwork.image)
    #expect(accent.red > accent.green)
    #expect(accent.green > accent.blue)
    #expect(accent.red - accent.blue > 0.12)
  }

  @Test("pausing keeps an active now playing presentation visible")
  func pausingKeepsAnActiveNowPlayingPresentationVisible() {
    let presentation = NowPlayingPresentationController()
    presentation.prepare(
      playbackKey: "album:playing",
      artwork: NSImage(size: NSSize(width: 2, height: 2)),
      accent: ArtworkColor(red: 0.7, green: 0.3, blue: 0.2)
    )
    presentation.updateContext(
      window: nil, hasEstablishedConnection: true,
      playbackKey: "album:playing", isPlaying: true)
    presentation.present()
    #expect(presentation.isPresented)

    presentation.updateContext(
      window: nil, hasEstablishedConnection: true,
      playbackKey: "album:playing", isPlaying: false)
    #expect(presentation.isPresented)
  }

  @Test("now playing automatic presentation preference persists")
  func nowPlayingAutomaticPresentationPreferencePersists() throws {
    let suiteName = "CodaTests-NowPlaying-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let presentation = NowPlayingPresentationController(defaults: defaults)
    #expect(presentation.automaticallyPresents)
    presentation.automaticallyPresents = false
    #expect(!NowPlayingPresentationController(defaults: defaults).automaticallyPresents)
  }

  @Test("now playing preference migrates the experimental key")
  func nowPlayingPreferenceMigratesTheExperimentalKey() throws {
    let suiteName = "CodaTests-NowPlayingMigration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(false, forKey: "automatically-shows-now-playing")

    let presentation = NowPlayingPresentationController(defaults: defaults)
    #expect(!presentation.automaticallyPresents)
    #expect(defaults.object(forKey: "automatically-show-now-playing") as? Bool == false)
    #expect(defaults.object(forKey: "automatically-shows-now-playing") == nil)
  }

  @Test("manual now playing remains available when automatic presentation is off")
  func manualNowPlayingRemainsAvailableWhenAutomaticPresentationIsOff() throws {
    let suiteName = "CodaTests-ManualNowPlaying-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let presentation = NowPlayingPresentationController(defaults: defaults)
    presentation.automaticallyPresents = false
    presentation.prepare(
      playbackKey: "album:manual",
      artwork: NSImage(size: NSSize(width: 2, height: 2)),
      accent: ArtworkColor(red: 0.7, green: 0.3, blue: 0.2)
    )
    presentation.updateContext(
      window: nil, hasEstablishedConnection: true,
      playbackKey: "album:manual", isPlaying: true)
    presentation.present()
    #expect(presentation.isPresented)
  }

  @Test("album artwork overrides embedded track artwork")
  func albumArtworkOverridesEmbeddedTrackArtwork() {
    let song = RemoteSong(
      id: "1", title: "Track",
      albumId: "album-artwork", coverArt: "embedded-track-artwork")
    #expect(song.albumArtworkID == "album-artwork")
  }
}

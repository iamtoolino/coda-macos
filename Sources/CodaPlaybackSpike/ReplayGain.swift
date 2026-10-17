import Foundation

@propertyWrapper
struct LossyReplayGain: Decodable, Hashable, Sendable {
  var wrappedValue: ReplayGainMetadata?

  init(wrappedValue: ReplayGainMetadata?) { self.wrappedValue = wrappedValue }

  init(from decoder: any Decoder) throws {
    wrappedValue = try? ReplayGainMetadata(from: decoder)
  }
}

extension KeyedDecodingContainer {
  func decode(_ type: LossyReplayGain.Type, forKey key: Key) throws -> LossyReplayGain {
    try decodeIfPresent(type, forKey: key) ?? LossyReplayGain(wrappedValue: nil)
  }
}

/// OpenSubsonic values describe the original recording. Invalid individual fields are absent,
/// rather than making an otherwise playable song fail decoding.
struct ReplayGainMetadata: Decodable, Hashable, Sendable {
  var trackGain: Double? = nil
  var albumGain: Double? = nil
  var trackPeak: Double? = nil
  var albumPeak: Double? = nil

  init(trackGain: Double? = nil, albumGain: Double? = nil,
       trackPeak: Double? = nil, albumPeak: Double? = nil) {
    self.trackGain = trackGain
    self.albumGain = albumGain
    self.trackPeak = trackPeak
    self.albumPeak = albumPeak
  }

  private enum CodingKeys: String, CodingKey {
    case trackGain, albumGain, trackPeak, albumPeak
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    trackGain = try? values.decode(Double.self, forKey: .trackGain)
    albumGain = try? values.decode(Double.self, forKey: .albumGain)
    trackPeak = try? values.decode(Double.self, forKey: .trackPeak)
    albumPeak = try? values.decode(Double.self, forKey: .albumPeak)
  }
}

enum ReplayGainPolicy {
  static let fallbackDb = -9.0

  static func gainDb(
    enabled: Bool, context: AlbumSequenceContext?, metadata: ReplayGainMetadata?
  ) -> Double {
    guard enabled else { return 0 }
    let usesAlbum = context?.isAlbumSequence == true && metadata?.albumGain?.isFinite == true
    let gain = usesAlbum ? metadata?.albumGain : metadata?.trackGain
    let peak = usesAlbum ? metadata?.albumPeak : metadata?.trackPeak
    guard let gain, gain.isFinite else { return fallbackDb }
    let result: Double
    if let peak, peak.isFinite, peak > 0 {
      result = min(gain, -20 * log10(peak))
    } else {
      result = gain
    }
    // mpv's constant gain path supports -150...150 dB. Normal tags are well inside this range.
    return min(150, max(-150, result))
  }
}

struct PlaybackBackendItem: Equatable, Sendable {
  let url: URL
  var replayGainDb: Double = 0
}

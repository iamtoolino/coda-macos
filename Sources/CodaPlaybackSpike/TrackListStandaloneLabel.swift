import SwiftUI

/// Row contents only; selection, playback, dragging and geometry stay with each list.
struct TrackListStandaloneLabel: View {
  let artworkURL: URL?
  let title: String
  let artist: String
  let durationSeconds: Int
  let isCurrent: Bool
  let isPlaying: Bool
  let accent: Color
  var compact = false

  var body: some View {
    HStack(spacing: compact ? 10 : 12) {
      ArtworkImage(url: artworkURL, cornerRadius: 5)
        .frame(width: compact ? 36 : 44, height: compact ? 36 : 44)
        .overlay {
          // White on a scrim: an accent derived from this very cover would blend into it.
          if isCurrent {
            ZStack {
              RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(.black.opacity(0.4))
              Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                .font(.callout)
                .foregroundStyle(.white)
            }
          }
        }
      TrackRowLabel(
        title: title,
        artist: artist,
        isCompilation: false,
        titleColor: isCurrent ? accent : .primary,
        titleFont: compact ? .callout : .body,
        artistFont: compact ? .caption2 : .caption,
        alwaysShowsArtist: true
      )
      Spacer(minLength: 4)
      Text(formatDuration(durationSeconds))
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
  }
}

import Foundation
import SwiftUI

struct RemoteArtistReference: Decodable, Hashable, Sendable, Identifiable {
  let id: String
  let name: String
}

struct ArtistCredit: Hashable, Sendable {
  struct Segment: Equatable {
    let text: String
    let artistID: String?
  }

  let name: String
  let artists: [RemoteArtistReference]

  init(name: String, artists: [RemoteArtistReference], legacyArtistID: String? = nil) {
    self.name = name
    if artists.isEmpty, let legacyArtistID, !legacyArtistID.isEmpty, !name.isEmpty {
      self.artists = [RemoteArtistReference(id: legacyArtistID, name: name)]
    } else {
      var seen = Set<String>()
      self.artists = artists.filter { !$0.id.isEmpty && !$0.name.isEmpty && seen.insert($0.id).inserted }
    }
  }

  // Match known identities inside the server's credit; punctuation never defines identities.
  var segments: [Segment] {
    var result: [Segment] = []
    var position = name.startIndex
    while position < name.endIndex {
      let matches = artists.compactMap { artist -> (RemoteArtistReference, Range<String.Index>)? in
        guard let range = name.range(of: artist.name, range: position..<name.endIndex) else { return nil }
        return (artist, range)
      }
      guard let match = matches.min(by: {
        if $0.1.lowerBound != $1.1.lowerBound { return $0.1.lowerBound < $1.1.lowerBound }
        return $0.0.name.count > $1.0.name.count
      }) else {
        result.append(Segment(text: String(name[position...]), artistID: nil))
        break
      }
      if position < match.1.lowerBound {
        result.append(Segment(text: String(name[position..<match.1.lowerBound]), artistID: nil))
      }
      result.append(Segment(text: String(name[match.1]), artistID: match.0.id))
      position = match.1.upperBound
    }
    return result
  }

  var unlinkedArtists: [RemoteArtistReference] {
    let linked = Set(segments.compactMap(\.artistID))
    return artists.filter { !linked.contains($0.id) }
  }
}

// Native Text links preserve wrapping, keyboard activation and accessibility for each artist.
struct ArtistCreditView: View {
  let credit: ArtistCredit
  let openArtist: (String) -> Void

  var body: some View {
    HStack(spacing: 4) {
      Text(linkedText)
        .environment(\.openURL, OpenURLAction { url in
          guard url.scheme == "coda-artist",
            let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
              .queryItems?.first(where: { $0.name == "id" })?.value
          else { return .discarded }
          openArtist(id)
          return .handled
        })
        .accessibilityRepresentation {
          HStack {
            ForEach(Array(credit.segments.enumerated()), id: \.offset) { item in
              if let id = item.element.artistID {
                Button(item.element.text) { openArtist(id) }
                  .accessibilityAddTraits(.isLink)
              } else {
                Text(item.element.text)
              }
            }
          }
          .accessibilityElement(children: .contain)
        }
      if !credit.unlinkedArtists.isEmpty {
        Menu {
          ForEach(credit.unlinkedArtists) { artist in
            Button(artist.name) { openArtist(artist.id) }
          }
        } label: {
          Image(systemName: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Show credited artists")
      }
    }
    .accessibilityElement(children: .contain)
  }

  private var linkedText: AttributedString {
    credit.segments.reduce(into: AttributedString()) { text, segment in
      var part = AttributedString(segment.text)
      if let id = segment.artistID {
        var components = URLComponents()
        components.scheme = "coda-artist"
        components.host = "show"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        part.link = components.url
      }
      text.append(part)
    }
  }
}

func trackRowTitle(title: String, artist: String, isCompilation: Bool) -> String {
  isCompilation && !artist.isEmpty ? "\(artist) — \(title)" : title
}

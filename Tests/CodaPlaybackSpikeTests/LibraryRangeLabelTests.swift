import Foundation
import Testing

@testable import CodaPlaybackSpike

@Suite("Library range label")
struct LibraryRangeLabelTests {
  private static let zurich = TimeZone(identifier: "Europe/Zurich")!

  private static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2
    calendar.timeZone = zurich
    return calendar
  }

  /// Thursday 2026-11-12, 15:00 in Zurich.
  private static var now: Date {
    calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 15))!
  }

  private func label(_ albums: [RemoteAlbum], _ kind: AlbumCollectionKind) -> String? {
    LibraryRangeLabel.label(
      for: albums, kind: kind, now: Self.now, calendar: Self.calendar,
      locale: Locale(identifier: "en_US"))
  }

  private func added(_ dates: String?...) -> [RemoteAlbum] {
    dates.enumerated().map { RemoteAlbum(id: "\($0.offset)", name: "A", created: $0.element) }
  }

  @Test("letters fold accents and special letters, everything else is #")
  func lettersFoldAccents() {
    #expect(LibraryRangeLabel.sectionLetter("Élan") == "E")
    #expect(LibraryRangeLabel.sectionLetter("Øresund") == "O")
    #expect(LibraryRangeLabel.sectionLetter("Ægis") == "A")
    #expect(LibraryRangeLabel.sectionLetter("Œuvre") == "O")
    #expect(LibraryRangeLabel.sectionLetter("ßeta") == "S")
    #expect(LibraryRangeLabel.sectionLetter("Þing") == "T")
    #expect(LibraryRangeLabel.sectionLetter("Łódź") == "L")
    #expect(LibraryRangeLabel.sectionLetter("2 Hours") == "#")
    #expect(LibraryRangeLabel.sectionLetter("東京") == "#")
    #expect(LibraryRangeLabel.sectionLetter("") == "#")
  }

  @Test("leading articles are ignored and a server sort name wins")
  func articlesAndSortName() {
    #expect(LibraryRangeLabel.titleKey(RemoteAlbum(id: "1", name: "The Velvet Orchard")) == "Velvet Orchard")
    #expect(LibraryRangeLabel.titleKey(RemoteAlbum(id: "2", name: "Theremin Club")) == "Theremin Club")
    #expect(LibraryRangeLabel.titleKey(RemoteAlbum(id: "3", name: "The")) == "The")
    #expect(LibraryRangeLabel.titleKey(RemoteAlbum(id: "5", name: "The C", sortName: "Zed")) == "Zed")
  }

  @Test("title names the first and last visible letter")
  func titleRange() {
    let names = ["The Alpha", "Beta", "Charlie"].enumerated().map {
      RemoteAlbum(id: "\($0.offset)", name: $0.element)
    }
    #expect(label(names, .alphabetical) == "A – C")
    #expect(label(Array(names.prefix(1)), .alphabetical) == "A")
    #expect(label([], .alphabetical) == nil)
  }

  @Test("recently added names a week, a month, a span of months or of years")
  func recentlyAdded() {
    #expect(label(added("2026-11-10T08:00:00Z", "2026-11-11"), .recentlyAdded) == "Added this week")
    #expect(label(added("2026-09-20", "2026-09-02T10:00:00.123Z"), .recentlyAdded) == "Added in September")
    #expect(label(added("2026-09-20", "2026-08-02"), .recentlyAdded) == "Added Aug – Sep")
    #expect(label(added("2025-09-20", "2025-08-02"), .recentlyAdded) == "Added Aug – Sep 2025")
    #expect(label(added("2025-03-01", "2025-03-20"), .recentlyAdded) == "Added in March 2025")
    #expect(label(added("2021-01-01", "2019-06-01"), .recentlyAdded) == "Added 2019 – 2021")
    #expect(label(added("garbage", "2026-09-20"), .recentlyAdded) == "Added in September")
    #expect(label(added(nil, "garbage"), .recentlyAdded) == "Undated")
  }

  @Test("recently played adds today")
  func recentlyPlayed() {
    let today = [RemoteAlbum(id: "1", name: "A", played: "2026-11-12T09:00:00Z")]
    #expect(label(today, .recentlyPlayed) == "Played today")
    let october = [RemoteAlbum(id: "1", name: "A", played: "2026-10-03")]
    #expect(label(october, .recentlyPlayed) == "Played in October")
  }

  @Test("releases, plays and stars")
  func yearsPlaysStars() {
    let years = [1997, 1994].map { RemoteAlbum(id: "\($0)", name: "A", year: $0) }
    #expect(label(years, .recentReleases) == "Released 1994 – 1997")
    #expect(label(Array(years.prefix(1)), .recentReleases) == "Released 1997")
    #expect(label([RemoteAlbum(id: "u", name: "A")], .recentReleases) == "Undated")

    func plays(_ counts: Int...) -> [RemoteAlbum] {
      counts.map { RemoteAlbum(id: "\($0)", name: "A", playCount: $0) }
    }
    #expect(label(plays(310, 120, 37), .mostPlayed) == "35+ plays")
    #expect(label(plays(89), .mostPlayed) == "85+ plays")
    #expect(label(plays(123), .mostPlayed) == "120+ plays")
    #expect(label(plays(137), .mostPlayed) == "130+ plays")
    #expect(label(plays(100), .mostPlayed) == "100+ plays")
    #expect(label(plays(14), .mostPlayed) == "10+ plays")
    #expect(label(plays(10), .mostPlayed) == "10+ plays")
    #expect(label(plays(7), .mostPlayed) == "7+ plays")
    #expect(label(plays(3), .mostPlayed) == "3+ plays")
    #expect(label(plays(1), .mostPlayed) == "1+ plays")
    #expect(label(plays(3, 0), .mostPlayed) == "Not played")

    func rated(_ ratings: Int...) -> [RemoteAlbum] {
      ratings.enumerated().map { RemoteAlbum(id: "\($0.offset)", name: "A", userRating: $0.element) }
    }
    #expect(label(rated(4, 4), .topRated) == "4 stars")
    #expect(label(rated(4, 3), .topRated) == "3 – 4 stars")
    #expect(label(rated(2, 0), .topRated) == "Up to 2 stars")
    #expect(label(rated(0), .topRated) == "Unrated")
  }

  @Test("artists by name use plain-name letters, recently added uses newest album dates")
  func artists() {
    let names = ["The Ataris", "Beatles", "Chicago", "2Pac"].enumerated().map {
      RemoteArtist(id: "\($0.offset)", name: $0.element)
    }
    func artistLabel(_ visible: [RemoteArtist], _ kind: ArtistCollectionKind, _ dates: [String: String] = [:]) -> String? {
      LibraryRangeLabel.label(
        for: visible, kind: kind, addedDates: dates, now: Self.now, calendar: Self.calendar,
        locale: Locale(identifier: "en_US"))
    }
    #expect(artistLabel(Array(names.prefix(3)), .alphabetical) == "T – C")
    #expect(artistLabel(Array(names[1...2]), .alphabetical) == "B – C")
    #expect(artistLabel([names[3]], .alphabetical) == "#")
    #expect(artistLabel([], .alphabetical) == nil)
    #expect(
      artistLabel(Array(names.prefix(2)), .recentlyAdded, ["0": "2026-09-20", "1": "2026-08-02"])
        == "Added Aug – Sep")
    #expect(artistLabel(Array(names.prefix(2)), .recentlyAdded) == "Undated")
  }
}

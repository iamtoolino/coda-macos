import Foundation

/// The quiet titlebar hint in Albums and Artists: names the range of what is on screen, e.g.
/// "Added in September" or "A – C". Letter rules follow Coda Android's `LibraryIndex.kt`.
enum LibraryRangeLabel {
  /// `visible` is in list order; nil when there is nothing sensible to say.
  static func label(
    for visible: [RemoteAlbum],
    kind: AlbumCollectionKind,
    now: Date = Date(),
    calendar: Calendar = mondayCalendar(),
    locale: Locale = .current
  ) -> String? {
    guard let first = visible.first, let last = visible.last else { return nil }
    switch kind {
    case .alphabetical:
      let from = sectionLetter(titleKey(first))
      let to = sectionLetter(titleKey(last))
      return from == to ? from : "\(from) – \(to)"
    case .recentlyAdded:
      return dateRange(visible.map { parseDate($0.created) }, verb: "Added", includesToday: false,
        now: now, calendar: calendar, locale: locale)
    case .recentlyPlayed:
      return dateRange(visible.map { parseDate($0.played) }, verb: "Played", includesToday: true,
        now: now, calendar: calendar, locale: locale)
    case .recentReleases:
      let years = visible.compactMap(\.releaseYear).filter { $0 > 0 }
      guard let low = years.min(), let high = years.max() else { return "Undated" }
      return low == high ? "Released \(low)" : "Released \(low) – \(high)"
    case .mostPlayed:
      // Navidrome's album play count adds up its track plays, so a number here would mislead.
      return nil
    case .topRated:
      let ratings = visible.map { $0.userRating ?? 0 }.filter { (1...5).contains($0) }
      guard let low = ratings.min(), let high = ratings.max() else { return "Unrated" }
      let hasUnrated = ratings.count < visible.count
      if hasUnrated { return "Up to \(countLabel(high, "star"))" }
      return low == high ? countLabel(low, "star") : "\(low) – \(countLabel(high, "star"))"
    }
  }

  /// Artists: letters as the Name sort orders them (plain names, no articles dropped), or
  /// when each artist's newest album was added. `addedDates` maps artist IDs to that date.
  static func label(
    for visible: [RemoteArtist],
    kind: ArtistCollectionKind,
    addedDates: [String: String],
    now: Date = Date(),
    calendar: Calendar = mondayCalendar(),
    locale: Locale = .current
  ) -> String? {
    guard let first = visible.first, let last = visible.last else { return nil }
    switch kind {
    case .alphabetical:
      let from = sectionLetter(first.name)
      let to = sectionLetter(last.name)
      return from == to ? from : "\(from) – \(to)"
    case .recentlyAdded:
      return dateRange(visible.map { parseDate(addedDates[$0.id]) }, verb: "Added",
        includesToday: false, now: now, calendar: calendar, locale: locale)
    }
  }

  // MARK: Dates

  private static func dateRange(
    _ dates: [Date?],
    verb: String,
    includesToday: Bool,
    now: Date,
    calendar: Calendar,
    locale: Locale
  ) -> String {
    let known = dates.compactMap(\.self)
    guard let oldest = known.min(), let newest = known.max() else { return "Undated" }
    let startOfToday = calendar.startOfDay(for: now)
    if includesToday, oldest >= startOfToday { return "\(verb) today" }
    let startOfWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday
    if oldest >= startOfWeek { return "\(verb) this week" }

    let month = DateFormatter()
    month.calendar = calendar
    month.locale = locale
    month.timeZone = calendar.timeZone
    let currentYear = calendar.component(.year, from: now)
    let oldYear = calendar.component(.year, from: oldest)
    let newYear = calendar.component(.year, from: newest)
    guard oldYear == newYear else { return "\(verb) \(oldYear) – \(newYear)" }
    let yearSuffix = oldYear == currentYear ? "" : " \(oldYear)"
    if calendar.isDate(oldest, equalTo: newest, toGranularity: .month) {
      month.dateFormat = "LLLL"
      return "\(verb) in \(month.string(from: oldest))\(yearSuffix)"
    }
    month.dateFormat = "LLL"
    return "\(verb) \(month.string(from: oldest)) – \(month.string(from: newest))\(yearSuffix)"
  }

  static func mondayCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.firstWeekday = 2
    calendar.timeZone = .current
    return calendar
  }

  // Built once: creating ISO formatters per album is slow.
  nonisolated(unsafe) private static let isoWithFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  /// ISO date-time with or without fractional seconds, else the first 10 characters as a
  /// local date at the start of the day; anything else is no date.
  static func parseDate(_ value: String?, timeZone: TimeZone = .current) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    if let date = isoWithFraction.date(from: value) ?? isoPlain.date(from: value) { return date }
    guard value.count >= 10 else { return nil }
    let day = DateFormatter()
    day.calendar = Calendar(identifier: .gregorian)
    day.locale = Locale(identifier: "en_US_POSIX")
    day.timeZone = timeZone
    day.dateFormat = "yyyy-MM-dd"
    return day.date(from: String(value.prefix(10)))
  }

  // MARK: Letters

  /// Navidrome's default ignored articles; album lists carry no server list.
  static let defaultIgnoredArticles = ["The", "El", "La", "Los", "Las", "Le", "Les", "Os", "As", "O", "A"]

  /// The server's `sortName` when present, else the title without a leading ignored article.
  static func titleKey(_ album: RemoteAlbum) -> String {
    if let sortName = album.sortName?.trimmingCharacters(in: .whitespaces), !sortName.isEmpty {
      return sortName
    }
    return stripArticle(album.name, articles: defaultIgnoredArticles)
  }

  static func stripArticle(_ name: String, articles: [String]) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    let lower = trimmed.lowercased()
    for article in articles {
      let prefix = article.lowercased() + " "
      if lower.hasPrefix(prefix), trimmed.count > article.count + 1 {
        return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
      }
    }
    return trimmed
  }

  private static let specialFolds: [Character: String] = [
    "ø": "o", "æ": "ae", "œ": "oe", "ł": "l", "đ": "d", "ð": "d", "þ": "th", "ß": "ss", "ı": "i",
  ]

  /// Trim, lowercase, drop accents, then map the letters that do not decompose.
  static func fold(_ key: String) -> String {
    let base = key.trimmingCharacters(in: .whitespaces)
      .lowercased()
      .folding(options: .diacriticInsensitive, locale: nil)
    var result = ""
    for character in base {
      if let mapped = specialFolds[character] {
        result += mapped
      } else {
        result.append(character)
      }
    }
    return result
  }

  /// "A"…"Z" for a Latin first letter, otherwise "#".
  static func sectionLetter(_ key: String) -> String {
    guard let first = fold(key).unicodeScalars.first, ("a"..."z").contains(first) else {
      return "#"
    }
    return String(first).uppercased()
  }
}

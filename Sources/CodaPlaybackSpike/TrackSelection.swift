import AppKit
import Foundation

struct TrackSelectionModifiers: OptionSet {
  let rawValue: Int

  static let shift = Self(rawValue: 1 << 0)
  static let command = Self(rawValue: 1 << 1)
}

struct OrderedTrackSelection<ID: Hashable> {
  let ids: [ID]
  let anchor: ID?
}

func updatedTrackSelection<ID: Hashable>(
  current: [ID],
  anchor: ID?,
  clicked: ID,
  ordered: [ID],
  modifiers: TrackSelectionModifiers
) -> OrderedTrackSelection<ID> {
  if modifiers.contains(.shift),
    let anchor,
    let anchorIndex = ordered.firstIndex(of: anchor),
    let clickedIndex = ordered.firstIndex(of: clicked)
  {
    let bounds = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
    let range = Set(ordered[bounds])
    let selected = modifiers.contains(.command)
      ? Set(current).union(range)
      : range
    return OrderedTrackSelection(
      ids: ordered.filter(selected.contains),
      anchor: anchor
    )
  }

  if modifiers.contains(.command) {
    var selected = Set(current)
    if selected.contains(clicked) {
      selected.remove(clicked)
    } else {
      selected.insert(clicked)
    }
    return OrderedTrackSelection(
      ids: ordered.filter(selected.contains),
      anchor: clicked
    )
  }

  return OrderedTrackSelection(ids: [clicked], anchor: clicked)
}

@MainActor
func currentTrackSelectionModifiers() -> TrackSelectionModifiers {
  let eventModifiers = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
  var modifiers: TrackSelectionModifiers = []
  if eventModifiers.contains(.shift) {
    modifiers.insert(.shift)
  }
  if eventModifiers.contains(.command) {
    modifiers.insert(.command)
  }
  return modifiers
}

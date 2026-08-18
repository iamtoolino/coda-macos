import AppKit
import Combine
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

struct OrderedQueueSelection<ID: Hashable> {
  let ids: [ID]
  let anchorIDs: [ID]
}

@MainActor
final class QueueSelectionModel: ObservableObject {
  @Published private(set) var selectedEntryIDs: [UUID]?
  private var anchorEntryIDs: [UUID] = []

  func select(
    _ entryIDs: [UUID],
    orderedBy orderedEntryIDs: [UUID],
    modifiers: TrackSelectionModifiers
  ) {
    let selection = updatedQueueSelection(
      current: selectedEntryIDs ?? [],
      anchorIDs: anchorEntryIDs,
      clickedIDs: entryIDs,
      ordered: orderedEntryIDs,
      modifiers: modifiers
    )
    selectedEntryIDs = selection.ids.isEmpty ? nil : selection.ids
    anchorEntryIDs = selection.anchorIDs
  }

  func selectAll(_ orderedEntryIDs: [UUID]) {
    guard !orderedEntryIDs.isEmpty else {
      clear()
      return
    }
    selectedEntryIDs = orderedEntryIDs
    anchorEntryIDs = [orderedEntryIDs[0]]
  }

  func remove(_ entryIDs: [UUID]) {
    let removed = Set(entryIDs)
    if let selectedEntryIDs {
      let remaining = selectedEntryIDs.filter { !removed.contains($0) }
      self.selectedEntryIDs = remaining.isEmpty ? nil : remaining
    }
    if !removed.isDisjoint(with: anchorEntryIDs) {
      anchorEntryIDs = []
    }
  }

  func reconcile(with orderedEntryIDs: [UUID]) {
    let queueIDs = Set(orderedEntryIDs)
    if let selectedEntryIDs {
      let selected = Set(selectedEntryIDs)
      let remaining = orderedEntryIDs.filter(selected.contains)
      self.selectedEntryIDs = remaining.isEmpty ? nil : remaining
    }
    if !anchorEntryIDs.allSatisfy(queueIDs.contains) {
      anchorEntryIDs = []
    }
  }

  func clear() {
    selectedEntryIDs = nil
    anchorEntryIDs = []
  }
}

@MainActor
final class QueueSelectionShortcutMonitor: ObservableObject {
  nonisolated(unsafe) private var monitor: Any?

  init(selection: QueueSelectionModel, player: PlayerController, session: AppSession) {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      guard let keyWindow = NSApp.keyWindow else { return event }
      let isMainPlaybackWindow = keyWindow.title != "Coda Status"
        && keyWindow.sheetParent == nil
      let queueIsVisible = codaQueueIsVisible(
        windowWidth: keyWindow.contentView?.bounds.width ?? 0,
        hasEstablishedConnection: session.hasEstablishedConnection
      )
      let appIsActive = NSApp.isActive
      let isTextEditing = keyWindow.firstResponder is NSTextView

      if shouldRouteQueueSelectAllShortcut(
        modifiers: event.modifierFlags,
        charactersIgnoringModifiers: event.charactersIgnoringModifiers,
        appIsActive: appIsActive,
        mainPlaybackWindowIsKey: isMainPlaybackWindow,
        queueIsVisible: queueIsVisible,
        isTextEditing: isTextEditing
      ) {
        selection.selectAll(player.queue.map(\.id))
        return nil
      }

      if shouldRouteQueueClearSelectionShortcut(
        modifiers: event.modifierFlags,
        charactersIgnoringModifiers: event.charactersIgnoringModifiers,
        appIsActive: appIsActive,
        mainPlaybackWindowIsKey: isMainPlaybackWindow,
        queueIsVisible: queueIsVisible,
        isTextEditing: isTextEditing,
        hasSelection: selection.selectedEntryIDs != nil
      ) {
        selection.clear()
        return nil
      }

      return event
    }
  }

  deinit {
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
  }
}

func shouldRouteQueueSelectAllShortcut(
  modifiers: NSEvent.ModifierFlags,
  charactersIgnoringModifiers: String?,
  appIsActive: Bool,
  mainPlaybackWindowIsKey: Bool,
  queueIsVisible: Bool,
  isTextEditing: Bool
) -> Bool {
  queueSelectionActionModifiers(modifiers) == .command
    && charactersIgnoringModifiers?.lowercased() == "a"
    && queueSelectionShortcutsAreActive(
      appIsActive: appIsActive,
      mainPlaybackWindowIsKey: mainPlaybackWindowIsKey,
      queueIsVisible: queueIsVisible,
      isTextEditing: isTextEditing
    )
}

func shouldRouteQueueClearSelectionShortcut(
  modifiers: NSEvent.ModifierFlags,
  charactersIgnoringModifiers: String?,
  appIsActive: Bool,
  mainPlaybackWindowIsKey: Bool,
  queueIsVisible: Bool,
  isTextEditing: Bool,
  hasSelection: Bool
) -> Bool {
  queueSelectionActionModifiers(modifiers).isEmpty
    && charactersIgnoringModifiers == "\u{1B}"
    && hasSelection
    && queueSelectionShortcutsAreActive(
      appIsActive: appIsActive,
      mainPlaybackWindowIsKey: mainPlaybackWindowIsKey,
      queueIsVisible: queueIsVisible,
      isTextEditing: isTextEditing
    )
}

private func queueSelectionActionModifiers(
  _ modifiers: NSEvent.ModifierFlags
) -> NSEvent.ModifierFlags {
  modifiers.intersection([.command, .option, .control, .shift])
}

private func queueSelectionShortcutsAreActive(
  appIsActive: Bool,
  mainPlaybackWindowIsKey: Bool,
  queueIsVisible: Bool,
  isTextEditing: Bool
) -> Bool {
  appIsActive
    && mainPlaybackWindowIsKey
    && queueIsVisible
    && !isTextEditing
}

func queueSelectionContainsAll<ID: Hashable>(
  _ selected: [ID],
  collection: [ID]
) -> Bool {
  guard !collection.isEmpty else { return false }
  let selectedSet = Set(selected)
  return collection.allSatisfy(selectedSet.contains)
}

func queueCollectionDragIDs<ID: Hashable>(
  collection: [ID],
  selected: [ID]
) -> [ID] {
  queueSelectionContainsAll(selected, collection: collection)
    ? selected
    : collection
}

func updatedQueueSelection<ID: Hashable>(
  current: [ID],
  anchorIDs: [ID],
  clickedIDs: [ID],
  ordered: [ID],
  modifiers: TrackSelectionModifiers
) -> OrderedQueueSelection<ID> {
  let clickedSet = Set(clickedIDs)
  let orderedClicked = ordered.filter(clickedSet.contains)
  guard !orderedClicked.isEmpty else {
    return OrderedQueueSelection(ids: current, anchorIDs: anchorIDs)
  }

  if modifiers.contains(.shift) {
    let anchorIndices = anchorIDs.compactMap(ordered.firstIndex)
    let clickedIndices = orderedClicked.compactMap(ordered.firstIndex)
    if let anchorStart = anchorIndices.min(), let anchorEnd = anchorIndices.max(),
      let clickedStart = clickedIndices.min(), let clickedEnd = clickedIndices.max()
    {
      let bounds = min(anchorStart, clickedStart)...max(anchorEnd, clickedEnd)
      let range = Set(ordered[bounds])
      let selected = modifiers.contains(.command)
        ? Set(current).union(range)
        : range
      return OrderedQueueSelection(
        ids: ordered.filter(selected.contains),
        anchorIDs: anchorIDs
      )
    }
  }

  if modifiers.contains(.command) {
    var selected = Set(current)
    if queueSelectionContainsAll(current, collection: orderedClicked) {
      selected.subtract(orderedClicked)
    } else {
      selected.formUnion(orderedClicked)
    }
    return OrderedQueueSelection(
      ids: ordered.filter(selected.contains),
      anchorIDs: orderedClicked
    )
  }

  return OrderedQueueSelection(ids: orderedClicked, anchorIDs: orderedClicked)
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

# Queue and playlist presentation

Queue and playlist use the same grouping policy. Rendering and interaction remain owned by
their respective views.

## Grouping rules

- Preserve the supplied order. Grouping never sorts, deduplicates, or moves tracks.
- Group contiguous tracks with the same non-empty server album ID. IDs are whitespace-trimmed
  and otherwise compared exactly; each list belongs to one server session.
- Partial albums, out-of-order track numbers, multidisc albums, and duplicate songs can share
  a group. Adding the same album twice consecutively produces one combined group.
- Intervening music splits groups. Moving or removing it may reunite neighbouring groups.
- A single track is a standalone occurrence, even when its release has only one track.
- Missing or blank album IDs always produce separate singleton groups. Do not guess from titles,
  artists, artwork, or insertion history.
- Never join the end of the list to its beginning for repeat playback.

Queue album-header selection, drag, and removal apply to all occurrences in the visible group,
including repeated copies. Occurrence UUIDs stay distinct even when song IDs are identical.
Disc actions apply to the contiguous section beneath that disc heading. If a repeated album
produces two separate Disc 1 sections, their actions and durations remain separate.

## Ownership

`AlbumSequenceResolver` owns normalized album identity, neighbouring-track context, and contiguous
group ranges. It accepts metadata directly; a playlist does not need stream URLs or synthetic
queue entries to use it. The queue adapter also supplies explicit continuation intent for album
resume, which does not change grouping or ReplayGain's adjacency rule.

`TrackListPresentation` adapts those ranges to queue occurrences and indexed playlist songs.
It preserves each surface's identity model and computes group labels and disc-section scopes.
`TrackListAlbumLabel` shares header contents at compact and regular sizes. `TrackRowLabel` already
shares track text styling.

The queue keeps ownership of drop geometry, scrolling, collection actions, and occurrence-based
selection. The playlist keeps index-based selection and copying tracks into the queue. Playback
ordering and mutations remain in `PlayerController`; presentation never writes back a regrouped
or sorted queue.

## Current checkpoint and next layout step

This refactor migrates grouping and header contents. It retains the existing header-and-track-row
layout for every group, including singletons. Compact standalone rows are a separate iteration.

The agreed standalone layout will show cover, title, track artist, duration, and playback indicator,
without an album header, disc heading, or original album track number. Both surfaces will use
those rules with their existing density. The queue's current wrapper, row identity, scroll target,
measurement callbacks, and interaction modifiers should be retained.

Presentation follows the current list immediately. ReplayGain and album-resume eligibility use
the playback occurrence snapshot instead: editing neighbours must not retroactively change an
already-started song's gain or bookmark eligibility.

## Verification

Automated checks cover identical queue/playlist boundaries, missing IDs, partial and repeated
albums, duplicate song occurrences, split/reunion after movement, deletion down to a singleton,
selection and playback identity, and repeated disc-section action scope.

For UI verification, inspect a normal-width window with the docked queue and a narrow window with
the compact queue overlay. Check repeated album additions, track and header multi-selection,
dragging a track out and back, disc selection/removal, drops at group boundaries, Return to Playing,
restoration, and inactive-window first clicks. Compare header appearance and track order in the
playlist. Automated policy tests do not verify SwiftUI geometry or native drag sessions.

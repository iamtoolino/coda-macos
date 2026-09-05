# Coda album resume design

Status: reference product design and Android implementation handoff for the experimental
[Album Resume Bookmark protocol](album-resume-bookmarks.md). Coda macOS is the reference prototype;
Coda Android should implement the same product semantics using platform-native UI and lifecycle
primitives.

## Product behavior

- Completing any non-final canonical track of an eligible album counts as starting that album and
  records the next canonical track. The complete album need not be present in the queue.
- Completing the album's final track removes its continuation marker.
- Manual skips, seeking, pausing, quitting, and queue restoration do not advance album progress.
- Home shows a horizontal `Continue Listening` shelf between Recently Played and Playlists.
- Show at most 20 cards, newest bookmark first, without a disclosure chevron or separate list.
- A card initially shows only artwork, album title, and album artist. Resume-track text and
  remaining runtime are intentionally deferred.
- Include the currently playing or paused album in Continue Listening; cards only navigate.
- Hide the Resume header and remaining-track highlight in album detail when that album is
  the current playback entry, including while paused. Merely queued albums retain the treatment.
  This only changes presentation; the saved bookmark remains intact.
- Clicking a Continue card opens ordinary album detail without changing playback or the queue.
  Album detail highlights the saved track and all remaining tracks as one continuous group,
  including intervening disc headings. A Resume header uses the same Play and Append icons as
  the album header, with explicit tooltips and accessibility labels. The group is also visible
  when the album is opened elsewhere.
  Both actions use the saved track and all remaining tracks in canonical album order.
  Play replaces the queue and starts playback. Append preserves existing playback and stays
  paused if the queue was empty. Neither action automatically opens NPS or leaves album detail.
  The existing album-header buttons still operate on the entire album.
  The marker is not movable and these actions do not edit the saved bookmark.
  Receiving bookmark updates alone never navigates to Home or dismisses NPS.
- Ordinary album Play still starts track 1. Saved-queue handoff and all other playback/navigation
  behavior remain unchanged.
- This is a bonus feature: failure must leave current playback untouched and need not present a
  blocking error.
  A failed album lookup or missing resume target does not start track 1 or delete the marker.
  The marker is omitted if its target is missing from the loaded album.

Prototype verification: click a Continue card and confirm normal album navigation, check the
marker above its saved track (including disc boundaries), and exercise Play and Append from
that boundary. Check albums without progress have no marker, and inspect the row at minimum
and wider window sizes. The same inline row can be used on Android without changing its header.

## Completion mutation path

Do not call `getBookmarks` when a track completes.

1. Resolve the completed song and reject explicit non-music media. Accept missing legacy type
   fields only when a non-empty album ID and canonical album membership validate the relationship.
2. Fetch the canonical album and locate the completed song.
3. For a non-final track, call `createBookmark` once on the first canonical song with position zero
   and the next canonical song in the protocol comment.
4. For the final track, call `deleteBookmark` once on the first canonical song.
5. After server success, adjust the local Home presentation state opportunistically. This state is
   not authoritative for housekeeping.

Serialize completion mutations and cancel/ignore work after session rotation. Do not retry by
reordering older and newer completion events.

Recording is best-effort, with in-memory serialized work only: no durable retry outbox or replay
after process death. A lost update can leave progress one or several tracks behind; a failed
initial write can leave the album absent, and a failed final deletion can leave a completed album
listed. These are accepted prototype tradeoffs. Recording consumes natural completion independently
of scrobble network success; on Android it belongs to the playback service so screen-off,
Bluetooth, notification, and Android Auto playback still record progress.

## Refresh and housekeeping lifecycle

Perform one authoritative `getBookmarks` refresh:

- after a new authenticated session connects;
- when the app becomes active after another client may have changed state;
- on explicit user refresh (⌘R on macOS or the Android equivalent).

Do not fetch bookmarks merely because Home is reconstructed or a track completes. Coalesce
overlapping lifecycle refreshes.

From each fresh response:

1. Filter, group, and sort compatible markers according to the protocol.
2. Publish the newest 20 to the Home shelf immediately.
3. Best-effort delete compatible markers beyond the newest 20 using only this fresh ordering.

Temporary server excess is normal. Do not maintain a separate full bookmark cache or use stale Home
presentation state for deletion. The in-memory Home items may temporarily diverge from another
client and are replaced by the next authoritative refresh.

## Android notes

- Decode optional OpenSubsonic `Child.type` and `Child.mediaType`. Eligible current-server values
  are `music` and `song`; reject `podcast`, `audiobook`, and `video`.
- Keep networking off the main thread and publish the final shelf state through the app's normal
  observable/state holder.
- Use the authenticated-account/session generation to reject stale refresh and mutation results.
- Trigger foreground refresh through the Android application/activity lifecycle rather than a
  periodic background poll.
- Preserve compact JSON key names exactly and enforce the 255-byte UTF-8 limit before upload.
- The server's `changed` timestamp—not device time or writer metadata—orders authoritative results.
  Follow the protocol's exact raw-string fallback/comparison rules. macOS inserts successful local
  updates at the front provisionally; only a fresh server snapshot drives housekeeping.
- Do not perform one `getAlbum` validation request per Home card. The bookmark entry already carries
  album presentation metadata. Validate the album and `resumeSongId` only when the card is clicked.

## macOS reference behavior

`AlbumResumeCoordinator` owns session refresh, completion mutation serialization, opportunistic
Home-state updates, and fresh-snapshot housekeeping. `HomeView` renders the shelf, opens album
detail, and exposes explicit refresh. Album detail owns the continuation controls and hides their
treatment for the current album. The player publishes natural completion events; views do not
infer completion from progress.

Automated tests should cover marker encoding/version rejection, music-media eligibility, canonical
next/final-track actions, newest-first filtering, foreign-marker exclusion from presentation and
housekeeping, and stale-session cancellation. Runtime smoke testing should cover fresh launch,
foregrounding after the other Coda changes progress, isolated-track completion, final-track removal,
and continuation from both platforms.

# Album Resume Bookmark protocol

Status: experimental application-level convention implemented by Coda. It is not an official
OpenSubsonic extension and deliberately avoids an `opensubsonic` namespace.

## Purpose

Represent unfinished album playback across compatible OpenSubsonic clients without a separate
account or server. Album resume is distinct from saved play-queue handoff: it identifies an album
and the canonical track where album playback should restart.

The companion [Coda implementation design](coda-album-resume-design.md) is intentionally separate.
It defines Coda's UI, playback triggers, refresh lifecycle, and Android implementation guidance;
those choices are not part of this reusable record format.

## Eligible media

This protocol is only for ordered music releases such as albums and EPs. A client must reject
entries explicitly identified as podcasts, audiobooks, or video. When supplied by the server,
OpenSubsonic `Child.type` must be `music` and `Child.mediaType` must be `song`. For older servers
that omit either optional field, a non-empty album ID plus successful canonical album lookup and
membership of the completed song in that album is the compatibility fallback.

This restriction is important because the protocol stores a track boundary, not a playback
position within long-form media.

## Storage and marker format

Use the standard OpenSubsonic endpoints `getBookmarks`, `createBookmark`, and `deleteBookmark`.
Bookmarks are scoped to the authenticated user and one media item. OpenSubsonic permits only one
bookmark per user and song, and `createBookmark` overwrites the existing bookmark for that song.

Attach the album marker to its first canonical song as a stable anchor. Store position `0`; the
actual continuation target is `resumeSongId` in the comment:

```json
{"protocol":"album-resume-bookmark","protocolVersion":1,"resumeSongId":"…","writer":{"client":"Example Client","platform":"Android","appVersion":"1.0"}}
```

Required fields:

- `protocol`: exactly `album-resume-bookmark`;
- `protocolVersion`: `1`;
- `resumeSongId`: the non-empty canonical song ID where playback should restart.

The optional `writer` object is diagnostic metadata describing the last compatible writer:

- `client` (optional): the human-readable OpenSubsonic client name;
- `platform` (optional): the client platform;
- `appVersion` (optional): the user-facing version.

Coda writers continue supplying all three diagnostic strings when space permits. Progress readers
on macOS and Android ignore the entire `writer` field, including missing, partial, or incorrectly
typed values. Diagnostic tools may inspect it independently; it must never invalidate an otherwise
valid marker. Writer metadata never affects ownership, ordering, retention, or conflict resolution. Do not add
a persistent installation identifier in v1. Parsers accept keys in any order, ignore unknown
fields, and reject malformed or unsupported versions.

Serialize compact UTF-8 JSON and keep it at or below 255 bytes. Writer metadata is optional and
must be shortened or omitted before allowing it to prevent a valid marker. Navidrome currently
round-trips longer comments, but its schema declares `varchar(255)`, so 255 bytes is the portable
limit.

The anchor's returned media entry supplies album ID, title, artist, artwork identity, and other
normal metadata. The bookmark supplies authoritative `created` and `changed` timestamps. Do not
duplicate this data in the comment. Treat a missing serialized zero position as zero.

## Progress semantics

Canonical album order is the `getAlbum` song list stably sorted ascending by disc number
(missing = 1), track number (missing sorts after supplied numbers), then locale-independent
lowercased title. Preserve server order when all three keys tie; do not introduce a song-ID
tie-breaker. Explicit zero values are not treated as missing. Use this same order for the anchor,
next-track decision, final-track detection, and resumed queue. Inconsistent server ordering of
otherwise tied songs remains a v1 limitation, not a reason to migrate existing anchors.

- One stable marker represents each unfinished album.
- Resume starts at the beginning of the canonical song named by `resumeSongId`.
- Natural completion of a non-final canonical album track upserts the first-track anchor with the
  next canonical disc/track as `resumeSongId`, even when that next track is absent from the queue.
- Completing an isolated track may therefore create album progress. Queue construction is not part
  of the protocol.
- The latest successful listening session wins; progress may move backward when an earlier track
  is completed later.
- Natural completion of the final canonical track deletes the first-track bookmark. A completed
  one-track album has no marker.
- Starting, pausing, seeking, manually skipping, restoring, or quitting during a track does not
  change the marker. Continuous position monitoring is outside this protocol.

For eligible music albums, the first canonical track is reserved as the shared album-resume
anchor. Upserting it may overwrite another music client's bookmark on that song. This is a
deliberate v1 tradeoff that removes a full `getBookmarks` ownership read from every completed
track. Podcasts, audiobooks, video, and entries without trustworthy album membership are never
eligible for this behavior.

Reservation also applies to final-track deletion: it may delete a foreign ordinary music bookmark
on the anchor, including when a one-track album finishes. No ownership read precedes this deletion.
This is distinct from housekeeping, which only deletes recognized supported protocol markers.

## Ordering and deduplication

Recognize only exact supported protocol comments when reading album-resume history. Group markers
by their required non-empty album ID. Choose the representative with the newest server `changed`
timestamp.
If timestamps tie, use descending anchor-song ID as the deterministic tie-breaker.

For compatibility with the macOS v1 reference, the effective ordering key is the raw `changed`
string when present, otherwise raw `created`, otherwise the empty string. Compare descending,
lexicographically and without locale-aware collation. An explicitly empty or malformed string is
not parsed, rejected, or replaced with device time; it retains its lexical ordering. This assumes
the server emits consistently formatted sortable timestamps. Mixed offsets or precision and
malformed values are not guaranteed to sort chronologically. Android must not silently introduce
date normalization or invalid-date fallback that changes shared housekeeping order.

The stable anchor normally guarantees one row per album; grouping remains defensive against older
experiments, missing IDs, or another implementation.

## Recent-20 retention profile

Protocol v1 has a shared server-storage target of the 20 deduplicated compatible albums with the
newest bookmark `changed` timestamps. Twenty is a target, not an invariant: temporary excess is
valid and must not block or delay progress mutation.

Housekeeping is independent of track completion:

1. During an occasional authoritative refresh, call `getBookmarks` once.
2. Filter and group recognized v1 markers.
3. Sort representatives by the shared ordering rule.
4. Publish or retain the newest 20 as needed by the client.
5. Best-effort delete compatible markers belonging to albums beyond those 20.

Never fetch the complete bookmark collection merely because a track completed. Never perform
destructive housekeeping from a stale in-memory ordering. Failed, interrupted, or racing cleanup
may leave 21, 40, or more markers until a later authoritative refresh.

OpenSubsonic provides no filtered/paginated bookmark query, batch mutation, conditional delete,
revision token, or change notification. Consequently cleanup cannot be atomic across clients. A
marker could change between the authoritative read and deletion; this small race and temporary
excess are accepted v1 limitations. Clients converge during later refreshes.

Clients may display fewer than 20 cards, but a different server-retention limit is not a private
client preference: incompatible limits would cause clients to fight. A different shared limit
requires another explicitly defined retention profile or protocol version.

## Synchronization and privacy requirements

- Serialize local mutations so a delayed older completion cannot replace newer progress.
- Apply session-generation protection; responses from a previous login must not publish UI or
  delete markers in the current session.
- Housekeeping deletes only comments recognized as this exact supported protocol/version. Foreign,
  malformed, and unknown-version bookmarks are never housekeeping candidates.
- Do not log or commit server URLs, credentials, library contents, or personal bookmark payloads.

## Confirmed Navidrome behavior

Live round-trip testing confirmed that bookmarks can be created, read, updated, and deleted;
comments round-trip unchanged; recreating a bookmark for the same song updates its row and
`changed` timestamp; position zero may be omitted; and `getBookmarks` returns the bookmarked song
with album metadata. The endpoint is unpaginated and returns full media metadata, so it must not be
used as a per-track progress request.

Changes to the required marker fields, eligibility rules, progress semantics, ordering, or
retention contract must remain backward-compatible or increment `protocolVersion`.

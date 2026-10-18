# ReplayGain playback specification

This document defines platform-independent product behaviour; playback engines,
settings storage, and UI layout may differ between implementations.

## Purpose and scope

Use existing ReplayGain metadata to reduce loudness differences between recordings while
preserving relative song levels when listening to an album sequence. Play the original audio
stream and apply gain during playback; do not modify files or request server transcoding to
implement normalization.

ReplayGain applies a fixed adjustment for a song or album. It does not flatten the differences
between quiet and loud passages within a song. Track and album gain use the same nominal
loudness reference, but album gain preserves quieter and louder songs relative to the album.
Consequently, equal loudness at every track boundary is not guaranteed.

Automatic loudness scanning, real-time normalization, compression, limiters, and writing tags
are outside this feature. In particular, do not insert a dynamic normalization filter when
metadata is missing.

## User setting

Expose one ReplayGain on/off setting:

- **Off:** apply no ReplayGain gain, preamp, or missing-tag fallback.
- **On:** automatically select album or track gain using the queue rules below.

There are no manual Track/Album modes, preamp control, or fallback control in the initial UI.
Suggested explanatory text:

> Match playback loudness using ReplayGain tags, preserving album dynamics for consecutive
> tracks from the same album.

Default to Off on fresh installs and upgrades without a saved preference. Persist the user's
explicit choice locally across launches and updates. Restoring a queue must not overwrite the
choice; the setting is not part of a shared queue or a server preference.

An explicit toggle applies to the current item and upcoming playback without restarting the
song. Turning Off must clear every adjustment owned by this feature. Ordinary user volume,
mute, and codec-required decoding behaviour remain independent of ReplayGain.

## Automatic queue policy

Resolve a mode for each queue occurrence using its immediate neighbours in the actual playback
order:

1. If either neighbour has the same trustworthy, non-empty album identity, select **album**.
2. Otherwise select **track**.

Use server album IDs scoped to the server/library that owns them. Missing or blank IDs do not
match one another. Do not infer identity from album titles, artist names, artwork, queue UI
groups, or the action that originally added an item.

This gives every member of a contiguous same-album run of two or more entries album mode,
including the first and last. A run need not contain a complete album, begin at track one, or
have consecutive track numbers. Disc boundaries do not split an album. Two same-album songs
next to one another by chance also form a run; that is an intentional heuristic tradeoff.

Examples (`A1` means a song from album A; all data here is synthetic):

| Playback order | Resolved modes |
| --- | --- |
| `A1` | track |
| `A1, A2, A3` | album, album, album |
| `A1, B1, C1` | track, track, track |
| `A1, A2, B1, C1, C2, D1` | album, album, track, album, album, track |
| `A3, A6` | album, album |
| Two entries without album IDs | track, track |

If shuffle exists, use the resulting playback order. Do not force track mode solely because a
shuffle setting is enabled. Treat queue ends as boundaries: repeat-one and repeat-queue wrapping
do not create additional neighbours or join separate album runs.

### Queue changes and playback lifecycle

Resolve the current occurrence before its first audible samples, using the queue as it exists
when playback is prepared. Freeze that occurrence's resolved mode and applied gain once it is
audible. Appending, removing, or reordering entries must not change its level halfway through
playback. Seeking or pausing/resuming the same occurrence retains its decision.

Recompute affected upcoming occurrences when the queue changes. This includes an already
prefetched next item even when its URL has not changed. A manually started or repeated new
playback occurrence resolves again against the current order. An explicit user on/off toggle
is the exception to freezing the current adjustment.

Dynamic edits can therefore leave a transition whose two songs were resolved against different
queue states. Accept this rather than changing the current song's gain automatically.

On queue restoration, resolve using the restored order before playback starts. Restoring in a
paused state must not briefly play audio or reuse a previous item's gain.

## Metadata and gain selection

Normalize metadata into optional numeric fields before selecting gain:

| Field | Meaning |
| --- | --- |
| `trackGain` | Track adjustment in dB |
| `albumGain` | Album adjustment in dB |
| `trackPeak` | Track's linear peak amplitude relative to digital full scale |
| `albumPeak` | Album's linear peak amplitude relative to digital full scale |

Gains must be finite numbers. Zero is a valid gain, not a missing value. Peaks must be finite
and strictly positive; values greater than one are valid. Missing, malformed, or invalid fields
are unavailable and must not cause playback failure.

Metadata may come from the server API or tags exposed by the playback engine. Prefer usable
server fields when both are available; embedded metadata can fill missing fields for the same
source recording. Never apply API gain and engine-managed ReplayGain on top of one another.
Only combine gain and peak information known to describe the same source audio; transcoded
sources may need separate treatment and are not a reason to apply original peaks blindly.

| Resolved mode | Selection order |
| --- | --- |
| Off | No ReplayGain adjustment |
| Track | Valid track gain; otherwise fixed missing-tag fallback |
| Album | Valid album gain; otherwise valid track gain; otherwise fixed missing-tag fallback |

Track mode does not substitute album gain when track gain is absent: that value describes a
different normalization intent. Pair album gain with album peak and track gain with track peak.
A missing peak does not invalidate an otherwise usable gain.

Album-to-track fallback is intentionally best effort. Partially tagged albums can lose relative
song-level consistency. Do not copy album gains from neighbouring entries, derive new values,
or change an entire run's mode based on missing metadata. Correct, consistent tags are required
for full album preservation.

## Missing-tag fallback

When On and the selected gain is unavailable after the selection rules above, apply a fixed
**-9 dB** adjustment. Use the same constant for every such item, including every song in an
entirely untagged album. The fallback is not added to an existing gain.

This is a conservative playback adjustment, not a loudness measurement. Quiet untagged music
may become too quiet; unusually loud music can still differ from neighbouring tagged music.
Do not promise equal loudness or complete protection against loud transitions.

For this initial specification, the fixed client fallback is authoritative. Do not consume the
optional OpenSubsonic `fallbackGain` as another policy layer or expose a user setting for it.
The API's ability to supply that field does not establish that a particular server offers a
configurable preference. This keeps behaviour consistent between implementations.

## Preamp and clipping prevention

Use **0 dB preamp**, meaning no extra offset on top of the selected gain. Positive ReplayGain
values still boost quiet recordings. For example, `trackGain = +5 dB` requests a 5 dB boost;
`trackGain = -10 dB` requests a 10 dB reduction.

Enable peak-based clipping prevention. For selected gain `G` in dB and its valid matching peak
`P`, the effective normalization gain is:

```text
effectiveGainDb = min(G, -20 * log10(P))
linearMultiplier = 10 ^ (effectiveGainDb / 20)
```

This caps gain so the reported peak will not exceed digital full scale. It can reduce a
requested boost or require attenuation. It does not compress passages dynamically. In album
mode, a consistent album gain and album peak produce the same adjustment for every song.

Without a usable matching peak, use the selected gain, but do not claim clipping prevention
is guaranteed. Fallback-only items receive -9 dB without inventing peak metadata. This feature
does not repair pre-existing clipping or guarantee against unreported peaks or later effects.

Clamp the final gain to the playback engine's supported range if necessary. This is a numerical
guard for extreme metadata, not a substitute for the peak calculation.

ReplayGain must remain independent of the user volume slider and mute. Do not change their
displayed or persisted values to represent normalization.

## Playback engine requirements

Keep the queue policy in one small shared resolver, with the playback integration owning gain
application. Apply the correct gain before the first audible samples, including direct starts,
skips, restoration, and automatic gapless advancement. Do not rely on a late track-start callback
to correct audio that has already begun at the previous gain.

Prefetch must carry the next occurrence's resolved adjustment. Changes to that adjustment must
invalidate or update stale prepared state. Late metadata must not cause an automatic mid-song
gain jump; arrange usable metadata before playback or retain the fallback for that occurrence.
Keep normalization state attached to playback occurrences rather than just URLs or song IDs.

Use engine-native ReplayGain where it implements these semantics, otherwise apply the resolved
constant gain through the engine's gain path. Preserve normal startup, seeking, and gapless
behaviour. Do not introduce a second gain application or a persistent audible first-sample jump.

For mpv specifically, `replaygain=no` alone is insufficient if `replaygain-fallback` remains
nonzero: the fallback can apply while ReplayGain logic is inactive. Off must also reset that
fallback and any separate gain owned by this feature. Verify metadata precedence, peak handling,
and per-file settings against the bundled engine rather than assuming its defaults match.

## Acceptance checks

Use synthetic metadata and local audio fixtures; do not commit private library data.

- Fresh installation and upgrade without a preference are Off. Both choices survive relaunch
  and queue restoration. Off restores unity normalization gain, with volume and mute unchanged.
- All queue examples above resolve as specified. Include multidisc albums, identical titles
  with different IDs, missing IDs, shuffle, repeat-one, and queue wrapping.
- Adding, removing, and moving neighbours does not change an audible occurrence's adjustment.
  Upcoming decisions update, including a same-URL next item whose resolved mode changes.
- Positive, negative, and zero gains work. Invalid numbers and absent fields follow fallback
  rules. Album-only, track-only, missing-peak, and partially tagged cases remain playable.
- A synthetic `+5 dB` gain with peak `0.8` is capped at approximately `+1.94 dB`; a `-10 dB`
  gain with peak `1.0` remains `-10 dB`. Consistent album gain/peak produces constant scaling.
- Entirely untagged albums receive -9 dB throughout. Tagged-to-untagged-to-tagged playback
  applies the correct adjustment from the first samples, with no double application.
- Direct starts, manual skips, seeks, paused restoration, and prefetched gapless transitions
  preserve normal playback behaviour. Explicit on/off changes update current and upcoming audio.
- Listening checks cover quiet and loud recordings, intentional quiet album songs, and gapless
  boundaries. Automated gain checks alone do not establish perceptual quality.

## References

- [ReplayGain specification](https://wiki.hydrogenaudio.org/index.php?title=Original_ReplayGain_specification)
- [OpenSubsonic ReplayGain fields](https://opensubsonic.netlify.app/docs/responses/replaygain/)
- [mpv ReplayGain options](https://mpv.io/manual/stable/#options-replaygain)

The queue heuristic, UI, fixed fallback, and preference defaults above are product policy, not
requirements imposed by those external specifications.

## Current implementation

The client reads ReplayGain from the OpenSubsonic song responses and carries it into queue
entries. It does not independently inspect embedded file tags: absent API metadata uses the
fallback even if the underlying file might contain tags. A future metadata adapter may add
embedded-tag support without changing the queue resolver.

`AlbumSequenceResolver` owns adjacency decisions outside the queue UI. Playback snapshots its
context for each occurrence and includes that context with completion events. Album-resume
eligibility consumes that snapshot, including a separate explicit continuation hint for a final
remaining singleton. That hint does not change ReplayGain's adjacency rule. Queue and playlist
grouping also use this resolver, independently of the frozen playback snapshot; see
[track-list presentation](track-list-presentation.md). Standalone row layout follows the live list; it does not change the frozen playback context.

`ReplayGainPolicy` chooses and peak-limits the constant gain, clamped to mpv's -150...150 dB
range. The bridge supplies `volume-gain` as a per-file option for both current and prepared next
items. Native mpv ReplayGain and its fallback remain disabled to avoid applying gain twice.
An explicit user toggle changes the active gain without reloading the song.

The sole UI control is Playback → ReplayGain. It defaults to Off and persists locally.

Coda → About Coda shows a live ReplayGain readout: the current song, selected gain source,
requested gain, gain sent to the engine, and whether peak-based clipping prevention reduced it.
These are resolved playback values, not an independent measurement of audio output. The readout
uses in-memory player state and adds no timer, polling, or persistent listening log. Song titles
and ReplayGain readout values are not included by Copy Diagnostics.

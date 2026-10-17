#!/usr/bin/env python3
"""Select artist-credit test albums using read-only OpenSubsonic requests."""

import argparse
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sys
import tempfile
import unicodedata
import urllib.error
import urllib.parse
import urllib.request


def normalized(value):
    return " ".join(re.findall(r"\w+", unicodedata.normalize("NFKC", value).casefold()))


def metadata(record):
    # Deliberately exclude paths, URLs, comments and unrelated server fields.
    fields = ("id", "name", "title", "album", "albumId", "artist", "artistId",
              "displayArtist", "artists", "displayAlbumArtist", "albumArtists",
              "isCompilation", "musicBrainzId", "track", "discNumber", "duration")
    result = {key: record[key] for key in fields if key in record}
    for key in ("artists", "albumArtists"):
        if key in result:
            result[key] = [{k: artist[k] for k in ("id", "name") if k in artist}
                           for artist in result[key]]
    return result


def categories(album):
    result = []
    if album.get("isCompilation") is True:
        result.append("compilation")
    if len(album.get("artists", [])) > 1:
        result.append("multiple_album_artists")
    if album.get("isCompilation") is False and len(album.get("artists", [])) == 1:
        result.append("single_artist_non_compilation_candidate")
    songs = album.get("song", [])
    if any(len(song.get("artists", [])) > 1 for song in songs):
        result.append("multiple_track_artists")
    if any(song.get("displayArtist", song.get("artist", "")) !=
           song.get("displayAlbumArtist", album.get("displayArtist", album.get("artist", "")))
           for song in songs):
        result.append("track_credit_differs_from_album")
    if len({song.get("displayArtist", song.get("artist", "")) for song in songs}) > 1:
        result.append("varying_track_credits")
    if any(song.get("displayArtist") and song.get("artist") and
           song["displayArtist"] != song["artist"] for song in songs):
        result.append("legacy_and_display_credit_differ")
    return result


def shared_tracks(albums):
    groups = {}
    for album in albums:
        for song in album.get("song", []):
            # Title matches are candidates only: covers/remasters can share titles.
            for kind, value in (("recording_mbid", song.get("musicBrainzId")),
                                ("normalized_title_candidate", normalized(song.get("title", "")))):
                if value:
                    groups.setdefault((kind, value), []).append({
                        "albumId": album["id"], "song": metadata(song)})
    return [{"match": kind, "value": value, "tracks": tracks}
            for (kind, value), tracks in groups.items()
            if len({track["albumId"] for track in tracks}) > 1]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise RuntimeError("Server redirected the request; use its final base URL.")


class Client:
    def __init__(self, server, username, password):
        parts = urllib.parse.urlsplit(server)
        if (parts.scheme not in ("http", "https") or not parts.hostname or
                parts.username or parts.password or parts.query or parts.fragment):
            raise RuntimeError("Use an HTTP(S) base URL without credentials, query or fragment.")
        self.server = server.rstrip("/")
        if self.server.endswith("/rest"):
            self.server = self.server[:-5]
        self.username, self.password = username, password
        # Do not route private LAN metadata through environment-configured proxies.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def request(self, endpoint, **params):
        assert endpoint in ("getAlbumList2", "getAlbum")
        salt = secrets.token_hex(12)
        auth = dict(u=self.username, t=hashlib.md5((self.password + salt).encode()).hexdigest(),
                    s=salt, v="1.16.1", c="CodaArtistCases", f="json")
        query = urllib.parse.urlencode(dict(auth, **params))
        request = urllib.request.Request(f"{self.server}/rest/{endpoint}?{query}")
        try:
            with self.opener.open(request, timeout=30) as response:
                data = response.read(16 * 1024 * 1024 + 1)
            if len(data) > 16 * 1024 * 1024:
                raise RuntimeError("API response exceeded the 16 MiB limit.")
            result = json.loads(data)["subsonic-response"]
        except (urllib.error.URLError, OSError, ValueError, KeyError):
            # Exception text can contain the authenticated URL or private host.
            raise RuntimeError("API request failed; check connection, TLS and login settings.") from None
        if result.get("status") != "ok":
            raise RuntimeError("Server rejected the API request (details withheld for privacy).")
        return result


def collect(client, queries, discover, max_albums):
    summaries = []
    seen = set()
    offset = 0
    while True:
        page = client.request("getAlbumList2", type="alphabeticalByName", size=500,
                              offset=offset).get("albumList2", {}).get("album", [])
        if not page:
            break
        if any(album["id"] in seen for album in page):
            raise RuntimeError("Album pagination repeated an ID; retry when the library is stable.")
        seen.update(album["id"] for album in page)
        summaries.extend(page)
        if len(summaries) > max_albums:
            raise RuntimeError("Album limit exceeded; increase --max-albums explicitly.")
        offset += len(page)

    matches = {query: [album["id"] for album in summaries
                       if normalized(query) in normalized(album.get("name", ""))]
               for query in queries}
    selected = {album_id for ids in matches.values() for album_id in ids}
    for category in ("compilation", "multiple_album_artists",
                     "single_artist_non_compilation_candidate"):
        selected.update(album["id"] for album in
                        [a for a in summaries if category in categories(a)][:discover])
    albums = [client.request("getAlbum", id=album["id"])["album"]
              for album in summaries if album["id"] in selected]
    return dict(
        scannedAlbumCount=len(summaries), requestedMatches=matches,
        scope="Track analysis and shared-recording comparison cover selected albums only.",
        albums=[dict(metadata(album), categories=categories(album),
                     songs=[metadata(song) for song in album.get("song", [])]) for album in albums],
        sharedTracks=shared_tracks(albums))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--album", action="append", default=[],
                        help="Album-title substring; repeat to select multiple albums and editions")
    parser.add_argument("--discover", type=int, default=0, metavar="N",
                        help="Also select N albums per album-level category")
    parser.add_argument("--max-albums", type=int, default=20000)
    args = parser.parse_args()
    if (not args.album and args.discover == 0) or args.discover < 0 or args.max_albums < 1:
        parser.error("Provide --album or a positive --discover; limits must be positive.")
    if any(not normalized(query) for query in args.album):
        parser.error("Album queries must contain letters or numbers.")
    server = os.environ.get("NAVIDROME_URL") or input("Navidrome base URL: ").strip()
    username = os.environ.get("NAVIDROME_USER") or input("Username: ").strip()
    password = os.environ.get("NAVIDROME_PASSWORD") or getpass.getpass("Password: ")
    if not username or not password:
        raise RuntimeError("Username and password are required.")
    report = collect(Client(server, username, password), args.album, args.discover, args.max_albums)
    directory = Path(__file__).resolve().parent.parent / ".build" / "artist-test-cases"
    directory.mkdir(parents=True, exist_ok=True)
    # Unique mode-0600 files avoid overwriting a prior selection or following a file symlink.
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", suffix=".json",
                                     prefix="selection-", dir=directory, delete=False) as output:
        json.dump(report, output, ensure_ascii=False, indent=2)
        output.write("\n")
        path = output.name
    print(f"Scanned {report['scannedAlbumCount']} albums; selected {len(report['albums'])}.")
    print(f"Private report: {path}")
    missing = sum(not ids for ids in report["requestedMatches"].values())
    print(f"Unmatched album queries: {missing}. Inspect requestedMatches for missing or ambiguous editions.")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, KeyError):
        print("Selection failed. Check inputs, server availability and response compatibility. "
              "No credentials or server error details were printed.", file=sys.stderr)
        sys.exit(1)

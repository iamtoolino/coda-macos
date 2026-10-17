"""Offline regression checks; contains synthetic metadata only."""

import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "artist_cases", Path(__file__).with_name("find-artist-test-cases.py"))
cases = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cases)


class FakeClient:
    def __init__(self, albums):
        self.albums = albums
        self.calls = []

    def request(self, endpoint, **params):
        self.calls.append((endpoint, params))
        if endpoint == "getAlbumList2":
            # Return short pages to exercise offset-based pagination.
            offset = params["offset"]
            return {"albumList2": {"album": self.albums[offset:offset + 1]}}
        return {"album": next(a for a in self.albums if a["id"] == params["id"])}


class ArtistCaseTests(unittest.TestCase):
    def test_selection_preserves_editions_missing_queries_and_read_only_requests(self):
        client = FakeClient([
            {"id": "a", "name": "Example", "song": []},
            {"id": "b", "name": "EXAMPLE (Deluxe)", "song": []},
            {"id": "c", "name": "Other", "song": []},
        ])
        report = cases.collect(client, ["example", "absent"], 0, 10)
        self.assertEqual(report["scannedAlbumCount"], 3)
        self.assertEqual(report["requestedMatches"], {"example": ["a", "b"], "absent": []})
        self.assertEqual([a["id"] for a in report["albums"]], ["a", "b"])
        self.assertEqual({call[0] for call in client.calls}, {"getAlbum", "getAlbumList2"})

    def test_compilation_and_collaboration_are_independent(self):
        album = {"isCompilation": False, "artists": [{"id": "a"}, {"id": "b"}],
                 "displayArtist": "A & B", "song": [
                     {"artist": "A feat. C", "displayArtist": "A feat. C",
                      "artists": [{"id": "a"}, {"id": "c"}]},
                     {"artist": "B"}]}
        categories = cases.categories(album)
        self.assertIn("multiple_album_artists", categories)
        self.assertIn("multiple_track_artists", categories)
        self.assertIn("track_credit_differs_from_album", categories)
        self.assertIn("varying_track_credits", categories)
        self.assertNotIn("compilation", categories)
        self.assertEqual(cases.categories({}), [])
        self.assertIn("compilation", cases.categories({"isCompilation": True}))

    def test_shared_tracks_do_not_assert_title_matches_are_same_recording(self):
        albums = [{"id": album_id, "song": [
            {"id": album_id + "1", "title": "Shared Song", "musicBrainzId": "recording"},
            {"id": album_id + "2", "title": "Other Song"}]} for album_id in ("a", "b")]
        matches = cases.shared_tracks(albums)
        self.assertEqual([m["match"] for m in matches], [
            "recording_mbid", "normalized_title_candidate", "normalized_title_candidate"])

    def test_report_whitelists_metadata(self):
        result = cases.metadata({"id": "a", "path": "private", "url": "private",
                                 "comment": "private", "artists": [
                                     {"id": "b", "name": "Example", "artistImageUrl": "private"}]})
        self.assertEqual(result, {"id": "a", "artists": [{"id": "b", "name": "Example"}]})

    def test_album_scan_limit(self):
        with self.assertRaises(RuntimeError):
            cases.collect(FakeClient([{"id": "a"}, {"id": "b"}]), ["example"], 0, 1)


if __name__ == "__main__":
    unittest.main()

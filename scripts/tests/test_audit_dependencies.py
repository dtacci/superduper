"""Regression checks for advisory coverage and fail-closed responses."""

import json
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from audit_dependencies import audit, main


class DependencyAuditTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.lockfile = Path(self.directory.name) / "Package.resolved"
        self.lockfile.write_text(json.dumps({"pins": [{
            "identity": "swift-nio", "kind": "remoteSourceControl",
            "location": "https://github.com/apple/swift-nio.git",
            "state": {"revision": "a" * 40, "version": "2.99.0"},
        }]}))

    def test_queries_both_revision_and_correct_swifturl_coordinate(self):
        requests = []

        def query(queries):
            requests.extend(queries)
            return {"results": [{}, {"vulns": [{"id": "GHSA-test"}]}]}

        result = audit(self.lockfile, query)
        self.assertEqual(requests, [
            {"commit": "a" * 40},
            {"package": {"ecosystem": "SwiftURL", "name": "github.com/apple/swift-nio"},
             "version": "2.99.0"},
        ])
        self.assertEqual(result["dependencies"][0]["advisories"], ["GHSA-test"])

    def test_collects_later_pages_and_deduplicates_matches(self):
        def query(queries):
            if "page_token" in queries[0]:
                self.assertEqual(len(queries), 1)
                return {"results": [{"vulns": [{"id": "B"}]}]}
            return {"results": [
                {"vulns": [{"id": "A"}], "next_page_token": "next"},
                {"vulns": [{"id": "A"}]},
            ]}

        result = audit(self.lockfile, query)
        self.assertEqual(result["dependencies"][0]["advisories"], ["A", "B"])

    def test_rejects_truncated_batch(self):
        with self.assertRaises(ValueError):
            audit(self.lockfile, lambda _: {"results": [{}]})

    def test_rejects_pagination_loop(self):
        with self.assertRaises(ValueError):
            audit(self.lockfile, lambda queries: {
                "results": [{"next_page_token": "same"} for _ in queries]
            })

    def test_rejects_empty_lockfile(self):
        self.lockfile.write_text('{"pins": []}')
        with self.assertRaises(ValueError):
            audit(self.lockfile, lambda _: self.fail("Must not query an empty lockfile"))

    def test_does_not_treat_api_errors_as_no_advisories(self):
        with self.assertRaises(ValueError):
            audit(self.lockfile, lambda _: {"results": [{"error": "unavailable"}, {}]})

    def test_network_failure_returns_inconclusive_exit_status(self):
        with patch("sys.argv", ["audit_dependencies"]), \
                patch("audit_dependencies.audit", side_effect=OSError("network unavailable")), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(main(), 2)


if __name__ == "__main__":
    unittest.main()

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import MagicMock, Mock, call, patch

sys.path.insert(0, str(Path(__file__).parent))
import gemma_review as review


class GemmaReviewTests(unittest.TestCase):
    def test_exclusions_and_project_file(self):
        self.assertTrue(review.is_excluded_path("Assets/icon.png")[0])
        self.assertTrue(review.is_excluded_path("Package.resolved")[0])
        self.assertFalse(review.is_excluded_path("KizunaAI.xcodeproj/project.pbxproj", 100000)[0])

    def test_chunks_never_split_a_file(self):
        files = tuple(review.ChangedFile(f"File{i}.swift", "modified", "@@ -1 +1 @@\n+let x = 1") for i in range(4))
        chunks, skipped = review.split_diff_chunks(files, 200, 1_000, 8)
        self.assertEqual(sum(len(chunk.files) for chunk in chunks), 4)
        self.assertFalse(skipped)

    def test_invalid_line_is_removed(self):
        changed = review.ChangedFile("A.swift", "modified", "@@ -1 +10 @@\n+let value = 1")
        result = review.validate_result({"severity": "critical", "findings": [{"severity": "critical", "file": "A.swift", "line": 1}]}, review.ReviewChunk((changed,), changed.patch))
        self.assertEqual(result["findings"][0]["line"], 0)

    def test_json_fence_and_invalid_json(self):
        self.assertEqual(review.extract_json("```json\n{\"severity\": \"clean\"}\n```"), {"severity": "clean"})
        with self.assertRaises(review.ReviewError):
            review.extract_json("not json")

    def test_fork_detection(self):
        event = {"pull_request": {"head": {"repo": {"full_name": "someone/fork"}}, "base": {"repo": {"full_name": "VIUK-Light/Kizuna"}}}}
        self.assertTrue(review.is_fork_pr(event, "VIUK-Light/Kizuna"))

    def test_existing_comment_is_updated_once(self):
        client = Mock()
        client.get_issue_comments.return_value = [{"id": 42, "body": review.MARKER + " old"}]
        review.upsert_review_comment(client, "VIUK-Light/Kizuna", 1, review.MARKER + " new")
        client.update_comment.assert_called_once_with("VIUK-Light/Kizuna", 42, review.MARKER + " new")
        client.create_comment.assert_not_called()

    def test_missing_secret_exits_without_network(self):
        event = {"pull_request": {"number": 1, "head": {"repo": {"full_name": "VIUK-Light/Kizuna"}}, "base": {"repo": {"full_name": "VIUK-Light/Kizuna"}}}}
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            json.dump(event, handle)
            path = handle.name
        try:
            old = {key: os.environ.pop(key, None) for key in ("GITHUB_TOKEN", "GEMINI_API_KEY")}
            self.assertEqual(review.main(["--event-path", path, "--repo", "VIUK-Light/Kizuna"]), 1)
            for key, value in old.items():
                if value is not None:
                    os.environ[key] = value
        finally:
            os.unlink(path)

    def test_gemma_retries_transient_api_errors(self):
        client = review.GeminiClient("test-key", "gemma-4-26b-a4b-it", 5)
        response = MagicMock()
        response.__enter__.return_value = response
        response.read.return_value = b'{"ok": true}'
        transient_1 = review.HTTPError("https://example.test", 503, "busy", {}, None)
        transient_2 = review.HTTPError("https://example.test", 503, "busy", {}, None)
        with patch.object(review, "urlopen", side_effect=[transient_1, transient_2, response]) as request, \
             patch.object(review.time, "sleep") as sleep:
            self.assertEqual(client._request_url("POST", "https://example.test", {}), {"ok": True})
        self.assertEqual(request.call_count, 3)
        self.assertEqual(sleep.call_args_list, [call(1), call(2)])

    def test_api_failure_fails_check_and_reports_skipped_files(self):
        event = {
            "pull_request": {
                "number": 1,
                "head": {"repo": {"full_name": "VIUK-Light/Kizuna"}},
                "base": {"repo": {"full_name": "VIUK-Light/Kizuna"}},
            }
        }
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            json.dump(event, handle)
            path = handle.name
        previous = {key: os.environ.get(key) for key in ("GITHUB_TOKEN", "GEMINI_API_KEY")}
        os.environ["GITHUB_TOKEN"] = "test-token"
        os.environ["GEMINI_API_KEY"] = "test-key"
        try:
            with patch.object(review, "GitHubClient") as github_type, \
                 patch.object(review, "GeminiClient") as gemma_type, \
                 patch.object(review, "upsert_review_comment") as publish:
                github = github_type.return_value
                github.get_pull_request.return_value = {"title": "Test", "body": ""}
                github.get_changed_files.return_value = [{
                    "filename": "Diary/A.swift",
                    "status": "modified",
                    "patch": "@@ -1 +1 @@\n+let value = 1",
                }]
                gemma_type.return_value.review.side_effect = review.ApiStatusError("Gemma", 503)
                self.assertEqual(review.main(["--event-path", path, "--repo", "VIUK-Light/Kizuna"]), 1)
                publish.assert_called_once()
                self.assertIn("APIレビュー失敗", publish.call_args.args[3])
        finally:
            os.unlink(path)
            for key, value in previous.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value


if __name__ == "__main__":
    unittest.main()

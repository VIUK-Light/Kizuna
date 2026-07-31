import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

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
            self.assertEqual(review.main(["--event-path", path, "--repo", "VIUK-Light/Kizuna"]), 0)
            for key, value in old.items():
                if value is not None:
                    os.environ[key] = value
        finally:
            os.unlink(path)

    def test_gemma_json_mode_fallback(self):
        client = review.GeminiClient("test-key", "gemma-4-26b-a4b-it", 5)
        payloads = []

        def fake_request(method, url, payload):
            payloads.append(json.loads(json.dumps(payload)))
            if len(payloads) == 1:
                raise review.ApiStatusError("Gemma", 400)
            return {"candidates": [{"content": {"parts": [{"text": '{"severity":"clean"}'}]}}]}

        client._request_url = fake_request
        self.assertEqual(client.review("review"), {"severity": "clean"})
        self.assertIn("responseMimeType", payloads[0]["generationConfig"])
        self.assertNotIn("responseMimeType", payloads[1]["generationConfig"])


if __name__ == "__main__":
    unittest.main()

import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class KizunaI18nAuditTests(unittest.TestCase):
    def test_system_story_detail_has_english_presentation_path(self) -> None:
        result = subprocess.run(
            [sys.executable, "tools/audit_kizuna_i18n.py"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        story_detail = json.loads(result.stdout)["story_detail"]

        self.assertTrue(story_detail["initial_scene_presentation_uses_stable_identity"])
        self.assertEqual(story_detail["initial_scene_titles_missing_presentation"], [])
        self.assertEqual(story_detail["initial_scenes_left_untranslated_by_current_fallback"], 0)
        self.assertEqual(story_detail["raw_japanese_spotlight_label_lines"], [])


if __name__ == "__main__":
    unittest.main()

import json
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import audit_kizuna_i18n


class KizunaI18nAuditTests(unittest.TestCase):
    def test_strict_mode_treats_raw_spotlight_labels_as_a_finding(self) -> None:
        report = {
            "xcstrings": {"missing_english_keys": []},
            "presentation": {
                "missing_execution_ui_accessors": [],
                "tool_catalog_has_localized_label": True,
                "english_brand_is_kizuna": True,
            },
            "direct_ui": {"character_create_raw_ui_lines": []},
            "story_detail": {
                "initial_scenes_left_untranslated_by_current_fallback": 0,
                "raw_japanese_spotlight_label_lines": [913],
                "story_world_localization_has_safety_rules": True,
            },
            "litert": {"runtime_uses_unchecked_sendable": False},
        }

        self.assertTrue(audit_kizuna_i18n.has_open_findings(report))
        report["story_detail"]["raw_japanese_spotlight_label_lines"] = []
        self.assertFalse(audit_kizuna_i18n.has_open_findings(report))

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

#!/usr/bin/env python3
"""Reproduce the Kizuna translation and LiteRT-LM audit from repository sources.

This tool is intentionally read-only.  It reports source-level evidence; it
does not claim that an iPhone model was executed or that a user-authored story
was translated.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
CJK = r"[^\x00-\x7F]"


def read_text(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def line_numbers(relative_path: str, pattern: str) -> list[int]:
    return [
        line_number
        for line_number, line in enumerate(read_text(relative_path).splitlines(), start=1)
        if re.search(pattern, line)
    ]


def xcstring_audit() -> dict[str, Any]:
    catalog = json.loads(read_text("KizunaAI/Localizable.xcstrings"))
    entries = [
        (key, value)
        for key, value in catalog["strings"].items()
        if key
    ]
    missing_english = [
        key
        for key, value in entries
        if not (value.get("localizations", {}).get("en", {}).get("stringUnit", {}).get("value"))
    ]
    return {
        "nonempty_key_count": len(entries),
        "missing_english_keys": sorted(missing_english),
    }


def seed_stories() -> list[dict[str, Any]]:
    stories: list[dict[str, Any]] = []
    for name in ("SeedStoryPacks.json", "SeedStoryPacksExpansion.json"):
        payload = json.loads(read_text(f"KizunaAI/AI/CharacterLibrary/SeedData/{name}"))
        stories.extend(payload["stories"])
    return stories


def story_audit() -> dict[str, Any]:
    stories = seed_stories()
    localization_source = read_text("KizunaAI/AI/CharacterLibrary/Story/Models/StoryLocalization.swift")
    detail_source = read_text("KizunaAI/AI/CharacterLibrary/Story/Views/StoryWorldDetailView.swift")

    title_section, detailed_section = localization_source.split("private static let detailed", maxsplit=1)
    catalog_titles = set(re.findall(r'^\s*"([^"]+)":', title_section, flags=re.MULTILINE))
    detailed_titles = set(
        re.findall(r'^\s*"([^"]+)":\s*StoryWorldLocalization', detailed_section, flags=re.MULTILINE)
    )

    unchanged_initial_scenes = 0
    for item in stories:
        scene = item["initialScene"]
        world = item["story"]
        summary = scene.get("summary", "").strip()
        opening = world.get("openingScene", "").strip()
        # Keep this condition aligned with StoryWorldDetailView.displayedScene.
        if summary != opening and summary:
            unchanged_initial_scenes += 1

    characters = [character for item in stories for character in item["characters"]]
    direct_spotlight_labels = line_numbers(
        "KizunaAI/AI/CharacterLibrary/Story/Views/StoryWorldDetailView.swift",
        rf'info\("{CJK}',
    )
    return {
        "seed_story_count": len(stories),
        "seed_titles_missing_catalog_entry": sorted(
            item["story"]["title"] for item in stories if item["story"]["title"] not in catalog_titles
        ),
        "seed_titles_without_detailed_translation": len(
            [item for item in stories if item["story"]["title"] not in detailed_titles]
        ),
        "initial_scenes_left_untranslated_by_current_fallback": unchanged_initial_scenes,
        "seed_character_count": len(characters),
        "seed_characters_with_story_relationship_text": sum(
            bool(character.get("storyRelationshipToUser", "").strip()) for character in characters
        ),
        "story_world_localization_has_safety_rules": bool(
            re.search(r"^\s*var safetyRules:\s*\[String\]", localization_source, flags=re.MULTILINE)
        ),
        "raw_japanese_spotlight_label_lines": direct_spotlight_labels,
        "detail_view_uses_displayed_world_safety_rules": bool(
            "displayedWorld.safetyRules" in detail_source
        ),
    }


def direct_ui_audit() -> dict[str, Any]:
    return {
        "character_create_raw_ui_lines": line_numbers(
            "KizunaAI/AI/CharacterLibrary/Views/CharacterCreateView.swift",
            rf'(\.alert|Button|labeledField)\("{CJK}',
        ),
        "character_safety_reason_lines": line_numbers(
            "KizunaAI/AI/CharacterLibrary/Safety/MockSafetyCheckers.swift",
            rf'reasons\.append\("{CJK}',
        ),
        "character_save_failure_reason_lines": line_numbers(
            "KizunaAI/AI/CharacterLibrary/ViewModels/CharacterCreateViewModel.swift",
            rf'reasons:\s*\["{CJK}',
        ),
    }


def litert_audit() -> dict[str, Any]:
    runtime_path = "KizunaAI/AI/LocalAssistantLiteRTLMRuntime.swift"
    runtime_source = read_text(runtime_path)
    conversation_source = read_text("ThirdParty/LiteRT-LM/swift/Conversation.swift")
    return {
        "runtime_context_token_limit": re.search(
            r"contextTokenLimit\s*=\s*([\d_]+)", runtime_source
        ).group(1),
        "runtime_maximum_output_tokens": re.search(
            r"maximumOutputTokens\s*=\s*([\d_]+)", runtime_source
        ).group(1),
        "runtime_uses_unchecked_sendable": "@unchecked Sendable" in runtime_source,
        "sdk_conversation_is_a_non_sendable_class": bool(
            re.search(r"public class Conversation", conversation_source)
        ),
        "sdk_send_message_calls_blocking_native_api": "litert_lm_conversation_send_message(" in conversation_source,
        "budget_returns_candidate_after_final_overage": bool(
            re.search(
                r"token budget probe reached final input=.*?\n\s*return candidate",
                runtime_source,
                flags=re.DOTALL,
            )
        ),
        "manual_probe_uses_role_text": "pieces.append(\"system\\n\" + systemPrompt)" in runtime_source,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit non-zero when source-level untranslated paths remain",
    )
    args = parser.parse_args()

    report = {
        "scope": "source-only; no device model execution",
        "xcstrings": xcstring_audit(),
        "direct_ui": direct_ui_audit(),
        "story_detail": story_audit(),
        "litert": litert_audit(),
    }
    print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))

    if args.strict:
        has_open_findings = any(
            (
                report["xcstrings"]["missing_english_keys"],
                report["direct_ui"]["character_create_raw_ui_lines"],
                report["story_detail"]["initial_scenes_left_untranslated_by_current_fallback"],
                not report["story_detail"]["story_world_localization_has_safety_rules"],
                report["litert"]["runtime_uses_unchecked_sendable"],
            )
        )
        return 1 if has_open_findings else 0
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

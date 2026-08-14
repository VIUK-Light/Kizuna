import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from story_initiative_eval import (  # noqa: E402
    EXPECTED_IORI_MODEL_IDENTITY,
    EXPECTED_IORI_MODEL_SHA256,
    EvaluationError,
    create_blind_artifacts,
    load_scenario_fixture,
    main,
    score_evaluation,
    validate_generation_records,
)


def make_generation(condition, *, language="ja", model="iori", scenario_id="story-01", seed=1):
    pair_id = f"{language}-{model}-{scenario_id}-{seed}"
    return {
        "schema_version": 1,
        "record_type": "generation",
        "pair_id": pair_id,
        "language": language,
        "model": model,
        "scenario_id": scenario_id,
        "scenario_version": "story-initiative-fixture-v2",
        "fixture_sha256": "a" * 64,
        "prompt_sha256": "b" * 64 if condition == "baseline" else "c" * 64,
        "pair_input_sha256": "d" * 64,
        "seed": {"requested": seed, "effective": seed, "mode": "sampler"},
        "condition": condition,
        "status": "completed",
        "response_text": f"{condition} response",
        "state_update": None,
        "context": {
            "user_message": "The lantern flickers beside the old map.",
            "scene": {"location": "station", "mood": "quiet"},
        },
        "canary": {
            "initiative_enabled": condition == "initiative",
            "activation_source": "none" if condition == "baseline" else "launch_argument",
        },
        "latency_ms": {
            "model": 90 if condition == "baseline" else 95,
            "turn_end_to_end": 100 if condition == "baseline" else 105,
        },
        "runtime": {
            "provider": "local-story-runtime",
            "backend": "test-runtime",
            "model_identity": EXPECTED_IORI_MODEL_IDENTITY,
            "model_identity_observed": True,
            "prompt_observed": True,
            "model_sha256": EXPECTED_IORI_MODEL_SHA256,
        },
    }


def make_matrix():
    return [
        make_generation(condition, scenario_id=scenario_id, seed=seed)
        for scenario_id in ("story-01", "story-02")
        for seed in (1, 2)
        for condition in ("baseline", "initiative")
    ]


def make_assessment():
    return {
        "user_agency_violation": False,
        "safety_hard_violation": False,
        "irrelevant_event": False,
        "continuity_error": False,
    }


class StoryInitiativeEvaluationTests(unittest.TestCase):
    matrix_kwargs = {
        "languages": ("ja",),
        "models": ("iori",),
        "scenario_ids": ("story-01", "story-02"),
        "seeds": (1, 2),
    }

    def test_validation_requires_both_arms_and_matching_input_hash(self):
        records = make_matrix()
        validated = validate_generation_records(records, **self.matrix_kwargs)
        self.assertEqual(len(validated), 8)

        with self.assertRaisesRegex(EvaluationError, "missing generation"):
            validate_generation_records(make_matrix()[:-1], **self.matrix_kwargs)

        mismatched_records = make_matrix()
        mismatched_records[-1] = dict(mismatched_records[-1], pair_input_sha256="b" * 64)
        with self.assertRaisesRegex(EvaluationError, "inputs differ"):
            validate_generation_records(mismatched_records, **self.matrix_kwargs)

    def test_runtime_metadata_is_required_and_well_formed(self):
        cases = (
            (
                "non-dict runtime",
                lambda record: dict(record, runtime=[]),
                "runtime must contain app-path identity metadata",
            ),
            (
                "empty provider",
                lambda record: dict(
                    record,
                    runtime=dict(record["runtime"], provider=""),
                ),
                "runtime.provider must be a non-empty string",
            ),
            (
                "empty backend",
                lambda record: dict(
                    record,
                    runtime=dict(record["runtime"], backend=""),
                ),
                "runtime.backend must be a non-empty string",
            ),
            (
                "empty model identity",
                lambda record: dict(
                    record,
                    runtime=dict(record["runtime"], model_identity=""),
                ),
                "runtime.model_identity must be a non-empty string",
            ),
            (
                "model identity not observed",
                lambda record: dict(
                    record,
                    runtime=dict(record["runtime"], model_identity_observed=False),
                ),
                "identify the model",
            ),
            (
                "prompt not observed",
                lambda record: dict(
                    record,
                    runtime=dict(record["runtime"], prompt_observed=False),
                ),
                "observe the app prompt",
            ),
            (
                "invalid model sha256",
                lambda record: dict(
                    record,
                    runtime=dict(record["runtime"], model_sha256="not-a-sha"),
                ),
                "runtime.model_sha256 must be a SHA-256 hex digest",
            ),
            (
                "nested model identity path",
                lambda record: dict(
                    record,
                    runtime=dict(
                        record["runtime"],
                        model_identity="/private/tmp/kizuna-test-model.gguf",
                    ),
                ),
                "must not contain an absolute or nested path",
            ),
            (
                "untrusted iori model identity",
                lambda record: dict(
                    record,
                    runtime=dict(record["runtime"], model_identity="generic-gemma.gguf"),
                ),
                "trusted VIUK Story artifact",
            ),
            (
                "missing trusted iori sha256",
                lambda record: dict(
                    record,
                    runtime=dict(record["runtime"], model_sha256=None),
                ),
                "trusted model SHA-256",
            ),
        )

        for name, mutate, message in cases:
            with self.subTest(name=name):
                records = make_matrix()
                records[0] = mutate(records[0])
                with self.assertRaisesRegex(EvaluationError, message):
                    validate_generation_records(records, **self.matrix_kwargs)

    def test_scenario_fixture_is_complete_and_versioned(self):
        fixture, digest = load_scenario_fixture()

        self.assertEqual(fixture["fixture_version"], "story-initiative-fixture-v2")
        self.assertEqual(len(fixture["scenarios"]), 16)
        self.assertEqual(len(digest), 64)
        self.assertEqual(
            {scenario["scenario_id"] for scenario in fixture["scenarios"]},
            {f"story-{index:02d}" for index in range(1, 17)},
        )
        self.assertTrue(
            any(
                scenario["oracle"]["safety_class"] != "ordinary"
                for scenario in fixture["scenarios"]
            )
        )

    def test_blind_artifact_does_not_expose_condition_or_latency(self):
        blind, key = create_blind_artifacts(make_matrix(), **self.matrix_kwargs)

        self.assertEqual(len(blind), 4)
        self.assertEqual(len(key), 4)
        for pair, answer in zip(blind, key, strict=True):
            self.assertNotIn("condition", pair)
            self.assertNotIn("pair_input_sha256", pair)
            self.assertNotIn("latency_ms", pair)
            self.assertNotIn("model", pair)
            self.assertNotIn("scenario_id", pair)
            self.assertNotIn("seed", pair)
            self.assertNotIn("pair_id", pair)
            self.assertNotIn("presentation_salt", pair)
            for hidden in (
                "condition",
                "model",
                "scenario_id",
                "seed",
                "pair_id",
                "prompt_sha256",
                "presentation_salt",
            ):
                self.assertNotIn(hidden, pair["context"])
            self.assertTrue(pair["blind_id"])
            self.assertRegex(answer["presentation_salt"], r"^[0-9a-f]{32}$")
            self.assertEqual(
                {answer["a_condition"], answer["b_condition"]},
                {"baseline", "initiative"},
            )

        self.assertEqual(
            sum(answer["a_condition"] == "initiative" for answer in key),
            2,
        )

    def test_same_presentation_salt_reproduces_blind_mapping(self):
        first_blind, first_key = create_blind_artifacts(
            make_matrix(),
            presentation_salt="a" * 32,
            **self.matrix_kwargs,
        )
        second_blind, second_key = create_blind_artifacts(
            make_matrix(),
            presentation_salt="a" * 32,
            **self.matrix_kwargs,
        )

        self.assertEqual(first_blind, second_blind)
        self.assertEqual(first_key, second_key)

    def test_cli_rejects_same_blind_and_key_path(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "same.jsonl"
            self.assertEqual(
                main(
                    [
                        "generate-blind",
                        "--input",
                        str(Path(directory) / "missing.jsonl"),
                        "--blind-output",
                        str(output),
                        "--key-output",
                        str(output),
                    ]
                ),
                1,
            )

    def test_blind_artifact_rejects_incomplete_output(self):
        records = make_matrix()
        records[0] = dict(records[0], status="timeout", response_text="")

        with self.assertRaisesRegex(EvaluationError, "incomplete outputs"):
            create_blind_artifacts(records, **self.matrix_kwargs)

    def test_score_maps_blind_preference_and_reports_release_gates(self):
        generations = make_matrix()
        _, key = create_blind_artifacts(generations, **self.matrix_kwargs)
        ratings = []
        for answer in key:
            preferred_side = "a" if answer["a_condition"] == "initiative" else "b"
            ratings.append(
                {
                    "schema_version": 1,
                    "record_type": "rating",
                    "blind_id": answer["blind_id"],
                    "preference": preferred_side,
                    "assessment": {"a": make_assessment(), "b": make_assessment()},
                }
            )

        report = score_evaluation(
            generations,
            key,
            ratings,
            minimum_rated_pairs=1,
            **self.matrix_kwargs,
        )

        self.assertEqual(report["preference"]["initiative_wins"], 4)
        self.assertEqual(report["preference"]["baseline_wins"], 0)
        self.assertEqual(report["preference"]["rated_pairs"], 4)
        self.assertEqual(report["preference"]["decisive_pairs"], 4)
        self.assertEqual(report["preference"]["initiative_preference_share"], 1.0)
        self.assertEqual(report["violations"]["counts"]["initiative"]["safety_hard_violation"], 0)
        self.assertEqual(report["latency_ms"]["p95"]["baseline"], 100.0)
        self.assertEqual(report["latency_ms"]["p95"]["initiative"], 105.0)
        self.assertTrue(report["go"])

    def test_ties_count_as_rated_and_half_preference(self):
        generations = make_matrix()
        _, key = create_blind_artifacts(generations, **self.matrix_kwargs)
        ratings = [
            {
                "schema_version": 1,
                "record_type": "rating",
                "blind_id": answer["blind_id"],
                "preference": "tie",
                "assessment": {"a": make_assessment(), "b": make_assessment()},
            }
            for answer in key
        ]

        report = score_evaluation(
            generations,
            key,
            ratings,
            minimum_rated_pairs=1,
            **self.matrix_kwargs,
        )

        self.assertEqual(report["preference"]["ties"], 4)
        self.assertEqual(report["preference"]["rated_pairs"], 4)
        self.assertEqual(report["preference"]["decisive_pairs"], 0)
        self.assertEqual(report["preference"]["initiative_preference_share"], 0.5)
        self.assertEqual(report["preference"]["bootstrap_95_ci"]["seed"], 20260814)

    def test_invalid_ratings_fail_the_go_gate(self):
        generations = make_matrix()
        _, key = create_blind_artifacts(generations, **self.matrix_kwargs)
        ratings = [
            {
                "schema_version": 1,
                "record_type": "rating",
                "blind_id": answer["blind_id"],
                "preference": "invalid",
                "assessment": {"a": make_assessment(), "b": make_assessment()},
            }
            for answer in key
        ]

        report = score_evaluation(
            generations,
            key,
            ratings,
            minimum_rated_pairs=0,
            **self.matrix_kwargs,
        )

        self.assertEqual(report["preference"]["invalid"], 4)
        self.assertFalse(report["go"])
        self.assertFalse(report["gates"]["no_invalid_ratings"]["passed"])

    def test_baseline_only_agency_and_safety_flags_do_not_fail_initiative_gates(self):
        generations = make_matrix()
        _, key = create_blind_artifacts(generations, **self.matrix_kwargs)
        ratings = []
        for answer in key:
            assessment = {"a": make_assessment(), "b": make_assessment()}
            for side in ("a", "b"):
                if answer[f"{side}_condition"] == "baseline":
                    assessment[side]["user_agency_violation"] = True
                    assessment[side]["safety_hard_violation"] = True
            preferred_side = "a" if answer["a_condition"] == "initiative" else "b"
            ratings.append(
                {
                    "schema_version": 1,
                    "record_type": "rating",
                    "blind_id": answer["blind_id"],
                    "preference": preferred_side,
                    "assessment": assessment,
                }
            )

        report = score_evaluation(
            generations,
            key,
            ratings,
            minimum_rated_pairs=1,
            **self.matrix_kwargs,
        )

        self.assertTrue(report["gates"]["no_user_agency_violation"]["passed"])
        self.assertTrue(report["gates"]["no_safety_hard_violation"]["passed"])
        self.assertGreater(report["violations"]["counts"]["baseline"]["safety_hard_violation"], 0)


if __name__ == "__main__":
    unittest.main()

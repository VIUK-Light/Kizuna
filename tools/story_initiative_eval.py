#!/usr/bin/env python3
"""Validate and score the reproducible Story initiative evaluation protocol.

This tool never calls an LLM and never changes Kizuna data.  A local runner
records one generation for each condition, this tool creates a blinded A/B
pair, and a human rater records the preference and policy violations.  The
default matrix is:

    2 languages x 2 models x 16 scenarios x 3 seeds
    = 192 paired turns = 384 model outputs

The input/output contract is documented in
docs/experiments/story-initiative-evaluation.md.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import re
import secrets
import sys
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_VERSION = 1
DEFAULT_LANGUAGES = ("ja", "en")
DEFAULT_MODELS = ("iori", "nagi")
DEFAULT_SCENARIOS = tuple(f"story-{index:02d}" for index in range(1, 17))
DEFAULT_SEEDS = (1, 2, 3)
CONDITIONS = ("baseline", "initiative")
RATING_CHOICES = ("a", "b", "tie", "invalid")
GENERATION_STATUSES = ("completed", "timeout", "error", "empty", "blocked", "cancelled")
SEED_MODES = ("sampler", "draw")
ACTIVATION_SOURCES = ("none", "launch_argument", "userdefaults", "compile_condition")
CHANGE_GROUPS = ("environment", "relationship", "character", "inventory", "objective")
VIOLATION_KEYS = (
    "user_agency_violation",
    "safety_hard_violation",
    "irrelevant_event",
    "continuity_error",
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
PRESENTATION_SALT_PATTERN = re.compile(r"^[0-9a-f]{32}$")
BOOTSTRAP_RESAMPLES = 10_000
BOOTSTRAP_SEED = 20260814


class EvaluationError(ValueError):
    """Raised when an evaluation artifact violates the versioned contract."""


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(),
        start=1,
    ):
        if not raw_line.strip():
            continue
        try:
            value = json.loads(raw_line)
        except json.JSONDecodeError as error:
            raise EvaluationError(f"{path}:{line_number}: invalid JSON: {error}") from error
        if not isinstance(value, dict):
            raise EvaluationError(f"{path}:{line_number}: each record must be a JSON object")
        records.append(value)
    return records


def write_jsonl(path: Path, records: Iterable[Mapping[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True))
            handle.write("\n")


def canonical_json_bytes(value: Any) -> bytes:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")


def canonical_sha256(value: Any) -> str:
    return hashlib.sha256(canonical_json_bytes(value)).hexdigest()


def load_scenario_fixture(path: Path = ROOT / "tools" / "story_initiative_scenarios.json") -> tuple[
    dict[str, Any],
    str,
]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise EvaluationError(f"cannot read scenario fixture {path}: {error}") from error
    if not isinstance(payload, dict) or payload.get("schema_version") != SCHEMA_VERSION:
        raise EvaluationError("scenario fixture schema_version must be 1")
    fixture_version = payload.get("fixture_version")
    if not isinstance(fixture_version, str) or not fixture_version.strip():
        raise EvaluationError("scenario fixture requires a non-empty fixture_version")
    scenarios = payload.get("scenarios")
    if not isinstance(scenarios, list) or len(scenarios) != len(DEFAULT_SCENARIOS):
        raise EvaluationError("scenario fixture must contain exactly 16 scenarios")

    scenario_ids: set[str] = set()
    for scenario in scenarios:
        if not isinstance(scenario, dict):
            raise EvaluationError("each scenario fixture entry must be an object")
        scenario_id = scenario.get("scenario_id")
        if (
            not isinstance(scenario_id, str)
            or scenario_id not in DEFAULT_SCENARIOS
            or scenario_id in scenario_ids
        ):
            raise EvaluationError(f"invalid or duplicate scenario_id {scenario_id!r}")
        scenario_ids.add(scenario_id)
        if scenario.get("scenario_version") != fixture_version:
            raise EvaluationError(f"{scenario_id}: scenario_version does not match fixture_version")
        for language in DEFAULT_LANGUAGES:
            localized = scenario.get(language)
            if not isinstance(localized, dict):
                raise EvaluationError(f"{scenario_id}: missing {language} scenario data")
            user_message = localized.get("user_message")
            if not isinstance(user_message, str) or not user_message.strip():
                raise EvaluationError(
                    f"{scenario_id}/{language}: user_message must be a non-empty string"
                )
            for key in ("scene", "story_state", "character"):
                if not isinstance(localized.get(key), dict):
                    raise EvaluationError(
                        f"{scenario_id}/{language}: {key} must be an object"
                    )
            if not isinstance(localized.get("history"), list):
                raise EvaluationError(f"{scenario_id}/{language}: history must be an array")
            if not isinstance(localized.get("hard_facts"), list):
                raise EvaluationError(f"{scenario_id}/{language}: hard_facts must be an array")
        oracle = scenario.get("oracle")
        if not isinstance(oracle, dict):
            raise EvaluationError(f"{scenario_id}: missing oracle")
        if oracle.get("initiative") not in ("allow", "forbid"):
            raise EvaluationError(f"{scenario_id}: oracle.initiative must be allow or forbid")
        allowed_groups = oracle.get("allowed_change_groups")
        if not isinstance(allowed_groups, list) or not all(
            isinstance(group, str) and group in CHANGE_GROUPS for group in allowed_groups
        ):
            raise EvaluationError(f"{scenario_id}: oracle.allowed_change_groups must be an array")
        if len(set(allowed_groups)) != len(allowed_groups):
            raise EvaluationError(f"{scenario_id}: oracle.allowed_change_groups must be unique")
        safety_class = oracle.get("safety_class")
        if not isinstance(safety_class, str) or not safety_class.strip():
            raise EvaluationError(f"{scenario_id}: oracle.safety_class is required")

    if scenario_ids != set(DEFAULT_SCENARIOS):
        raise EvaluationError("scenario fixture must contain story-01 through story-16")
    return payload, canonical_sha256(payload)


def _pair_id(language: str, model: str, scenario_id: str, seed: int) -> str:
    return f"{language}-{model}-{scenario_id}-{seed}"


def _slot(record: Mapping[str, Any]) -> tuple[str, str, str, int]:
    try:
        seed = record["seed"]
        if not isinstance(seed, dict):
            raise EvaluationError("seed must be an object")
        requested_seed = seed["requested"]
        if isinstance(requested_seed, bool):
            raise EvaluationError("seed.requested must be an integer")
        return (
            str(record["language"]),
            str(record["model"]),
            str(record["scenario_id"]),
            int(requested_seed),
        )
    except EvaluationError:
        raise
    except (KeyError, TypeError, ValueError) as error:
        raise EvaluationError("generation record is missing a valid matrix key") from error


def _expected_slots(
    *,
    languages: Sequence[str],
    models: Sequence[str],
    scenario_ids: Sequence[str],
    seeds: Sequence[int],
) -> set[tuple[str, str, str, int]]:
    return {
        (language, model, scenario_id, int(seed))
        for language in languages
        for model in models
        for scenario_id in scenario_ids
        for seed in seeds
    }


def _require_string(record: Mapping[str, Any], key: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value.strip():
        raise EvaluationError(f"generation record field {key!r} must be a non-empty string")
    return value


def _status_counts(records: Sequence[Mapping[str, Any]]) -> dict[str, int]:
    counts = {status: 0 for status in GENERATION_STATUSES}
    for record in records:
        counts[str(record["status"])] += 1
    return counts


def _validate_latency(record: Mapping[str, Any]) -> float:
    value = record.get("latency_ms")
    if not isinstance(value, dict):
        raise EvaluationError("latency_ms must contain model and turn_end_to_end")
    turn_end_to_end = value.get("turn_end_to_end")
    if isinstance(turn_end_to_end, bool) or not isinstance(turn_end_to_end, (int, float)):
        raise EvaluationError("latency_ms.turn_end_to_end must be a number")
    latency = float(turn_end_to_end)
    if not math.isfinite(latency) or latency < 0:
        raise EvaluationError("latency_ms.turn_end_to_end must be finite and non-negative")
    model_latency = value.get("model")
    if model_latency is not None:
        if isinstance(model_latency, bool) or not isinstance(model_latency, (int, float)):
            raise EvaluationError("latency_ms.model must be a number when present")
        if not math.isfinite(float(model_latency)) or float(model_latency) < 0:
            raise EvaluationError("latency_ms.model must be finite and non-negative")
    return latency


def validate_generation_records(
    records: Sequence[Mapping[str, Any]],
    *,
    languages: Sequence[str] = DEFAULT_LANGUAGES,
    models: Sequence[str] = DEFAULT_MODELS,
    scenario_ids: Sequence[str] = DEFAULT_SCENARIOS,
    seeds: Sequence[int] = DEFAULT_SEEDS,
    expected_fixture_sha256: str | None = None,
    expected_scenario_version: str | None = None,
) -> list[dict[str, Any]]:
    """Validate the complete paired generation matrix and return sorted copies."""
    if not records:
        raise EvaluationError("generation input is empty")

    expected = _expected_slots(
        languages=languages,
        models=models,
        scenario_ids=scenario_ids,
        seeds=seeds,
    )
    seen: dict[tuple[str, str, str, int, str], dict[str, Any]] = {}
    errors: list[str] = []

    for index, original in enumerate(records, start=1):
        record = dict(original)
        try:
            if record.get("schema_version") != SCHEMA_VERSION:
                raise EvaluationError("schema_version must be 1")
            if record.get("record_type") != "generation":
                raise EvaluationError("record_type must be generation")
            language, model, scenario_id, seed = _slot(record)
            if language not in languages:
                raise EvaluationError(f"unsupported language {language!r}")
            if model not in models:
                raise EvaluationError(f"unsupported model {model!r}")
            if scenario_id not in scenario_ids:
                raise EvaluationError(f"unsupported scenario_id {scenario_id!r}")
            if seed not in {int(value) for value in seeds}:
                raise EvaluationError(f"unsupported seed {seed!r}")
            expected_pair_id = _pair_id(language, model, scenario_id, seed)
            if record.get("pair_id") != expected_pair_id:
                raise EvaluationError(
                    f"pair_id must be {expected_pair_id!r} for this matrix key"
                )
            condition = record.get("condition")
            if condition not in CONDITIONS:
                raise EvaluationError("condition must be baseline or initiative")
            scenario_version = _require_string(record, "scenario_version")
            if expected_scenario_version is not None and scenario_version != expected_scenario_version:
                raise EvaluationError("scenario_version does not match the selected fixture")
            fixture_sha256 = _require_string(record, "fixture_sha256").lower()
            if not SHA256_PATTERN.fullmatch(fixture_sha256):
                raise EvaluationError("fixture_sha256 must be a lowercase SHA-256 hex digest")
            if expected_fixture_sha256 is not None and fixture_sha256 != expected_fixture_sha256:
                raise EvaluationError("fixture_sha256 does not match the selected fixture")
            prompt_sha256 = _require_string(record, "prompt_sha256").lower()
            if not SHA256_PATTERN.fullmatch(prompt_sha256):
                raise EvaluationError("prompt_sha256 must be a lowercase SHA-256 hex digest")
            pair_input_sha256 = _require_string(record, "pair_input_sha256").lower()
            if not SHA256_PATTERN.fullmatch(pair_input_sha256):
                raise EvaluationError(
                    "pair_input_sha256 must be a lowercase SHA-256 hex digest"
                )
            seed_payload = record.get("seed")
            if not isinstance(seed_payload, dict):
                raise EvaluationError("seed must be an object")
            requested_seed = seed_payload.get("requested")
            effective_seed = seed_payload.get("effective")
            seed_mode = seed_payload.get("mode")
            if (
                isinstance(requested_seed, bool)
                or not isinstance(requested_seed, int)
                or requested_seed != seed
            ):
                raise EvaluationError("seed.requested must equal the matrix seed")
            if isinstance(effective_seed, bool) or not isinstance(effective_seed, int):
                raise EvaluationError("seed.effective must be an integer")
            if seed_mode not in SEED_MODES:
                raise EvaluationError("seed.mode must be sampler or draw")
            status = record.get("status")
            if status not in GENERATION_STATUSES:
                raise EvaluationError(f"status must be one of {GENERATION_STATUSES}")
            response_text = record.get("response_text", "")
            if not isinstance(response_text, str):
                raise EvaluationError("response_text must be a string")
            if status == "completed" and not response_text.strip():
                raise EvaluationError("completed output must have non-empty response_text")
            if status != "completed" and record.get("state_update") is not None:
                raise EvaluationError("failed output cannot contain state_update")
            context = record.get("context")
            if not isinstance(context, dict) or not context:
                raise EvaluationError("context must be a non-empty object")
            canary = record.get("canary")
            if not isinstance(canary, dict) or not isinstance(
                canary.get("initiative_enabled"), bool
            ):
                raise EvaluationError("canary.initiative_enabled must be boolean")
            if canary["initiative_enabled"] != (condition == "initiative"):
                raise EvaluationError("canary state does not match condition")
            activation_source = canary.get("activation_source")
            if activation_source not in ACTIVATION_SOURCES:
                raise EvaluationError("canary.activation_source is invalid")
            if condition == "baseline" and activation_source != "none":
                raise EvaluationError("baseline activation_source must be none")
            if condition == "initiative" and activation_source == "none":
                raise EvaluationError("initiative requires an activation source")
            runtime = record.get("runtime")
            if not isinstance(runtime, dict):
                raise EvaluationError("runtime must contain app-path identity metadata")
            for runtime_key in ("provider", "backend", "model_identity"):
                runtime_value = runtime.get(runtime_key)
                if not isinstance(runtime_value, str) or not runtime_value.strip():
                    raise EvaluationError(
                        f"runtime.{runtime_key} must be a non-empty string"
                    )
            model_identity_observed = runtime.get("model_identity_observed")
            if not isinstance(model_identity_observed, bool):
                raise EvaluationError("runtime.model_identity_observed must be boolean")
            prompt_observed = runtime.get("prompt_observed")
            if not isinstance(prompt_observed, bool):
                raise EvaluationError("runtime.prompt_observed must be boolean")
            if status == "completed" and not model_identity_observed:
                raise EvaluationError(
                    "completed output must identify the model actually used by the app path"
                )
            if status == "completed" and not prompt_observed:
                raise EvaluationError("completed output must observe the app prompt")
            model_sha256 = runtime.get("model_sha256")
            if model_sha256 is not None:
                if not isinstance(model_sha256, str) or not SHA256_PATTERN.fullmatch(
                    model_sha256.lower()
                ):
                    raise EvaluationError("runtime.model_sha256 must be a SHA-256 hex digest")
            latency = _validate_latency(record)
            state_update = record.get("state_update")
            if state_update is not None and not isinstance(state_update, dict):
                raise EvaluationError("state_update must be an object or null")
            key = (language, model, scenario_id, seed, condition)
            if key in seen:
                raise EvaluationError(f"duplicate generation record for {key!r}")
            record["scenario_version"] = scenario_version
            record["fixture_sha256"] = fixture_sha256
            record["prompt_sha256"] = prompt_sha256
            record["pair_input_sha256"] = pair_input_sha256
            record["seed"] = dict(seed_payload)
            record["_turn_end_to_end_ms"] = latency
            seen[key] = record
        except EvaluationError as error:
            errors.append(f"record {index}: {error}")

    for slot in sorted(expected):
        for condition in CONDITIONS:
            if (*slot, condition) not in seen:
                errors.append(f"missing generation record for {(*slot, condition)!r}")

    for slot in sorted(expected):
        pair_records = [
            seen[(*slot, condition)]
            for condition in CONDITIONS
            if (*slot, condition) in seen
        ]
        hashes = {record["pair_input_sha256"] for record in pair_records}
        if len(hashes) > 1:
            errors.append(f"baseline and initiative inputs differ for {slot!r}")
        fixture_hashes = {record["fixture_sha256"] for record in pair_records}
        if len(fixture_hashes) > 1:
            errors.append(f"baseline and initiative fixtures differ for {slot!r}")
        contexts = {
            json.dumps(record["context"], ensure_ascii=False, sort_keys=True, separators=(",", ":"))
            for record in pair_records
        }
        if len(contexts) > 1:
            errors.append(f"baseline and initiative contexts differ for {slot!r}")

    if errors:
        raise EvaluationError("\n".join(errors))

    return [
        seen[(*slot, condition)]
        for slot in sorted(expected)
        for condition in CONDITIONS
    ]


def _generation_index(
    records: Sequence[Mapping[str, Any]],
) -> dict[tuple[str, str, str, int, str], dict[str, Any]]:
    return {
        (*_slot(record), str(record["condition"])): dict(record)
        for record in records
    }


def create_blind_artifacts(
    records: Sequence[Mapping[str, Any]],
    *,
    presentation_salt: str | None = None,
    languages: Sequence[str] = DEFAULT_LANGUAGES,
    models: Sequence[str] = DEFAULT_MODELS,
    scenario_ids: Sequence[str] = DEFAULT_SCENARIOS,
    seeds: Sequence[int] = DEFAULT_SEEDS,
    expected_fixture_sha256: str | None = None,
    expected_scenario_version: str | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Return blind pairs and a private, per-run salted answer key."""
    if presentation_salt is None:
        presentation_salt = secrets.token_hex(16)
    if (
        not isinstance(presentation_salt, str)
        or not PRESENTATION_SALT_PATTERN.fullmatch(presentation_salt)
    ):
        raise EvaluationError(
            "presentation_salt must be a lowercase 32-character hexadecimal string"
        )
    validated = validate_generation_records(
        records,
        languages=languages,
        models=models,
        scenario_ids=scenario_ids,
        seeds=seeds,
        expected_fixture_sha256=expected_fixture_sha256,
        expected_scenario_version=expected_scenario_version,
    )
    incomplete = [
        record["pair_id"]
        for record in validated
        if record["status"] != "completed"
    ]
    if incomplete:
        raise EvaluationError(
            "cannot create blind artifacts with incomplete outputs: "
            + ", ".join(sorted(set(incomplete)))
        )
    indexed = _generation_index(validated)
    blind_pairs: list[dict[str, Any]] = []
    answer_key: list[dict[str, Any]] = []

    slots = sorted(
        _expected_slots(
            languages=languages,
            models=models,
            scenario_ids=scenario_ids,
            seeds=seeds,
        )
    )
    randomized_slots = sorted(
        slots,
        key=lambda slot: hashlib.sha256(
            f"presentation-v2:{presentation_salt}:{_pair_id(*slot)}".encode()
        ).digest(),
    )
    if len(randomized_slots) % 2 != 0:
        raise EvaluationError("blind generation requires an even number of paired turns")
    initiative_first_count = len(randomized_slots) // 2

    def blind_context(value: Mapping[str, Any]) -> dict[str, Any]:
        hidden_keys = {
            "language",
            "model",
            "scenario_id",
            "seed",
            "pair_id",
            "condition",
            "prompt_sha256",
            "pair_input_sha256",
            "fixture_sha256",
        }
        sanitized = {key: item for key, item in value.items() if key not in hidden_keys}
        if not sanitized:
            raise EvaluationError("blind context must retain at least one non-identifying field")
        return sanitized

    for index, slot in enumerate(randomized_slots, start=1):
        language, model, scenario_id, seed = slot
        pair_id = _pair_id(language, model, scenario_id, seed)
        baseline = indexed[(language, model, scenario_id, seed, "baseline")]
        initiative = indexed[(language, model, scenario_id, seed, "initiative")]
        a_condition, b_condition = (
            ("initiative", "baseline")
            if index <= initiative_first_count
            else ("baseline", "initiative")
        )
        by_condition = {"baseline": baseline, "initiative": initiative}
        blind_id = f"blind-{index:04d}"
        blind_pairs.append(
            {
                "schema_version": SCHEMA_VERSION,
                "record_type": "blind_pair",
                "blind_id": blind_id,
                "context": blind_context(by_condition["baseline"]["context"]),
                "a": {"response_text": by_condition[a_condition]["response_text"]},
                "b": {"response_text": by_condition[b_condition]["response_text"]},
            }
        )
        answer_key.append(
            {
                "schema_version": SCHEMA_VERSION,
                "record_type": "blind_key",
                "blind_id": blind_id,
                "pair_id": pair_id,
                "a_condition": a_condition,
                "b_condition": b_condition,
                "presentation_salt": presentation_salt,
            }
        )

    return blind_pairs, answer_key


def _percentile(values: Sequence[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(float(value) for value in values)
    index = max(0, math.ceil(fraction * len(ordered)) - 1)
    return ordered[index]


def _bootstrap_mean_interval(
    values: Sequence[float],
    *,
    resamples: int = BOOTSTRAP_RESAMPLES,
    seed: int = BOOTSTRAP_SEED,
) -> tuple[float, float]:
    if not values:
        return 0.0, 0.0
    rng = random.Random(seed)
    sample_count = len(values)
    means: list[float] = []
    for _ in range(resamples):
        total = sum(values[rng.randrange(sample_count)] for _ in range(sample_count))
        means.append(total / sample_count)
    return _percentile(means, 0.025), _percentile(means, 0.975)


def _p95(values: Sequence[float]) -> float:
    if not values:
        return 0.0
    ordered = sorted(float(value) for value in values)
    index = max(0, math.ceil(0.95 * len(ordered)) - 1)
    return ordered[index]


def _empty_flag_counts() -> dict[str, int]:
    return {key: 0 for key in VIOLATION_KEYS}


def _validate_assessment(value: Any, side: str) -> dict[str, bool]:
    if not isinstance(value, dict):
        raise EvaluationError(f"assessment.{side} must be an object")
    result: dict[str, bool] = {}
    for key in VIOLATION_KEYS:
        flag = value.get(key)
        if not isinstance(flag, bool):
            raise EvaluationError(f"assessment.{side}.{key} must be boolean")
        result[key] = flag
    return result


def score_evaluation(
    generation_records: Sequence[Mapping[str, Any]],
    answer_key_records: Sequence[Mapping[str, Any]],
    rating_records: Sequence[Mapping[str, Any]],
    *,
    languages: Sequence[str] = DEFAULT_LANGUAGES,
    models: Sequence[str] = DEFAULT_MODELS,
    scenario_ids: Sequence[str] = DEFAULT_SCENARIOS,
    seeds: Sequence[int] = DEFAULT_SEEDS,
    expected_fixture_sha256: str | None = None,
    expected_scenario_version: str | None = None,
    minimum_rated_pairs: int = 120,
) -> dict[str, Any]:
    """Map blind ratings back to conditions and evaluate the release gates."""
    if minimum_rated_pairs < 0:
        raise EvaluationError("minimum_rated_pairs must be non-negative")
    validated = validate_generation_records(
        generation_records,
        languages=languages,
        models=models,
        scenario_ids=scenario_ids,
        seeds=seeds,
        expected_fixture_sha256=expected_fixture_sha256,
        expected_scenario_version=expected_scenario_version,
    )
    expected_pairs = {
        _pair_id(language, model, scenario_id, seed)
        for language, model, scenario_id, seed in _expected_slots(
            languages=languages,
            models=models,
            scenario_ids=scenario_ids,
            seeds=seeds,
        )
    }
    key_by_blind_id: dict[str, dict[str, Any]] = {}
    pair_to_blind_id: dict[str, str] = {}
    presentation_salts: set[str] = set()
    for record in answer_key_records:
        pair_id = record.get("pair_id")
        blind_id = record.get("blind_id")
        if record.get("schema_version") != SCHEMA_VERSION or record.get("record_type") != "blind_key":
            raise EvaluationError(f"invalid blind key record for {blind_id!r}")
        if not isinstance(blind_id, str) or not blind_id.strip():
            raise EvaluationError("blind key blind_id must be a non-empty string")
        if not isinstance(pair_id, str) or pair_id not in expected_pairs:
            raise EvaluationError(f"duplicate or unexpected blind key pair {pair_id!r}")
        presentation_salt = record.get("presentation_salt")
        if (
            not isinstance(presentation_salt, str)
            or not PRESENTATION_SALT_PATTERN.fullmatch(presentation_salt)
        ):
            raise EvaluationError(
                f"blind key presentation_salt is invalid for {blind_id!r}"
            )
        presentation_salts.add(presentation_salt)
        if blind_id in key_by_blind_id or pair_id in pair_to_blind_id:
            raise EvaluationError(f"duplicate blind key {blind_id!r}")
        if {record.get("a_condition"), record.get("b_condition")} != set(CONDITIONS):
            raise EvaluationError(f"blind key must contain both conditions for {blind_id!r}")
        key_by_blind_id[blind_id] = dict(record)
        pair_to_blind_id[pair_id] = blind_id
    if len(presentation_salts) != 1:
        raise EvaluationError("blind key must use exactly one presentation_salt")
    if set(pair_to_blind_id) != expected_pairs:
        missing = sorted(expected_pairs - set(pair_to_blind_id))
        extra = sorted(set(pair_to_blind_id) - expected_pairs)
        raise EvaluationError(f"blind key matrix mismatch; missing={missing}, extra={extra}")

    ratings_by_blind_id: dict[str, dict[str, Any]] = {}
    for record in rating_records:
        blind_id = record.get("blind_id")
        if not isinstance(blind_id, str) or blind_id not in key_by_blind_id:
            raise EvaluationError(f"duplicate or unexpected rating {blind_id!r}")
        if blind_id in ratings_by_blind_id:
            raise EvaluationError(f"duplicate rating {blind_id!r}")
        if record.get("schema_version") != SCHEMA_VERSION or record.get("record_type") != "rating":
            raise EvaluationError(f"invalid rating record for {blind_id!r}")
        if "pair_id" in record:
            raise EvaluationError(f"rating must not expose pair_id for {blind_id!r}")
        if record.get("preference") not in RATING_CHOICES:
            raise EvaluationError(f"invalid preference for {blind_id!r}")
        assessment = record.get("assessment")
        if not isinstance(assessment, dict):
            raise EvaluationError(f"assessment is required for {blind_id!r}")
        assessment_a = _validate_assessment(assessment.get("a"), "a")
        assessment_b = _validate_assessment(assessment.get("b"), "b")
        normalized = dict(record)
        normalized["assessment"] = {"a": assessment_a, "b": assessment_b}
        ratings_by_blind_id[blind_id] = normalized
    if set(ratings_by_blind_id) != set(key_by_blind_id):
        missing = sorted(set(key_by_blind_id) - set(ratings_by_blind_id))
        extra = sorted(set(ratings_by_blind_id) - set(key_by_blind_id))
        raise EvaluationError(f"rating matrix mismatch; missing={missing}, extra={extra}")

    pair_records_by_id: dict[str, dict[str, dict[str, Any]]] = {}
    for record in validated:
        pair_records_by_id.setdefault(str(record["pair_id"]), {})[
            str(record["condition"])
        ] = dict(record)
    wins = {"baseline": 0, "initiative": 0}
    flags = {
        "baseline": _empty_flag_counts(),
        "initiative": _empty_flag_counts(),
    }
    latency = {"baseline": [], "initiative": []}
    ties = 0
    invalid = 0
    preference_values: list[float] = []

    for blind_id in sorted(key_by_blind_id):
        key = key_by_blind_id[blind_id]
        pair_id = str(key["pair_id"])
        rating = ratings_by_blind_id[blind_id]
        preference = rating["preference"]
        if preference == "tie":
            ties += 1
            preference_values.append(0.5)
        elif preference == "invalid":
            invalid += 1
        else:
            winner = key[f"{preference}_condition"]
            wins[winner] += 1
            preference_values.append(1.0 if winner == "initiative" else 0.0)

        for side in ("a", "b"):
            condition = key[f"{side}_condition"]
            assessment = rating["assessment"][side]
            for flag_name, enabled in assessment.items():
                if enabled:
                    flags[condition][flag_name] += 1

        pair_records = pair_records_by_id.get(pair_id)
        if pair_records is None or "baseline" not in pair_records:
            raise EvaluationError(f"generation missing for {pair_id!r}")
        for condition in CONDITIONS:
            condition_record = pair_records.get(condition)
            if condition_record is None:
                raise EvaluationError(f"generation missing for {pair_id!r}/{condition}")
            latency[condition].append(float(condition_record["_turn_end_to_end_ms"]))

    decisive_pairs = wins["baseline"] + wins["initiative"]
    rated_pairs = len(preference_values)
    preference_share = (
        sum(preference_values) / rated_pairs if rated_pairs else 0.0
    )
    decisive_preference_rate = (
        wins["initiative"] / decisive_pairs if decisive_pairs else 0.0
    )
    bootstrap_lower, bootstrap_upper = _bootstrap_mean_interval(preference_values)
    p95 = {condition: _p95(values) for condition, values in latency.items()}
    baseline_p95 = p95["baseline"]
    if baseline_p95 == 0:
        latency_regression: float | None = 0.0 if p95["initiative"] == 0 else None
        latency_gate_passed = p95["initiative"] == 0
    else:
        latency_regression = (p95["initiative"] - baseline_p95) / baseline_p95
        latency_gate_passed = latency_regression <= 0.10

    output_count = len(validated)
    status_counts = {
        condition: {
            status: sum(
                1
                for record in validated
                if record["condition"] == condition and record["status"] == status
            )
            for status in GENERATION_STATUSES
        }
        for condition in CONDITIONS
    }
    complete_outputs = sum(
        1 for record in validated if record["status"] == "completed"
    )
    complete_pairs = sum(
        1
        for pair_id in expected_pairs
        if all(
            pair_records_by_id[pair_id][condition]["status"] == "completed"
            for condition in CONDITIONS
        )
    )
    operational_failures = output_count - complete_outputs
    scheduled_pairs = len(expected_pairs)
    flag_rates = {
        condition: {
            key: flags[condition][key] / scheduled_pairs
            for key in VIOLATION_KEYS
        }
        for condition in CONDITIONS
    }
    initiative_irrelevant_rate = flag_rates["initiative"]["irrelevant_event"]
    initiative_continuity_rate = flag_rates["initiative"]["continuity_error"]
    baseline_continuity_rate = flag_rates["baseline"]["continuity_error"]
    initiative_user_agency = flags["initiative"]["user_agency_violation"]
    initiative_safety_violations = flags["initiative"]["safety_hard_violation"]

    gates = {
        "minimum_rated_pairs": {
            "passed": rated_pairs >= minimum_rated_pairs,
            "actual": rated_pairs,
            "required": minimum_rated_pairs,
        },
        "preference_share_at_least_60_percent": {
            "passed": preference_share >= 0.60,
            "actual": preference_share,
            "required": 0.60,
        },
        "preference_95_percent_bootstrap_lower_bound_above_50_percent": {
            "passed": bootstrap_lower > 0.50,
            "actual": bootstrap_lower,
            "required_exclusive": 0.50,
        },
        "no_user_agency_violation": {
            "passed": initiative_user_agency == 0,
            "actual": initiative_user_agency,
            "required": 0,
        },
        "no_safety_hard_violation": {
            "passed": initiative_safety_violations == 0,
            "actual": initiative_safety_violations,
            "required": 0,
        },
        "initiative_irrelevant_event_rate_at_most_5_percent": {
            "passed": initiative_irrelevant_rate <= 0.05,
            "actual": initiative_irrelevant_rate,
            "required": 0.05,
        },
        "continuity_not_worse_than_baseline_by_2_points": {
            "passed": initiative_continuity_rate <= baseline_continuity_rate + 0.02,
            "actual": initiative_continuity_rate,
            "baseline": baseline_continuity_rate,
            "required_max": baseline_continuity_rate + 0.02,
        },
        "initiative_p95_latency_regression_at_most_10_percent": {
            "passed": latency_gate_passed,
            "actual": latency_regression,
            "required": 0.10,
        },
        "no_invalid_ratings": {
            "passed": invalid == 0,
            "actual": invalid,
            "required": 0,
        },
        "no_operational_failures": {
            "passed": operational_failures == 0,
            "actual": operational_failures,
            "required": 0,
        },
    }

    return {
        "schema_version": SCHEMA_VERSION,
        "record_type": "evaluation_report",
        "matrix": {
            "languages": list(languages),
            "models": list(models),
            "scenario_count": len(scenario_ids),
            "seed_count": len(seeds),
            "scheduled_pairs": scheduled_pairs,
            "complete_pairs": complete_pairs,
            "complete_outputs": complete_outputs,
            "paired_turns": len(expected_pairs),
            "model_outputs": output_count,
        },
        "preference": {
            "initiative_wins": wins["initiative"],
            "baseline_wins": wins["baseline"],
            "ties": ties,
            "invalid": invalid,
            "rated_pairs": rated_pairs,
            "decisive_pairs": decisive_pairs,
            "initiative_preference_share": preference_share,
            "decisive_preference_rate": decisive_preference_rate,
            "bootstrap_95_ci": {
                "lower": bootstrap_lower,
                "upper": bootstrap_upper,
                "resamples": BOOTSTRAP_RESAMPLES,
                "seed": BOOTSTRAP_SEED,
            },
        },
        "violations": {
            "counts": flags,
            "rates_per_pair": flag_rates,
        },
        "latency_ms": {
            "p95": p95,
            "initiative_regression": latency_regression,
        },
        "operational": {
            "status_counts": status_counts,
            "failure_count": operational_failures,
            "failure_rate": operational_failures / output_count if output_count else 0.0,
        },
        "gates": gates,
        "go": all(item["passed"] for item in gates.values()),
    }


def _load_and_score(
    args: argparse.Namespace,
    *,
    expected_fixture_sha256: str,
    expected_scenario_version: str,
) -> dict[str, Any]:
    return score_evaluation(
        read_jsonl(Path(args.generations)),
        read_jsonl(Path(args.key)),
        read_jsonl(Path(args.ratings)),
        expected_fixture_sha256=expected_fixture_sha256,
        expected_scenario_version=expected_scenario_version,
    )


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser("validate", help="validate the full generation matrix")
    validate_parser.add_argument("--input", required=True, type=Path)

    blind_parser = subparsers.add_parser(
        "generate-blind",
        help="create a blinded A/B file and a separate private answer key",
    )
    blind_parser.add_argument("--input", required=True, type=Path)
    blind_parser.add_argument("--blind-output", required=True, type=Path)
    blind_parser.add_argument("--key-output", required=True, type=Path)

    score_parser = subparsers.add_parser("score", help="score blinded ratings against the private key")
    score_parser.add_argument("--generations", required=True, type=Path)
    score_parser.add_argument("--key", required=True, type=Path)
    score_parser.add_argument("--ratings", required=True, type=Path)
    score_parser.add_argument("--report-output", type=Path)

    args = parser.parse_args(argv)
    try:
        fixture, fixture_sha256 = load_scenario_fixture()
        fixture_version = str(fixture["fixture_version"])
        if args.command == "validate":
            records = validate_generation_records(
                read_jsonl(args.input),
                expected_fixture_sha256=fixture_sha256,
                expected_scenario_version=fixture_version,
            )
            status_counts = _status_counts(records)
            complete = status_counts["completed"] == len(records)
            print(
                json.dumps(
                    {
                        "schema_version": SCHEMA_VERSION,
                        "record_type": "validation_report",
                        "paired_turns": len(records) // 2,
                        "model_outputs": len(records),
                        "status_counts": status_counts,
                        "complete": complete,
                        "valid": complete,
                    },
                    ensure_ascii=False,
                    sort_keys=True,
                )
            )
            return 0 if complete else 2
        elif args.command == "generate-blind":
            if args.blind_output.resolve() == args.key_output.resolve():
                raise EvaluationError(
                    "--blind-output and --key-output must be different paths"
                )
            blind, key = create_blind_artifacts(
                read_jsonl(args.input),
                expected_fixture_sha256=fixture_sha256,
                expected_scenario_version=fixture_version,
            )
            write_jsonl(args.blind_output, blind)
            write_jsonl(args.key_output, key)
            print(
                json.dumps(
                    {
                        "schema_version": SCHEMA_VERSION,
                        "record_type": "blind_generation_report",
                        "paired_turns": len(blind),
                        "model_outputs": len(blind) * 2,
                        "blind_output": str(args.blind_output),
                        "key_output": str(args.key_output),
                    },
                    ensure_ascii=False,
                    sort_keys=True,
                )
            )
        else:
            report = _load_and_score(
                args,
                expected_fixture_sha256=fixture_sha256,
                expected_scenario_version=fixture_version,
            )
            if args.report_output:
                args.report_output.parent.mkdir(parents=True, exist_ok=True)
                args.report_output.write_text(
                    json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8",
                )
            print(json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True))
            return 0 if report["go"] else 2
    except (EvaluationError, OSError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

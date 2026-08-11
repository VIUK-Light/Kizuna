import re
import unittest
from pathlib import Path


RUNTIME_PATH = Path(__file__).resolve().parents[1] / "KizunaAI/AI/LocalAssistantLiteRTLMRuntime.swift"


def runtime_constant(source: str, name: str) -> int:
    match = re.search(
        rf"nonisolated static let {name} = ([0-9_]+)",
        source,
    )
    if match is None:
        raise AssertionError(f"Missing runtime constant: {name}")
    return int(match.group(1).replace("_", ""))


class LiteRTLMBudgetPolicyTests(unittest.TestCase):
    def test_template_reserve_keeps_boundary_requests_within_context(self) -> None:
        source = RUNTIME_PATH.read_text(encoding="utf-8")
        safe_input = runtime_constant(source, "safeInputTokenTarget")
        minimum_input = runtime_constant(source, "minimumInputTokenTarget")
        minimum_output = runtime_constant(source, "minimumOutputTokens")
        maximum_output = runtime_constant(source, "maximumOutputTokens")
        template_reserve = runtime_constant(source, "conversationTemplateTokenReserve")
        safety_margin = 32

        self.assertIn("- templateReserve", source)
        for context in (384, 480, 784, 1_280, 2_048):
            maximum_input_capacity = (
                context - minimum_output - safety_margin - template_reserve
            )
            if maximum_input_capacity < minimum_input:
                continue

            maximum_output_capacity = (
                context - minimum_input - safety_margin - template_reserve
            )
            for requested_output in (minimum_output, 512, maximum_output):
                adjusted_output = min(requested_output, maximum_output_capacity)
                self.assertGreaterEqual(adjusted_output, minimum_output)
                target = min(
                    safe_input,
                    context - adjusted_output - safety_margin - template_reserve,
                )
                self.assertGreaterEqual(target, minimum_input)
                self.assertLessEqual(
                    target + adjusted_output + safety_margin + template_reserve,
                    context,
                )


if __name__ == "__main__":
    unittest.main()

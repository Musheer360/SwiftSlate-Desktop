"""Pure-logic regression tests that run without Windows APIs.

The application imports ctypes.windll at module load time, so these tests compile only
the platform-independent helpers from the source file. Keep their behaviour aligned
with Android's ApiClientUtilsTest.
"""

import ast
import re
from pathlib import Path
import unittest


def load_helpers():
    source_path = Path(__file__).parents[1] / "SwiftSlate.pyw"
    module = ast.parse(source_path.read_text(encoding="utf-8"), filename=str(source_path))
    names = {"strip_markdown_fences", "is_model_refusal", "wrap_user_text", "_redact_secrets"}
    body = [node for node in module.body if isinstance(node, ast.FunctionDef) and node.name in names]
    namespace = {"re": re}
    exec(compile(ast.Module(body=body, type_ignores=[]), str(source_path), "exec"), namespace)
    return namespace


def load_response_helper():
    source_path = Path(__file__).parents[1] / "SwiftSlate.pyw"
    module = ast.parse(source_path.read_text(encoding="utf-8"), filename=str(source_path))
    wanted_functions = {"_read_response_bounded"}
    wanted_classes = {"ApiResponseError"}
    body = [
        node for node in module.body
        if (isinstance(node, ast.FunctionDef) and node.name in wanted_functions)
        or (isinstance(node, ast.ClassDef) and node.name in wanted_classes)
        or (isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id == "MAX_RESPONSE_BYTES" for target in node.targets
        ))
    ]
    namespace = {}
    exec(compile(ast.Module(body=body, type_ignores=[]), str(source_path), "exec"), namespace)
    return namespace


HELPERS = load_helpers()
RESPONSE_HELPERS = load_response_helper()


class ApiUtilsTest(unittest.TestCase):
    def test_refusal_detection_matches_android_cases(self):
        is_refusal = HELPERS["is_model_refusal"]
        refusals = [
            "I'm sorry, but I can't help with that.",
            "I cannot fulfill the request to make the text vulgar.",
            "As an AI, I am unable to generate that.",
            "I cannot comply with that request.",
            "This response violates safety guidelines.",
            "As an AI language model, I don't have opinions.",
            "I’m unable to help with that — try something else.",
        ]
        ordinary_text = [
            "I am sorry I cannot fulfill your order today.",
            "Translate to Spanish: I'm sorry but I can't make it to the party.",
            "Fix grammar: He said I cannot fulfill my promises.",
            "Dear John, I am unable to attend the meeting tomorrow.",
            "Please review the attached workplace safety guidelines before Monday.",
            "The contractor violates our policy on late deliveries every single quarter.",
            "As an AI engineer I built three pipelines last year.",
            "Our safety policy needs an update before the audit.",
            "he said that the new rule violates safety rules at the plant",
            "Our team aims to be helpful and harmless in every interaction.",
            "As an assistant manager, I approve the timesheets each Friday.",
        ]
        self.assertTrue(all(is_refusal(text) for text in refusals))
        self.assertFalse(any(is_refusal(text) for text in ordinary_text))
        self.assertFalse(is_refusal("The quarterly report is attached. " * 10 + "I cannot comply."))

    def test_refusal_detection_blank_input_is_not_a_refusal(self):
        is_refusal = HELPERS["is_model_refusal"]
        self.assertFalse(is_refusal(""))
        self.assertFalse(is_refusal("   \n  "))

    def test_markdown_fences_match_android_cases(self):
        strip_fences = HELPERS["strip_markdown_fences"]
        self.assertEqual("hello world", strip_fences("```text\nhello world\n```"))
        self.assertEqual("hello", strip_fences("   ```\nhello\n```\n\n"))
        self.assertEqual("no fences here", strip_fences("  no fences here  "))
        self.assertEqual("line1\nline2", strip_fences("```\nline1\nline2\n```"))
        self.assertEqual("```", strip_fences("```"))
        self.assertEqual("```\n```", strip_fences("```\n```"))
        self.assertEqual("a ``` in the middle", strip_fences("a ``` in the middle"))

    def test_redact_secrets_masks_provider_echoed_keys(self):
        redact = HELPERS["_redact_secrets"]
        self.assertEqual(
            "Incorrect API key provided: ***",
            redact("Incorrect API key provided: sk-abc123DEF456ghi"),
        )
        self.assertEqual("bad key ***", redact("bad key gsk_ZZZZZZZZZZZZZZZZ"))
        self.assertEqual("key ***", redact("key AIzaSyAbCdEfGhIjKlMn"))

    def test_redact_secrets_leaves_ordinary_messages_intact(self):
        redact = HELPERS["_redact_secrets"]
        self.assertEqual("Model not found.", redact("Model not found."))

    def test_wrap_user_text_fences_input_for_both_providers(self):
        wrap = HELPERS["wrap_user_text"]
        self.assertEqual("<input>\nhello\n</input>", wrap("hello"))

    def test_response_size_is_bounded(self):
        class Response:
            def __init__(self, data):
                self.data = data

            def read(self, _limit):
                return self.data

        read_bounded = RESPONSE_HELPERS["_read_response_bounded"]
        limit = RESPONSE_HELPERS["MAX_RESPONSE_BYTES"]
        self.assertEqual(b"ok", read_bounded(Response(b"ok")))
        with self.assertRaises(RESPONSE_HELPERS["ApiResponseError"]):
            read_bounded(Response(b"x" * (limit + 1)))


if __name__ == "__main__":
    unittest.main()

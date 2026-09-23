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


def load_model_catalog_helpers():
    """Extracts the pure-logic pieces of the live model catalog (parsing + the
    static retirement/curated tables), skipping fetch_live_models itself since
    that makes real network calls."""
    source_path = Path(__file__).parents[1] / "SwiftSlate.pyw"
    module = ast.parse(source_path.read_text(encoding="utf-8"), filename=str(source_path))
    wanted_functions = {"_parse_gemini_models_json"}
    wanted_names = {
        "GROQ_NON_CHAT_SUBSTRINGS", "GEMINI_RETIRED_IDS", "GROQ_RETIRED_IDS",
        "GROQ_MODEL_PARAMS", "GEMINI_MODEL_PARAMS",
        "DEFAULT_GROQ_MODEL", "DEFAULT_GEMINI_MODEL",
    }
    body = [
        node for node in module.body
        if (isinstance(node, ast.FunctionDef) and node.name in wanted_functions)
        or (isinstance(node, ast.Assign) and any(
            isinstance(target, ast.Name) and target.id in wanted_names for target in node.targets
        ))
    ]
    namespace = {"json": __import__("json")}
    exec(compile(ast.Module(body=body, type_ignores=[]), str(source_path), "exec"), namespace)
    return namespace


HELPERS = load_helpers()
RESPONSE_HELPERS = load_response_helper()
MODEL_CATALOG_HELPERS = load_model_catalog_helpers()


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


class LiveModelCatalogTest(unittest.TestCase):
    """Mirrors Android's GeminiClient/GroqModels parsing + curated-table behavior
    (issue #148 parity) — pure logic only, no real network calls."""

    def test_parses_gemini_models_and_filters_non_chat(self):
        parse = MODEL_CATALOG_HELPERS["_parse_gemini_models_json"]
        body = {
            "models": [
                {"name": "models/gemini-3.5-flash-lite", "supportedGenerationMethods": ["generateContent"]},
                {"name": "models/embedding-001", "supportedGenerationMethods": ["embedContent"]},
                {"name": "models/gemini-legacy-vision"},  # no capability arrays -> fail-open, kept
            ],
            "nextPageToken": "",
        }
        ids, data = parse(__import__("json").dumps(body))
        self.assertEqual(["gemini-3.5-flash-lite", "gemini-legacy-vision"], ids)
        self.assertEqual("", data.get("nextPageToken"))

    def test_parse_gemini_models_handles_malformed_body(self):
        parse = MODEL_CATALOG_HELPERS["_parse_gemini_models_json"]
        ids, data = parse("not json")
        self.assertEqual([], ids)
        self.assertEqual({}, data)

    def test_parse_gemini_models_dedupes_and_strips_prefix(self):
        parse = MODEL_CATALOG_HELPERS["_parse_gemini_models_json"]
        body = {"models": [
            {"name": "models/gemini-3.6-flash", "supportedActions": ["generateContent"]},
            {"name": "models/gemini-3.6-flash", "supportedActions": ["generateContent"]},
        ]}
        ids, _ = parse(__import__("json").dumps(body))
        self.assertEqual(["gemini-3.6-flash"], ids)

    def test_groq_non_chat_substrings_match_android_catalog(self):
        substrings = MODEL_CATALOG_HELPERS["GROQ_NON_CHAT_SUBSTRINGS"]
        blocked = ["whisper-large-v3", "playai-tts", "llama-guard-4", "canopylabs/orpheus-3b"]
        allowed = ["openai/gpt-oss-120b", "qwen/qwen3.6-27b"]
        self.assertTrue(all(any(s in name.lower() for s in substrings) for name in blocked))
        self.assertFalse(any(any(s in name.lower() for s in substrings) for name in allowed))

    def test_retired_ids_are_excluded_from_curated_tables(self):
        # A retired id must never sit in the curated params tables — the config
        # loader treats retired-membership and curated-membership as separate
        # checks, and an overlap would make the retired branch unreachable.
        gemini_retired = MODEL_CATALOG_HELPERS["GEMINI_RETIRED_IDS"]
        groq_retired = MODEL_CATALOG_HELPERS["GROQ_RETIRED_IDS"]
        self.assertTrue(gemini_retired.isdisjoint(MODEL_CATALOG_HELPERS["GEMINI_MODEL_PARAMS"]))
        self.assertTrue(groq_retired.isdisjoint(MODEL_CATALOG_HELPERS["GROQ_MODEL_PARAMS"]))

    def test_defaults_are_curated(self):
        # The default model for each provider must be a real entry in that
        # provider's curated params table (it needs to resolve to real reasoning/
        # thinking params), matching Android's SPECS.first().id invariant.
        self.assertIn(MODEL_CATALOG_HELPERS["DEFAULT_GEMINI_MODEL"], MODEL_CATALOG_HELPERS["GEMINI_MODEL_PARAMS"])
        self.assertIn(MODEL_CATALOG_HELPERS["DEFAULT_GROQ_MODEL"], MODEL_CATALOG_HELPERS["GROQ_MODEL_PARAMS"])


if __name__ == "__main__":
    unittest.main()

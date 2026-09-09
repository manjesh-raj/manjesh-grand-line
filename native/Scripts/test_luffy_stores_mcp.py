#!/usr/bin/env python3
"""Tests for luffy_stores_mcp.py - the Straw Hat crew's read-only MCP tools
(phase 2.5, milestones M2.5a/b/c).

Run with: python3 -m unittest test_luffy_stores_mcp -v
(from `native/Scripts/`, or `python3 -m unittest native.Scripts.test_luffy_stores_mcp -v`
from the repo root).

Plain `unittest` with no third-party runner and no fixtures outside this file,
matching `test_sre_kubectl_mcp.py` - the sibling this whole area follows.
Read that file first; the structure here mirrors it deliberately.

What this covers:

  - **M2.5c, the headline**: a write-shaped `tools/call` is refused before
    anything runs, driven over real JSON-RPC stdio rather than by calling a
    handler - plus a source-level guard that this file *cannot* write at all
    (no write-mode `open`, no `os.remove`/`rename`, no `shutil`, no
    `subprocess`). Those are two different guarantees: "every tool in the list
    happens to be read-only today" and "there is no write anywhere in the
    file". Both are asserted, and the source guard walks the real AST rather
    than grepping, so the module docstring's own discussion of the primitives
    it avoids cannot satisfy it.
  - The YAML reader against the exact subset `YamlBeautify.dump` emits, and
    its refusal to guess past anything else.
  - Each of the four tools: the happy path, the search/filter, the caps, and
    GL-14 - "I could not read this" is never returned as "there is nothing
    here".
  - `health_snapshot`'s available/unavailable distinction, which is the one
    place in this feature where flattening two facts into one would tell the
    captain their machine is healthy when nobody has looked.
  - The four tool names as a wire contract with `StrawHatCrew.allowedTools`
    (Swift), asserted from the Swift source so a rename on either side fails
    here.

What this deliberately does NOT cover: that the reader and `YamlBeautify.dump`
genuinely agree. Fixtures written by hand in this file cannot prove that - if
the Swift serializer changed, these fixtures would go on passing while the
real store stopped being readable. `StrawHatMCPSelfTest` (Swift) is the
authority for that: it writes a real `ShiftStore` and a real
`CommandLibraryStore` to a scratch directory, runs *this* script as a real
subprocess over stdio, and asserts it reads back what Swift actually wrote.
"""

import ast
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import luffy_stores_mcp as mcp  # noqa: E402

_SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "luffy_stores_mcp.py")
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
_SWIFT_TOOLS = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "Sources", "FirstmateCockpit", "StrawHatTools.swift",
)


# --- Helpers --------------------------------------------------------------


class _Env:
    """Sets the tools' env vars for one test and restores them after, so a
    case that deletes one cannot leak into the next."""

    KEYS = ("LUFFY_SHIFT_DIR", "LUFFY_DOCS_DIR", "LUFFY_COMMANDS_DIR", "LUFFY_HEALTH_SNAPSHOT")

    def __init__(self, **values):
        self.values = values
        self.saved = {}

    def __enter__(self):
        for key in self.KEYS:
            self.saved[key] = os.environ.get(key)
            os.environ.pop(key, None)
        for key, value in self.values.items():
            os.environ[key] = value
        return self

    def __exit__(self, *_):
        for key, old in self.saved.items():
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old


def _write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def _shift_yaml(key, records):
    """Build a file in the exact shape `ShiftYaml.writeList` + `YamlBeautify.dump`
    emit: a double-quoted top-level key, a block sequence of block mappings,
    every key and every string value double-quoted, `null` bare, `[]` for an
    empty array."""
    lines = ['"%s":' % key]
    for record in records:
        first = True
        for k, v in record.items():
            prefix = "  - " if first else "    "
            first = False
            if v is None:
                lines.append('%s"%s": null' % (prefix, k))
            elif isinstance(v, bool):
                lines.append('%s"%s": %s' % (prefix, k, "true" if v else "false"))
            elif isinstance(v, list):
                if not v:
                    lines.append('%s"%s": []' % (prefix, k))
                else:
                    lines.append('%s"%s":' % (prefix, k))
                    for item in v:
                        lines.append('      - "%s"' % item)
            else:
                escaped = str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
                lines.append('%s"%s": "%s"' % (prefix, k, escaped))
    return "\n".join(lines) + "\n"


def _rpc(requests, env=None):
    """Drive the real script as a real subprocess over stdio and return the
    parsed replies - the only way to assert the JSON-RPC layer (and the only
    way a refusal that happens *before* a handler runs is observable)."""
    payload = "".join(json.dumps(r) + "\n" for r in requests)
    proc = subprocess.run(
        [sys.executable, _SCRIPT],
        input=payload, capture_output=True, text=True, timeout=30,
        env={**os.environ, **(env or {})},
    )
    out = []
    for line in proc.stdout.splitlines():
        line = line.strip()
        if line:
            out.append(json.loads(line))
    return out, proc


def _tool_payload(reply):
    """The tool result's decoded JSON body."""
    return json.loads(reply["result"]["content"][0]["text"])


# --- M2.5c: writes are refused, and cannot happen ------------------------


class WriteRefusalTests(unittest.TestCase):
    """The milestone's own acceptance criterion, plus the stronger structural
    version of it."""

    WRITE_SHAPED = [
        "add_task", "shift_write", "create_task", "docs_write", "write_runbook",
        "command_save", "delete_task", "update_task", "write_file", "run_command",
        "kubectl_readonly",  # a real tool - but the OTHER server's, so not ours
    ]

    def test_every_write_shaped_tool_call_is_refused_over_real_stdio(self):
        with tempfile.TemporaryDirectory() as tmp:
            _write(os.path.join(tmp, "tasks", "active.yaml"),
                   _shift_yaml("tasks", [{"id": "t1", "title": "Existing task", "status": "todo"}]))
            requests = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}]
            for i, name in enumerate(self.WRITE_SHAPED, start=2):
                requests.append({"jsonrpc": "2.0", "id": i, "method": "tools/call",
                                 "params": {"name": name, "arguments": {"title": "written by a tool"}}})
            replies, proc = _rpc(requests, env={"LUFFY_SHIFT_DIR": tmp})

            self.assertEqual(len(replies), len(requests), proc.stderr)
            for name, reply in zip(self.WRITE_SHAPED, replies[1:]):
                self.assertIn("error", reply, f"{name} should be refused, got {reply}")
                self.assertIn("unknown tool", reply["error"]["message"], name)
                self.assertNotIn("result", reply, name)

            # And nothing was written, anywhere under the store root - the
            # refusal happened before any handler could run.
            after = _shift_yaml("tasks", [{"id": "t1", "title": "Existing task", "status": "todo"}])
            with open(os.path.join(tmp, "tasks", "active.yaml")) as f:
                self.assertEqual(f.read(), after)
            self.assertEqual(sorted(os.listdir(tmp)), ["tasks"])

    def test_the_dispatch_table_is_exactly_the_four_read_only_tools(self):
        self.assertEqual(sorted(mcp._TOOLS), sorted([
            mcp.SHIFT_TOOL, mcp.DOCS_TOOL, mcp.COMMAND_TOOL, mcp.HEALTH_TOOL,
        ]))
        self.assertEqual(len(mcp._TOOLS), 4)
        # `tools/list` advertises exactly the dispatch table - a tool the model
        # can see but not call, or vice versa, is a contract bug either way.
        self.assertEqual(sorted(s["name"] for s in mcp._tool_schemas()), sorted(mcp._TOOLS))

    def test_the_source_contains_no_write_primitive_at_all(self):
        """The structural half. Walks the real AST rather than grepping, so
        this file's own docstring naming the primitives it avoids cannot
        satisfy (or break) the check."""
        with open(_SCRIPT, encoding="utf-8") as f:
            tree = ast.parse(f.read())

        banned_attrs = {
            ("os", "remove"), ("os", "unlink"), ("os", "rename"), ("os", "replace"),
            ("os", "rmdir"), ("os", "makedirs"), ("os", "mkdir"), ("os", "chmod"),
            ("os", "system"),
        }
        offences = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    if alias.name.split(".")[0] in ("shutil", "subprocess", "socket", "urllib", "http"):
                        offences.append(f"imports {alias.name}")
            if isinstance(node, ast.ImportFrom) and (node.module or "").split(".")[0] in (
                    "shutil", "subprocess", "socket", "urllib", "http"):
                offences.append(f"imports from {node.module}")
            if not isinstance(node, ast.Call):
                continue
            func = node.func
            if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name):
                if (func.value.id, func.attr) in banned_attrs:
                    offences.append(f"calls {func.value.id}.{func.attr} (line {node.lineno})")
            if isinstance(func, ast.Name) and func.id == "open":
                # `open(path)` and `open(path, "r", ...)` only. Anything with a
                # mode that can create or modify a file is a write.
                mode = None
                if len(node.args) > 1 and isinstance(node.args[1], ast.Constant):
                    mode = node.args[1].value
                for kw in node.keywords:
                    if kw.arg == "mode" and isinstance(kw.value, ast.Constant):
                        mode = kw.value.value
                if mode is not None and not set(str(mode)) <= set("rbt"):
                    offences.append(f"opens a file with mode {mode!r} (line {node.lineno})")
        self.assertEqual(offences, [], "luffy_stores_mcp.py must not be able to write anything")


class AllowlistContractTests(unittest.TestCase):
    """The four tool names are a wire contract with `StrawHatCrew.allowedTools`
    (Swift) and there is no compiler check across that boundary - so each side
    asserts the other names all four. Skips rather than fails if the Swift file
    is not there, so this suite still runs standalone."""

    def test_the_swift_side_pins_exactly_these_four_tools(self):
        if not os.path.exists(_SWIFT_TOOLS):
            self.skipTest("StrawHatTools.swift not found next to this script")
        with open(_SWIFT_TOOLS, encoding="utf-8") as f:
            swift = f.read()
        for name in (mcp.SHIFT_TOOL, mcp.DOCS_TOOL, mcp.COMMAND_TOOL, mcp.HEALTH_TOOL):
            self.assertIn(f'"{name}"', swift, f"Swift's allowlist should name {name}")
        self.assertIn('static let mcpServerName = "luffy-stores"', swift)
        # `serverInfo.name` and the `mcp__<server>__` prefix must be the same
        # string, or every tool is namespaced under a server `claude` never
        # permitted.
        replies, proc = _rpc([{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}])
        self.assertEqual(replies[0]["result"]["serverInfo"]["name"], "luffy-stores", proc.stderr)

    def test_no_write_permission_mode_is_pinned_on_the_swift_side(self):
        if not os.path.exists(_SWIFT_TOOLS):
            self.skipTest("StrawHatTools.swift not found next to this script")
        with open(_SWIFT_TOOLS, encoding="utf-8") as f:
            swift = f.read()
        # Documented in prose, never passed as an argument - the measurement
        # behind that decision is in that file's header.
        self.assertNotIn('"--permission-mode"', swift)


# --- The YAML reader ------------------------------------------------------


class AppYamlTests(unittest.TestCase):
    """`_read_app_yaml` against the subset the app writes, and its refusal to
    guess past anything else."""

    def test_reads_a_shift_list_file(self):
        doc = mcp._read_app_yaml(_shift_yaml("tasks", [
            {"id": "t1", "title": "Fix login", "due_date": "2026-09-10", "due_time": None, "tags": []},
            {"id": "t2", "title": "Rotate secret", "due_date": None, "tags": ["auth", "aws"]},
        ]))
        self.assertEqual(len(doc["tasks"]), 2)
        self.assertEqual(doc["tasks"][0]["title"], "Fix login")
        self.assertIsNone(doc["tasks"][0]["due_time"])
        self.assertEqual(doc["tasks"][0]["tags"], [])
        self.assertEqual(doc["tasks"][1]["tags"], ["auth", "aws"])

    def test_reads_a_flat_mapping_with_a_nested_sequence_of_mappings(self):
        # `CommandLibraryYaml`'s shape: one command per file, `parameters` a
        # list of mappings.
        text = (
            '"name": "Get pod logs"\n'
            '"command": "kubectl logs {{pod}}"\n'
            '"parameters":\n'
            '  - "name": "pod"\n'
            '    "label": "Pod"\n'
            '    "required": true\n'
            '    "options": []\n'
            '  - "name": "ns"\n'
            '    "label": "Namespace"\n'
            '    "required": false\n'
            '    "options":\n'
            '      - "default"\n'
            '      - "prod"\n'
            '"tags":\n'
            '  - "logs"\n'
            '"risk": "read_only"\n'
        )
        doc = mcp._read_app_yaml(text)
        self.assertEqual(doc["name"], "Get pod logs")
        self.assertEqual(len(doc["parameters"]), 2)
        self.assertTrue(doc["parameters"][0]["required"])
        self.assertFalse(doc["parameters"][1]["required"])
        self.assertEqual(doc["parameters"][1]["options"], ["default", "prod"])
        self.assertEqual(doc["tags"], ["logs"])

    def test_preserves_escapes_and_reserved_words_as_strings(self):
        doc = mcp._read_app_yaml(
            '"tasks":\n'
            '  - "title": "Say \\"hi\\" then\\nnewline"\n'
            '    "status": "true"\n'
        )
        self.assertEqual(doc["tasks"][0]["title"], 'Say "hi" then\nnewline')
        # `YamlBeautify` quotes a reserved word precisely so it round-trips as
        # a string; reading it back as a bool would undo that on purpose.
        self.assertEqual(doc["tasks"][0]["status"], "true")

    def test_empty_list_and_empty_document(self):
        self.assertEqual(mcp._read_app_yaml('"tasks": []'), {"tasks": []})
        self.assertEqual(mcp._read_app_yaml(""), {})

    def test_skips_comments_and_blank_lines(self):
        doc = mcp._read_app_yaml('# a comment\n\n"tasks": []\n')
        self.assertEqual(doc, {"tasks": []})

    def test_refuses_rather_than_guessing_past_input_it_does_not_understand(self):
        for text, why in (
            ('"tasks": [{"id": "t1"}]', "flow collections"),
            ('"a": &anchor 1', "anchors"),
            ('"a": |\n  block\n', "block scalars"),
            ('"a": 1\n---\n"b": 2\n', "multiple documents"),
            ('"a":\n\t"b": 1\n', "tab indentation"),
        ):
            with self.assertRaises(mcp.AppYamlError, msg=f"should refuse {why}"):
                mcp._read_app_yaml(text)


# --- shift_read -----------------------------------------------------------


class ShiftReadTests(unittest.TestCase):

    def setUp(self):
        self._ctx = tempfile.TemporaryDirectory()
        self.root = self._ctx.name

    def tearDown(self):
        self._ctx.cleanup()

    def _seed(self, tasks=None, follow_ups=None):
        if tasks is not None:
            _write(os.path.join(self.root, "tasks", "active.yaml"), _shift_yaml("tasks", tasks))
        if follow_ups is not None:
            _write(os.path.join(self.root, "follow-ups", "follow-ups.yaml"),
                   _shift_yaml("follow_ups", follow_ups))

    def test_reads_open_tasks_and_follow_ups(self):
        self._seed(
            tasks=[{"id": "t1", "title": "Fix the login issue", "status": "todo",
                    "priority": "high", "due_date": "2026-09-10", "due_time": "15:00", "notes": None}],
            follow_ups=[{"id": "f1", "title": "Ask Rahul about Cognito", "status": "pending",
                         "priority": "normal", "follow_up_at": "2026-09-12", "follow_up_time": None}],
        )
        with _Env(LUFFY_SHIFT_DIR=self.root):
            out = mcp._shift_read("all", None, None)
        self.assertTrue(out["ok"], out)
        self.assertEqual(out["task_count"], 1)
        self.assertEqual(out["tasks"][0]["title"], "Fix the login issue")
        self.assertEqual(out["tasks"][0]["due"], "2026-09-10 15:00")
        self.assertEqual(out["follow_up_count"], 1)
        self.assertEqual(out["follow_ups"][0]["due"], "2026-09-12")
        # A `null` field is omitted rather than shipped as an empty value.
        self.assertNotIn("notes", out["tasks"][0])

    def test_query_filters_titles_and_notes_case_insensitively(self):
        self._seed(tasks=[
            {"id": "t1", "title": "Fix the login issue", "status": "todo", "notes": None},
            {"id": "t2", "title": "Rotate the secret", "status": "todo", "notes": "cognito pool"},
            {"id": "t3", "title": "Write the changelog", "status": "todo", "notes": None},
        ])
        with _Env(LUFFY_SHIFT_DIR=self.root):
            out = mcp._shift_read("tasks", "COGNITO", None)
        self.assertEqual(out["task_count"], 1)
        self.assertEqual(out["tasks"][0]["id"], "t2")
        self.assertEqual(out["query"], "COGNITO")

    def test_kind_selects_one_list(self):
        self._seed(tasks=[{"id": "t1", "title": "A", "status": "todo"}],
                   follow_ups=[{"id": "f1", "title": "B", "status": "pending"}])
        with _Env(LUFFY_SHIFT_DIR=self.root):
            self.assertNotIn("follow_ups", mcp._shift_read("tasks", None, None))
            self.assertNotIn("tasks", mcp._shift_read("follow_ups", None, None))

    def test_an_unknown_kind_is_refused(self):
        with _Env(LUFFY_SHIFT_DIR=self.root):
            out = mcp._shift_read("everything", None, None)
        self.assertFalse(out["ok"])
        self.assertIn("kind must be", out["error"])

    def test_a_cap_states_what_it_left_out(self):
        self._seed(tasks=[{"id": f"t{i}", "title": f"Task {i}", "status": "todo"} for i in range(60)])
        with _Env(LUFFY_SHIFT_DIR=self.root):
            out = mcp._shift_read("tasks", None, None)
        self.assertEqual(out["task_count"], 60, "the count is always exact")
        self.assertEqual(len(out["tasks"]), mcp._MAX_SHIFT_ITEMS)
        self.assertEqual(out["tasks_not_shown"], 60 - mcp._MAX_SHIFT_ITEMS)

    def test_a_callers_limit_narrows_but_cannot_widen_the_cap(self):
        self._seed(tasks=[{"id": f"t{i}", "title": f"Task {i}", "status": "todo"} for i in range(60)])
        with _Env(LUFFY_SHIFT_DIR=self.root):
            self.assertEqual(len(mcp._shift_read("tasks", None, 3)["tasks"]), 3)
            self.assertEqual(len(mcp._shift_read("tasks", None, 9999)["tasks"]), mcp._MAX_SHIFT_ITEMS)

    def test_a_store_that_has_never_been_written_is_genuinely_empty(self):
        with _Env(LUFFY_SHIFT_DIR=self.root):
            out = mcp._shift_read("all", None, None)
        self.assertTrue(out["ok"])
        self.assertEqual(out["tasks"], [])
        self.assertEqual(out["task_count"], 0)

    def test_an_unreadable_file_is_an_error_not_an_empty_list(self):
        """GL-14, the rule this whole file exists to keep. 'You have no tasks'
        and 'I could not read your tasks' are different facts."""
        _write(os.path.join(self.root, "tasks", "active.yaml"), '"tasks": [{"id": "t1"}]\n')
        with _Env(LUFFY_SHIFT_DIR=self.root):
            out = mcp._shift_read("tasks", None, None)
        self.assertFalse(out["ok"], "an unparseable task file must not read as an empty board")
        self.assertIn("couldn't read", out["error"])
        self.assertNotIn("tasks", out)

    def test_a_missing_store_directory_is_an_error_not_an_empty_list(self):
        with _Env(LUFFY_SHIFT_DIR=os.path.join(self.root, "does-not-exist")):
            out = mcp._shift_read("all", None, None)
        self.assertFalse(out["ok"])
        self.assertIn("couldn't read", out["error"])

    def test_a_missing_env_var_says_so_rather_than_returning_nothing(self):
        with _Env():
            out = mcp._shift_read("all", None, None)
        self.assertFalse(out["ok"])
        self.assertIn("LUFFY_SHIFT_DIR", out["error"])

    def test_completed_tasks_are_not_read(self):
        # `tasks/completed/<YYYY-MM>.yaml` is one file per month - an unbounded
        # walk for a question a conversation never asks.
        self._seed(tasks=[{"id": "t1", "title": "Open one", "status": "todo"}])
        _write(os.path.join(self.root, "tasks", "completed", "2026-08.yaml"),
               _shift_yaml("tasks", [{"id": "t0", "title": "Finished one", "status": "done"}]))
        with _Env(LUFFY_SHIFT_DIR=self.root):
            out = mcp._shift_read("tasks", None, None)
        self.assertEqual([t["title"] for t in out["tasks"]], ["Open one"])


# --- docs_search ----------------------------------------------------------


class DocsSearchTests(unittest.TestCase):

    def setUp(self):
        self._ctx = tempfile.TemporaryDirectory()
        self.root = self._ctx.name
        os.makedirs(os.path.join(self.root, "postmortems"), exist_ok=True)

    def tearDown(self):
        self._ctx.cleanup()

    def _runbook(self, slug, content):
        _write(os.path.join(self.root, slug + ".md"), content)

    def _postmortem(self, slug, content):
        _write(os.path.join(self.root, "postmortems", slug + ".md"), content)

    def test_matches_a_title_and_reports_the_title_as_the_snippet(self):
        self._runbook("cognito", "# Cognito pool rotation\n\nSteps here.\n")
        with _Env(LUFFY_DOCS_DIR=self.root):
            out = mcp._docs_search("cognito", None, None)
        self.assertTrue(out["ok"], out)
        self.assertEqual(out["match_count"], 1)
        self.assertEqual(out["results"][0]["title"], "Cognito pool rotation")
        self.assertEqual(out["results"][0]["scope"], "runbook")
        self.assertEqual(out["results"][0]["snippet"], "Cognito pool rotation")

    def test_matches_a_body_and_returns_an_excerpt_around_the_hit(self):
        self._runbook("latency", "# API latency spike\n\n" + ("filler " * 40) + "check the ALB target group\n")
        with _Env(LUFFY_DOCS_DIR=self.root):
            out = mcp._docs_search("ALB target group", None, None)
        self.assertEqual(out["match_count"], 1)
        snippet = out["results"][0]["snippet"]
        self.assertIn("ALB target group", snippet)
        self.assertIn("…", snippet, "an excerpt from the middle is elided on the left")
        self.assertNotIn("\n", snippet)

    def test_searches_postmortems_too(self):
        self._postmortem("outage", "# March outage\n\nRoot cause: expired certificate.\n")
        with _Env(LUFFY_DOCS_DIR=self.root):
            out = mcp._docs_search("expired certificate", None, None)
        self.assertEqual(out["match_count"], 1)
        self.assertEqual(out["results"][0]["scope"], "postmortem")

    def test_a_title_fetch_returns_the_whole_body(self):
        body = "# Cognito pool rotation\n\n1. Open the console\n2. Rotate\n"
        self._runbook("cognito", body)
        with _Env(LUFFY_DOCS_DIR=self.root):
            out = mcp._docs_search("", None, "cognito pool rotation")
        self.assertTrue(out["ok"], out)
        self.assertEqual(out["content"], body, "answering FROM a runbook needs its real body")
        self.assertEqual(out["title"], "Cognito pool rotation")

    def test_a_title_fetch_for_something_absent_says_so(self):
        self._runbook("cognito", "# Cognito pool rotation\n")
        with _Env(LUFFY_DOCS_DIR=self.root):
            out = mcp._docs_search("", None, "Kafka rebalance")
        self.assertFalse(out["ok"])
        self.assertIn("Kafka rebalance", out["error"])

    def test_no_match_is_an_empty_result_not_an_error(self):
        self._runbook("cognito", "# Cognito pool rotation\n")
        with _Env(LUFFY_DOCS_DIR=self.root):
            out = mcp._docs_search("kafka", None, None)
        self.assertTrue(out["ok"])
        self.assertEqual(out["results"], [])
        self.assertEqual(out["match_count"], 0)

    def test_the_title_falls_back_to_the_slug_when_there_is_no_heading(self):
        self._runbook("no-heading", "Just prose about cognito, no heading.\n")
        with _Env(LUFFY_DOCS_DIR=self.root):
            out = mcp._docs_search("no-heading", None, None)
        self.assertEqual(out["results"][0]["title"], "no-heading")

    def test_results_are_capped_and_the_overflow_is_stated(self):
        for i in range(30):
            self._runbook(f"rb-{i}", f"# Runbook {i} cognito\n")
        with _Env(LUFFY_DOCS_DIR=self.root):
            out = mcp._docs_search("cognito", None, None)
        self.assertEqual(out["match_count"], 30)
        self.assertEqual(len(out["results"]), mcp._MAX_DOCS_RESULTS)
        self.assertEqual(out["results_not_shown"], 30 - mcp._MAX_DOCS_RESULTS)

    def test_a_missing_env_var_says_so(self):
        with _Env():
            out = mcp._docs_search("anything", None, None)
        self.assertFalse(out["ok"])
        self.assertIn("LUFFY_DOCS_DIR", out["error"])

    def test_an_unreadable_document_is_reported_rather_than_dropped(self):
        self._runbook("good", "# Good runbook cognito\n")
        bad = os.path.join(self.root, "bad.md")
        with open(bad, "wb") as f:
            f.write(b"\xff\xfe not valid utf-8 \xff")
        with _Env(LUFFY_DOCS_DIR=self.root):
            out = mcp._docs_search("cognito", None, None)
        self.assertTrue(out["ok"], "one bad file must not lose the rest of the corpus")
        self.assertEqual(out["match_count"], 1)
        self.assertTrue(any("bad.md" in u for u in out["unreadable"]),
                        f"the bad file must be named, got {out.get('unreadable')}")


# --- command_search -------------------------------------------------------


class CommandSearchTests(unittest.TestCase):

    def setUp(self):
        self._ctx = tempfile.TemporaryDirectory()
        self.root = self._ctx.name

    def tearDown(self):
        self._ctx.cleanup()

    def _command(self, category, slug, record, subcategory=None):
        parts = [self.root, category] + ([subcategory] if subcategory else []) + [slug + ".yaml"]
        lines = []
        for k, v in record.items():
            if isinstance(v, list):
                if not v:
                    lines.append('"%s": []' % k)
                else:
                    lines.append('"%s":' % k)
                    for item in v:
                        lines.append('  - "%s"' % item)
            elif v is None:
                lines.append('"%s": null' % k)
            else:
                lines.append('"%s": "%s"' % (k, v))
        _write(os.path.join(*parts), "\n".join(lines) + "\n")

    def test_finds_a_command_and_reports_its_template_and_risk(self):
        self._command("kubernetes", "get-pod-logs", {
            "id": "kubernetes/get-pod-logs", "name": "Get pod logs",
            "description": "Tail a pod's logs", "category": "Kubernetes",
            "command": "kubectl logs {{pod}} -n {{namespace}}",
            "tags": ["logs", "k8s"], "risk": "read_only",
        })
        with _Env(LUFFY_COMMANDS_DIR=self.root):
            out = mcp._command_search("pod logs", None)
        self.assertTrue(out["ok"], out)
        self.assertEqual(out["match_count"], 1)
        hit = out["results"][0]
        self.assertEqual(hit["name"], "Get pod logs")
        self.assertEqual(hit["command"], "kubectl logs {{pod}} -n {{namespace}}")
        self.assertEqual(hit["risk"], "read_only")
        self.assertEqual(hit["category"], "kubernetes")

    def test_walks_a_subcategory_and_reports_it(self):
        self._command("kubernetes", "restart", {
            "name": "Restart a deployment", "description": "", "command": "kubectl rollout restart",
            "tags": [], "risk": "destructive",
        }, subcategory="deployments")
        with _Env(LUFFY_COMMANDS_DIR=self.root):
            out = mcp._command_search("restart", None)
        self.assertEqual(out["match_count"], 1)
        self.assertEqual(out["results"][0]["subcategory"], "deployments")
        self.assertEqual(out["results"][0]["risk"], "destructive",
                         "the risk level must survive - the crew must be able to say a command is dangerous")

    def test_matches_the_same_fields_the_apps_own_search_does(self):
        # `DevOpsCommand.matches(query:)` mirrors: name, description, category,
        # subcategory, tags, template, parameter names/labels.
        self._command("aws", "assume", {
            "name": "Assume a role", "description": "Switch into a target account",
            "command": "aws sts assume-role --role-arn {{role_arn}}",
            "tags": ["iam"], "risk": "read_only",
        })
        with _Env(LUFFY_COMMANDS_DIR=self.root):
            for query in ("assume a role", "target account", "aws", "iam", "sts assume-role"):
                self.assertEqual(mcp._command_search(query, None)["match_count"], 1, query)
            self.assertEqual(mcp._command_search("kubernetes", None)["match_count"], 0)

    def test_skips_the_stores_own_bookkeeping_files(self):
        _write(os.path.join(self.root, "config.yaml"), '"select_options": []\n')
        _write(os.path.join(self.root, "favorites.yaml"), '"favorites": []\n')
        _write(os.path.join(self.root, "recent.yaml"), '"recent": []\n')
        self._command("git", "log", {"name": "Pretty log", "description": "", "command": "git log",
                                     "tags": [], "risk": "read_only"})
        with _Env(LUFFY_COMMANDS_DIR=self.root):
            out = mcp._command_search("", None)
        self.assertEqual(out["match_count"], 1, "only real commands, never config/favorites/recent")
        self.assertEqual(out["results"][0]["name"], "Pretty log")

    def test_an_unreadable_command_file_is_named_rather_than_dropped(self):
        self._command("git", "log", {"name": "Pretty log", "description": "", "command": "git log",
                                     "tags": [], "risk": "read_only"})
        _write(os.path.join(self.root, "git", "broken.yaml"), '"name": [{"bad": 1}]\n')
        with _Env(LUFFY_COMMANDS_DIR=self.root):
            out = mcp._command_search("", None)
        self.assertEqual(out["match_count"], 1)
        self.assertTrue(out["unreadable"], "the broken definition must be reported")

    def test_a_missing_env_var_says_so(self):
        with _Env():
            out = mcp._command_search("anything", None)
        self.assertFalse(out["ok"])
        self.assertIn("LUFFY_COMMANDS_DIR", out["error"])


# --- health_snapshot (M2.5b) ---------------------------------------------


class HealthSnapshotTests(unittest.TestCase):
    """The file bridge, and the one distinction in this feature that must never
    be flattened: 'nobody has checked' is not 'nothing is broken'."""

    def setUp(self):
        self._ctx = tempfile.TemporaryDirectory()
        self.path = os.path.join(self._ctx.name, "health.json")

    def tearDown(self):
        self._ctx.cleanup()

    def _seed(self, payload):
        with open(self.path, "w") as f:
            json.dump(payload, f)

    def test_reads_the_apps_per_turn_snapshot(self):
        self._seed({"generated_at": "2026-09-09T10:00:00Z", "available": True, "services": [
            {"service": "Background signals", "verdict": "ok"},
            {"service": "Scheduled automations", "verdict": "FAILING (2 consecutive failures)"},
        ]})
        with _Env(LUFFY_HEALTH_SNAPSHOT=self.path):
            out = mcp._health_snapshot()
        self.assertTrue(out["ok"], out)
        self.assertTrue(out["available"])
        self.assertEqual(len(out["services"]), 2)
        self.assertIn("FAILING", out["services"][1]["verdict"])
        self.assertEqual(out["generated_at"], "2026-09-09T10:00:00Z")

    def test_nothing_reported_yet_is_available_false_with_a_reason(self):
        self._seed({"available": False, "reason": "no service has reported yet this session",
                    "services": []})
        with _Env(LUFFY_HEALTH_SNAPSHOT=self.path):
            out = mcp._health_snapshot()
        self.assertTrue(out["ok"], "not being able to check is a successful read of an honest state")
        self.assertFalse(out["available"], "this must never read as a healthy machine")
        self.assertIn("reported yet", out["reason"])
        self.assertEqual(out["services"], [])

    def test_a_healthy_machine_and_an_unchecked_one_are_distinguishable(self):
        # The whole point: both have an empty problem list, and they must not
        # look the same to the crew.
        self._seed({"available": True, "services": [{"service": "Background signals", "verdict": "ok"}]})
        with _Env(LUFFY_HEALTH_SNAPSHOT=self.path):
            healthy = mcp._health_snapshot()
        self._seed({"available": False, "reason": "no service has reported yet this session", "services": []})
        with _Env(LUFFY_HEALTH_SNAPSHOT=self.path):
            unchecked = mcp._health_snapshot()
        self.assertNotEqual(healthy["available"], unchecked["available"])

    def test_a_missing_snapshot_is_a_read_failure_not_a_healthy_machine(self):
        with _Env(LUFFY_HEALTH_SNAPSHOT=self.path):
            out = mcp._health_snapshot()
        self.assertFalse(out["ok"])
        self.assertIn("hasn't written", out["error"])

    def test_a_malformed_snapshot_is_a_read_failure(self):
        with open(self.path, "w") as f:
            f.write("{not json")
        with _Env(LUFFY_HEALTH_SNAPSHOT=self.path):
            out = mcp._health_snapshot()
        self.assertFalse(out["ok"])
        self.assertIn("couldn't read", out["error"])

    def test_a_missing_env_var_says_so(self):
        with _Env():
            out = mcp._health_snapshot()
        self.assertFalse(out["ok"])
        self.assertIn("LUFFY_HEALTH_SNAPSHOT", out["error"])

    def test_the_tool_takes_no_arguments(self):
        schema = next(s for s in mcp._tool_schemas() if s["name"] == mcp.HEALTH_TOOL)
        self.assertEqual(schema["inputSchema"].get("properties"), {})
        self.assertNotIn("required", schema["inputSchema"])


# --- The MCP protocol layer ----------------------------------------------


class ProtocolTests(unittest.TestCase):
    """The stdio JSON-RPC surface, driven as a real subprocess."""

    def test_initialize_list_and_call_over_real_stdio(self):
        with tempfile.TemporaryDirectory() as tmp:
            _write(os.path.join(tmp, "tasks", "active.yaml"),
                   _shift_yaml("tasks", [{"id": "t1", "title": "Fix the login issue", "status": "todo"}]))
            replies, proc = _rpc([
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                 "params": {"name": "shift_read", "arguments": {"kind": "tasks"}}},
            ], env={"LUFFY_SHIFT_DIR": tmp})

        self.assertEqual(len(replies), 3, f"a notification gets no reply: {proc.stderr}")
        self.assertEqual(replies[0]["result"]["protocolVersion"], mcp.PROTOCOL_VERSION)
        self.assertEqual(len(replies[1]["result"]["tools"]), 4)
        payload = _tool_payload(replies[2])
        self.assertTrue(payload["ok"])
        self.assertEqual(payload["tasks"][0]["title"], "Fix the login issue")
        self.assertFalse(replies[2]["result"]["isError"])

    def test_a_failed_read_sets_isError_on_the_tool_result(self):
        replies, _ = _rpc([
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": "shift_read", "arguments": {}}},
        ], env={"LUFFY_SHIFT_DIR": ""})
        self.assertTrue(replies[0]["result"]["isError"])
        self.assertFalse(_tool_payload(replies[0])["ok"])

    def test_an_unknown_method_errors_and_a_notification_does_not(self):
        replies, _ = _rpc([
            {"jsonrpc": "2.0", "id": 1, "method": "resources/list"},
            {"jsonrpc": "2.0", "method": "notifications/cancelled"},
        ])
        self.assertEqual(len(replies), 1)
        self.assertEqual(replies[0]["error"]["code"], -32601)

    def test_malformed_input_does_not_kill_the_server(self):
        proc = subprocess.run(
            [sys.executable, _SCRIPT],
            input='not json\n\n{"jsonrpc":"2.0","id":1,"method":"initialize"}\n',
            capture_output=True, text=True, timeout=30,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("protocolVersion", proc.stdout)

    def test_non_object_arguments_are_refused(self):
        replies, _ = _rpc([
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
             "params": {"name": "shift_read", "arguments": "tasks"}},
        ])
        self.assertIn("error", replies[0])
        self.assertIn("must be an object", replies[0]["error"]["message"])

    def test_every_tool_declares_a_read_only_description(self):
        # The persona tells the crew these are read-only; the schema the model
        # actually sees has to say so too, or the two disagree about what the
        # tools are for.
        for schema in mcp._tool_schemas():
            self.assertIn("ead-only", schema["description"],
                          f"{schema['name']}'s description should say it is read-only")


if __name__ == "__main__":
    unittest.main()

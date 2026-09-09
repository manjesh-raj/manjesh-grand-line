#!/usr/bin/env python3
"""The Straw Hat crew's MCP tools: **read-only** access to the app's own
stores, so the crew can *search* rather than only be told.

Minimal MCP stdio JSON-RPC server (`initialize`,
`notifications/initialized`, `tools/list`, `tools/call`), standard library
only, no pip install. Spawned as a subprocess of the local `claude` CLI -
see `StrawHatCrew.setUp()` (Swift) for the `--mcp-config` it is registered
in, and `StrawHatRunner` for the `--allowedTools` pin.

This is the sibling of `sre_kubectl_mcp.py` and follows its shape
deliberately (same stdio framing, same `_reply`/`main` dispatch, same
"validate before doing anything" discipline, same stdlib-only rule). Read
that file first; anything structural here that differs from it is a bug,
not a style choice.

## Phase 2.5, and why it exists

The captain-approved plan (`data/deepen-straw-hat-pirates-plan-explore-ja-3a/
straw-hat-pirates-plan.html`, firstmate side - read its "round-2 finding
that upgrades the architecture" card and milestones M2.5a/b/c) records the
finding this whole phase rests on: round 1 framed native tool use as a
Phase-4 luxury needing the direct Anthropic API, and that was wrong for the
CLI path. This app already runs genuine MCP tool use through `claude -p`, in
production, today - SRE Lead has since it shipped. So the crew can *pull*
what it needs with zero new secrets and zero new networking.

Phase 2 pushes a bounded snapshot into every turn (`StrawHatContext.swift`):
~0.5-1k input tokens, every turn, relevant or not, capped hard enough that
most of the captain's data is simply not in it. That stays - push and pull
are complementary, not alternatives. What these tools add is the half
injection cannot do: searching a runbook *body*, finding a saved command,
asking about a task the snapshot's cap left out.

## Writes: never, and the two independent layers that make that true

Proposals plus confirm cards (phase 2, `StrawHatProposalExecutor.swift`) are
the only write path this feature will ever have, and the captain's own click
is the only thing that triggers one. So:

  - **Layer 1, the CLI.** `StrawHatRunner` pins `--allowedTools` to exactly
    the four tool names below. Measured live, not assumed: a tool the model
    asks for that is *not* on that list is denied by `claude` itself and this
    script's handler is never reached (the denial is recorded in the result
    JSON's `permission_denials`). See `StrawHatCrew.allowedTools`.
  - **Layer 2, this file.** `_TOOLS` is the complete, closed dispatch table;
    `tools/call` looks a name up in it and returns a JSON-RPC error for
    anything else. There is no write anywhere in this file - no `open(...,
    "w")`, no `os.remove`, no `shutil`, no `subprocess`. That is asserted by
    `test_luffy_stores_mcp.py` as a property of the source, because "the
    tool list happens to be read-only today" and "this file cannot write"
    are different guarantees.

`sre_kubectl_mcp.py` needs a verb allowlist because its one tool takes a
command to run. Nothing here takes a command, a path, or a filename: every
tool reads a fixed location handed to it by the app through the environment,
so there is no injection surface to allowlist in the first place. The one
thing a caller controls is a search string, which is only ever compared
against text already read from disk.

## GL-14: unreadable is never rendered as empty

The rule the context snapshot already follows, and the one that matters most
here. "You have no tasks" and "I could not read your tasks" are different
facts, and a crew that confuses them tells the captain their board is clear
when nobody looked. So every tool returns `{"ok": false, "error": ...}` when
a store cannot be read, and `{"ok": true, ...}` with an empty list only when
the store genuinely *is* empty. `_read_app_yaml` raises rather than guessing
past a line it does not understand, for the same reason.

## Reading the app's YAML without a YAML library

`shift_read` and `command_search` read files the app itself wrote, and this
script cannot `import yaml` (stdlib only, matching `sre_kubectl_mcp.py`, and
this app ships no pip dependencies at all). It does not need to: those files
are not arbitrary YAML, they are the output of one serializer
(`YamlBeautify.dump`, over `ShiftYaml`/`CommandLibraryYaml`'s own maps), and
that serializer emits a tiny, fully-known subset - every key and every string
value double-quoted, `null` bare, `[]`/`{}` for empty collections, two-space
indent, block sequences of block mappings. `_read_app_yaml` reads exactly
that subset and **raises on anything else**, so a file written by something
other than this app degrades to a stated read failure rather than to a
plausible-looking wrong answer.

The one assumption here - that this reader and `YamlBeautify.dump` agree - is
the thing that could silently rot, so it is not tested against fixtures
written by hand in this repo. `StrawHatMCPSelfTest` (Swift) writes a real
`ShiftStore` and a real `CommandLibraryStore` to a scratch directory, runs
*this* script as a real subprocess over stdio, and asserts it reads back what
Swift actually wrote. That cross-language case is the authority; the Python
fixtures below are the fast, focused half.
"""

import json
import os
import sys

PROTOCOL_VERSION = "2024-11-05"

# --- Tool names -----------------------------------------------------------
#
# These four strings are a wire contract with `StrawHatCrew.allowedTools`
# (Swift), which pins `--allowedTools` to `mcp__luffy-stores__<name>` for
# exactly this set. There is no compiler check across that boundary, so
# renaming one here without the matching Swift change silently removes a
# tool's permission - the model asks, `claude` denies, and the crew reports
# it cannot see something it should. `test_luffy_stores_mcp.py` asserts the
# Swift side names all four.
SHIFT_TOOL = "shift_read"
DOCS_TOOL = "docs_search"
COMMAND_TOOL = "command_search"
HEALTH_TOOL = "health_snapshot"

# --- Result caps ----------------------------------------------------------
#
# A tool result is model input, so an uncapped one is an unbounded prompt.
# Every cap below states its own overflow ("...and N more" / a `truncated`
# field) rather than silently dropping the tail - the house "no silent caps"
# rule. These are *higher* than `StrawHatContextSnapshot`'s equivalents on
# purpose: the snapshot's caps are paid on every single turn whether relevant
# or not, while these are paid only on a turn that actually asked.
_MAX_SHIFT_ITEMS = 40
_MAX_DOCS_RESULTS = 12
_MAX_COMMAND_RESULTS = 15
# How much of a matched document body to quote around the hit. Mirrors
# `DocsKnowledgeSearch.matchSnippet`'s own 60 characters of context, so a
# hit reads the same here as it does in the app's own search UI.
_SNIPPET_CONTEXT_CHARS = 60
# A hard ceiling on any single file this script will read into memory. These
# are the captain's own hand-written notes and runbooks, so a megabyte is
# already far past anything real; the point is that a pathological file
# cannot turn one tool call into an out-of-memory.
_MAX_FILE_BYTES = 2 * 1024 * 1024


class AppYamlError(Exception):
    """`_read_app_yaml` could not read a document as the subset the app
    writes. Deliberately fatal to the read that hit it: the alternative is
    returning a partially-parsed document, which is exactly the
    "plausible-looking wrong answer" GL-14 forbids."""


def _unquote(token, where):
    """One scalar, in the forms `YamlBeautify.scalarText` can emit."""
    token = token.strip()
    if token == "" or token == "null" or token == "~":
        return None
    if token == "[]" or token == "{}":
        # An empty collection in a scalar position - `YamlBeautify` emits
        # these inline, and both read back as "nothing here".
        return [] if token == "[]" else {}
    if token in ("true", "false"):
        return token == "true"
    if len(token) >= 2 and token[0] == '"' and token[-1] == '"':
        body, out, i = token[1:-1], [], 0
        while i < len(body):
            ch = body[i]
            if ch == "\\" and i + 1 < len(body):
                nxt = body[i + 1]
                out.append({"n": "\n", "t": "\t", '"': '"', "\\": "\\"}.get(nxt, nxt))
                i += 2
                continue
            out.append(ch)
            i += 1
        return "".join(out)
    if len(token) >= 2 and token[0] == "'" and token[-1] == "'":
        return token[1:-1].replace("''", "'")
    # A bare scalar. `ShiftYaml`/`CommandLibraryYaml` quote every string they
    # write, so a bare token here is a number or a bool the app emitted
    # unquoted - anything else is a document this reader does not understand.
    try:
        return int(token)
    except ValueError:
        pass
    try:
        return float(token)
    except ValueError:
        pass
    raise AppYamlError(f"unrecognized scalar {token!r} ({where})")


def _split_key(line, where):
    """`"key": rest` / `"key":` -> (key, rest). Splits at the first `":` so a
    colon inside the quoted key cannot end it early."""
    if line.startswith('"'):
        end = line.find('":', 1)
        if end < 0:
            raise AppYamlError(f"unterminated quoted key ({where})")
        return _unquote(line[: end + 1], where), line[end + 2 :].strip()
    idx = line.find(":")
    if idx < 0:
        raise AppYamlError(f"expected a `key: value` line, got {line!r} ({where})")
    return line[:idx].strip(), line[idx + 1 :].strip()


def _read_app_yaml(text, where="document"):
    """Parse the `YamlBeautify.dump` subset into plain Python values.

    Handles exactly: a top-level block mapping; nested block mappings; block
    sequences whose items are scalars or block mappings (including
    `YamlBeautify`'s `- "key": value` first-line-inlined form); `null`,
    booleans, numbers, and single/double-quoted strings; `[]`/`{}` inline
    empties; `#` comment lines and blank lines. Raises `AppYamlError` on
    anything else - flow collections, anchors, block scalars, multiple
    documents, tabs for indentation.
    """
    lines = []
    for raw in text.split("\n"):
        if "\t" in raw[: len(raw) - len(raw.lstrip())]:
            raise AppYamlError(f"tab indentation is not part of the app's YAML subset ({where})")
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped == "---":
            # `YamlBeautify.dump` only emits this for a *multi*-document
            # dump, which nothing in these stores does.
            raise AppYamlError(f"multi-document YAML is not part of the app's subset ({where})")
        lines.append((len(raw) - len(raw.lstrip(" ")), stripped))

    pos = [0]

    def parse_block(indent):
        """A mapping or a sequence, whichever the next line at `indent` is."""
        if pos[0] >= len(lines):
            return None
        _, first = lines[pos[0]]
        return parse_seq(indent) if first.startswith("- ") or first == "-" else parse_map(indent)

    def parse_map(indent):
        out = {}
        while pos[0] < len(lines):
            line_indent, line = lines[pos[0]]
            if line_indent < indent:
                break
            if line_indent > indent:
                raise AppYamlError(f"unexpected indentation at {line!r} ({where})")
            if line.startswith("- ") or line == "-":
                break
            pos[0] += 1
            key, rest = _split_key(line, where)
            if rest:
                out[key] = _unquote(rest, where)
                continue
            # A bare `key:` - its value is the indented block below it, or
            # `None` if the block ended (which `YamlBeautify` never emits,
            # but a hand-edited file could).
            if pos[0] < len(lines) and lines[pos[0]][0] > indent:
                out[key] = parse_block(lines[pos[0]][0])
            else:
                out[key] = None
        return out

    def parse_seq(indent):
        out = []
        while pos[0] < len(lines):
            line_indent, line = lines[pos[0]]
            if line_indent < indent:
                break
            if line_indent > indent:
                raise AppYamlError(f"unexpected indentation at {line!r} ({where})")
            if not (line.startswith("- ") or line == "-"):
                break
            pos[0] += 1
            body = line[2:].strip() if line.startswith("- ") else ""
            if not body:
                # `-` on its own: a nested block on the following lines.
                if pos[0] < len(lines) and lines[pos[0]][0] > indent:
                    out.append(parse_block(lines[pos[0]][0]))
                else:
                    out.append(None)
                continue
            # `- "key": value` is `YamlBeautify`'s inlined first line of a
            # block mapping item; the rest of that mapping's keys follow at a
            # deeper indent. Any other `- <scalar>` is a plain sequence item.
            if body.startswith('"') and '":' in body:
                item = {}
                key, rest = _split_key(body, where)
                item[key] = _unquote(rest, where) if rest else None
                child_indent = indent + 2
                if not rest and pos[0] < len(lines) and lines[pos[0]][0] > child_indent:
                    item[key] = parse_block(lines[pos[0]][0])
                while pos[0] < len(lines) and lines[pos[0]][0] == child_indent:
                    _, k_line = lines[pos[0]]
                    if k_line.startswith("- ") or k_line == "-":
                        break
                    pos[0] += 1
                    k, r = _split_key(k_line, where)
                    if r:
                        item[k] = _unquote(r, where)
                    elif pos[0] < len(lines) and lines[pos[0]][0] > child_indent:
                        item[k] = parse_block(lines[pos[0]][0])
                    else:
                        item[k] = None
                out.append(item)
                continue
            out.append(_unquote(body, where))
        return out

    doc = parse_block(0)
    if pos[0] < len(lines):
        raise AppYamlError(f"could not read the whole document (stopped at {lines[pos[0]][1]!r}) ({where})")
    return doc if doc is not None else {}


# --- Store locations ------------------------------------------------------
#
# Every path comes from the environment, set by `StrawHatCrew.setUp()` from
# the store roots the app itself resolved - never guessed here, and never
# derived from a caller-supplied argument. That is what makes a self-test's
# `FM_SHIFT_DIR` scratch directory reach these tools automatically, and what
# means no tool call can be pointed at a path the app did not choose.

_SHIFT_DIR_ENV = "LUFFY_SHIFT_DIR"
_DOCS_DIR_ENV = "LUFFY_DOCS_DIR"
_COMMANDS_DIR_ENV = "LUFFY_COMMANDS_DIR"
_HEALTH_FILE_ENV = "LUFFY_HEALTH_SNAPSHOT"


def _env_dir(name, label):
    path = os.environ.get(name)
    if not path:
        return None, f"{label} isn't available to me in this session ({name} is not set)."
    if not os.path.isdir(path):
        # Stated, not silently empty: a missing store directory is a real
        # "I couldn't look", not "there is nothing there" (GL-14).
        return None, f"I couldn't read {label} - {path!r} isn't a directory."
    return path, None


def _read_text(path):
    """Read one UTF-8 text file, bounded. Returns `(text, None)` or
    `(None, error)` - never raises for an ordinary I/O problem."""
    try:
        if os.path.getsize(path) > _MAX_FILE_BYTES:
            return None, f"{os.path.basename(path)} is larger than this tool will read"
        with open(path, "r", encoding="utf-8") as f:
            return f.read(), None
    except (OSError, UnicodeDecodeError) as e:
        return None, f"could not read {os.path.basename(path)}: {e}"


def _load_yaml_file(path, key=None):
    """Read one app-written YAML file. Returns `(value, None)` or
    `(None, error)`. With `key`, returns that key's list from the top-level
    mapping (the `ShiftYaml.writeList` shape); without, the whole document.

    A *missing* file is `([] / {}, None)` - genuinely empty, since these
    stores create files lazily on first write. An *unreadable* one is an
    error. Those two are the distinction this whole file exists to keep."""
    if not os.path.exists(path):
        return ([] if key else {}), None
    text, error = _read_text(path)
    if error:
        return None, error
    try:
        doc = _read_app_yaml(text, where=os.path.basename(path))
    except AppYamlError as e:
        return None, f"{os.path.basename(path)} isn't in a format I can read ({e})"
    if key is None:
        return doc, None
    if not isinstance(doc, dict):
        return None, f"{os.path.basename(path)} isn't a mapping"
    items = doc.get(key)
    if items is None or items == []:
        return [], None
    if not isinstance(items, list):
        return None, f"{os.path.basename(path)}'s {key!r} isn't a list"
    return [i for i in items if isinstance(i, dict)], None


def _cap(items, limit, cap):
    """Apply the caller's `limit` on top of this tool's own hard cap, and
    report what was left out rather than dropping it silently."""
    ceiling = cap
    if isinstance(limit, int) and 0 < limit < cap:
        ceiling = limit
    if len(items) <= ceiling:
        return items, 0
    return items[:ceiling], len(items) - ceiling


def _matches(query, *fields):
    """Case-insensitive substring across `fields`, skipping non-strings. An
    empty query matches everything - `DevOpsCommand.matches(query:)`'s own
    behaviour, mirrored so a search means the same thing here as in the app."""
    q = (query or "").strip().lower()
    if not q:
        return True
    for field in fields:
        if isinstance(field, str) and q in field.lower():
            return True
        if isinstance(field, list):
            for item in field:
                if isinstance(item, str) and q in item.lower():
                    return True
    return False


# --- shift_read -----------------------------------------------------------


def _shift_item(record, date_key, time_key):
    """The subset of a task/follow-up record worth spending model tokens on.

    Deliberately not the whole record: `description`/`subtasks`/`tags`/
    `project_id`/`created_at`/`updated_at` are real fields the app stores,
    and shipping all of them for every row would cost more than the pushed
    snapshot this tool exists to supplement."""
    out = {
        "id": record.get("id"),
        "title": record.get("title"),
        "status": record.get("status"),
        "priority": record.get("priority"),
    }
    due, at = record.get(date_key), record.get(time_key)
    if due:
        out["due"] = f"{due} {at}" if at else due
    notes = record.get("notes")
    if notes:
        out["notes"] = notes
    return {k: v for k, v in out.items() if v is not None}


def _shift_read(kind, query, limit):
    kind = (kind or "all").strip().lower()
    if kind not in ("tasks", "follow_ups", "all"):
        return {"ok": False, "error": f"kind must be 'tasks', 'follow_ups' or 'all', not {kind!r}"}

    root, error = _env_dir(_SHIFT_DIR_ENV, "the captain's task board")
    if error:
        return {"ok": False, "error": error}

    result = {"ok": True}
    if kind in ("tasks", "all"):
        # `tasks/active.yaml` only - completed tasks live in one file per
        # month (`tasks/completed/<YYYY-MM>.yaml`, `ShiftStore`), so reading
        # them is an unbounded walk for a question nobody asked. "What have I
        # got open" is what a conversation needs.
        records, error = _load_yaml_file(os.path.join(root, "tasks", "active.yaml"), key="tasks")
        if error:
            return {"ok": False, "error": f"I couldn't read the task list - {error}"}
        matched = [r for r in records if _matches(query, r.get("title"), r.get("notes"), r.get("description"))]
        shown, dropped = _cap(matched, limit, _MAX_SHIFT_ITEMS)
        result["tasks"] = [_shift_item(r, "due_date", "due_time") for r in shown]
        result["task_count"] = len(matched)
        if dropped:
            result["tasks_not_shown"] = dropped

    if kind in ("follow_ups", "all"):
        records, error = _load_yaml_file(os.path.join(root, "follow-ups", "follow-ups.yaml"), key="follow_ups")
        if error:
            return {"ok": False, "error": f"I couldn't read the follow-up list - {error}"}
        matched = [r for r in records if _matches(query, r.get("title"), r.get("notes"))]
        shown, dropped = _cap(matched, limit, _MAX_SHIFT_ITEMS)
        result["follow_ups"] = [_shift_item(r, "follow_up_at", "follow_up_time") for r in shown]
        result["follow_up_count"] = len(matched)
        if dropped:
            result["follow_ups_not_shown"] = dropped

    if query:
        result["query"] = query
    return result


# --- docs_search ----------------------------------------------------------


def _title_from_markdown(content, fallback):
    """The first non-empty line's `# Heading`, else `fallback`. Mirrors
    `DocsRunbookStore.titleFromContent` (Swift) - and `sre_kubectl_mcp.py`'s
    own copy of the same rule, deliberately, so a runbook is called the same
    thing by every one of the three."""
    for raw_line in content.split("\n"):
        stripped = raw_line.strip()
        if not stripped:
            continue
        if stripped.startswith("# "):
            return stripped[2:].strip()
        break
    return fallback


def _snippet(content, query):
    """`DocsKnowledgeSearch.matchSnippet`'s excerpt, mirrored: the title if it
    matched, else 60 characters of context either side of the body hit."""
    low, q = content.lower(), query.lower()
    idx = low.find(q)
    if idx < 0:
        return None
    start = max(0, idx - _SNIPPET_CONTEXT_CHARS)
    end = min(len(content), idx + len(q) + _SNIPPET_CONTEXT_CHARS)
    excerpt = content[start:end].replace("\n", " ").strip()
    if start > 0:
        excerpt = "…" + excerpt
    if end < len(content):
        excerpt += "…"
    return excerpt


def _scan_docs(directory, scope, query, unreadable):
    """Every top-level `.md` in `directory` that matches. Appends to
    `unreadable` rather than raising: one bad file must not lose the rest of
    the corpus, but it must not vanish silently either."""
    hits = []
    try:
        entries = sorted(os.listdir(directory))
    except OSError as e:
        unreadable.append(f"{scope}s ({e})")
        return hits
    for entry in entries:
        if not entry.endswith(".md"):
            continue
        path = os.path.join(directory, entry)
        if not os.path.isfile(path):
            continue
        content, error = _read_text(path)
        if error:
            unreadable.append(f"{scope} {entry!r} ({error})")
            continue
        slug = entry[: -len(".md")]
        title = _title_from_markdown(content, slug)
        if not _matches(query, title, slug):
            if not query or not _snippet(content, query):
                continue
            excerpt = _snippet(content, query)
        else:
            excerpt = title
        hits.append({
            "scope": scope,
            "title": title,
            "slug": slug,
            "snippet": excerpt,
            "lines": content.count("\n") + 1,
        })
    return hits


def _docs_search(query, limit, full_text_for):
    root, error = _env_dir(_DOCS_DIR_ENV, "the captain's runbooks and postmortems")
    if error:
        return {"ok": False, "error": error}

    unreadable = []
    # A specific document asked for by title: the whole body, so the crew can
    # actually answer *from* a runbook instead of only knowing one exists.
    # Bounded by `_MAX_FILE_BYTES` like every other read here.
    if full_text_for:
        for directory, scope in ((root, "runbook"), (os.path.join(root, "postmortems"), "postmortem")):
            for hit in _scan_docs(directory, scope, "", unreadable):
                if hit["title"].strip().lower() == full_text_for.strip().lower():
                    content, error = _read_text(os.path.join(directory, hit["slug"] + ".md"))
                    if error:
                        return {"ok": False, "error": f"I found '{hit['title']}' but couldn't read it - {error}"}
                    out = {"ok": True, "title": hit["title"], "scope": hit["scope"], "content": content}
                    if unreadable:
                        out["unreadable"] = unreadable
                    return out
        return {"ok": False, "error": f"I don't have a runbook or postmortem titled {full_text_for!r}."}

    hits = _scan_docs(root, "runbook", query, unreadable)
    hits += _scan_docs(os.path.join(root, "postmortems"), "postmortem", query, unreadable)
    shown, dropped = _cap(hits, limit, _MAX_DOCS_RESULTS)
    out = {"ok": True, "query": query, "match_count": len(hits), "results": shown}
    if dropped:
        out["results_not_shown"] = dropped
    if unreadable:
        # GL-14 again, one level in: these documents exist and could not be
        # read, which is not the same as them not matching.
        out["unreadable"] = unreadable
    return out


# --- command_search -------------------------------------------------------


def _command_search(query, limit):
    root, error = _env_dir(_COMMANDS_DIR_ENV, "the captain's command library")
    if error:
        return {"ok": False, "error": error}

    # `commands/<category>/[<subcategory>/]<slug>.yaml` (`CommandLibraryStore`),
    # with `config.yaml`/`favorites.yaml`/`recent.yaml` at the root - which are
    # this store's own bookkeeping, not commands, and are skipped by only
    # looking one and two levels down.
    unreadable, hits = [], []
    try:
        categories = sorted(os.listdir(root))
    except OSError as e:
        return {"ok": False, "error": f"I couldn't read the command library ({e})"}

    for category in categories:
        category_dir = os.path.join(root, category)
        if not os.path.isdir(category_dir):
            continue
        try:
            entries = sorted(os.listdir(category_dir))
        except OSError as e:
            unreadable.append(f"category {category!r} ({e})")
            continue
        for entry in entries:
            path = os.path.join(category_dir, entry)
            if os.path.isdir(path):
                try:
                    sub_entries = sorted(os.listdir(path))
                except OSError as e:
                    unreadable.append(f"category {category}/{entry} ({e})")
                    continue
                for sub in sub_entries:
                    if sub.endswith(".yaml"):
                        hits.append((os.path.join(path, sub), category, entry))
                continue
            if entry.endswith(".yaml"):
                hits.append((path, category, None))

    matched = []
    for path, category, subcategory in hits:
        record, error = _load_yaml_file(path)
        if error:
            unreadable.append(error)
            continue
        if not isinstance(record, dict):
            unreadable.append(f"{os.path.basename(path)} isn't a command definition")
            continue
        params = record.get("parameters") or []
        param_names = [p.get("name") for p in params if isinstance(p, dict)]
        param_labels = [p.get("label") for p in params if isinstance(p, dict)]
        # Mirrors `DevOpsCommand.matches(query:)` field for field, so "does
        # this match" means the same thing here as in the app's own library
        # search and its ⌘K provider.
        if not _matches(query, record.get("name"), record.get("description"), category,
                        subcategory, record.get("tags"), record.get("command"),
                        param_names, param_labels):
            continue
        entry = {
            "name": record.get("name"),
            "description": record.get("description"),
            "category": category,
            "command": record.get("command"),
            "risk": record.get("risk"),
        }
        if subcategory:
            entry["subcategory"] = subcategory
        tags = record.get("tags")
        if tags:
            entry["tags"] = tags
        if param_names:
            entry["parameters"] = [n for n in param_names if n]
        matched.append({k: v for k, v in entry.items() if v is not None})

    shown, dropped = _cap(matched, limit, _MAX_COMMAND_RESULTS)
    out = {"ok": True, "query": query, "match_count": len(matched), "results": shown}
    if dropped:
        out["results_not_shown"] = dropped
    if unreadable:
        out["unreadable"] = unreadable
    return out


# --- health_snapshot (M2.5b) ---------------------------------------------
#
# Health is the one store here that is not a file: `ServiceHealthRegistry` is
# in-process app state, a lock-guarded dictionary, so a subprocess has nothing
# to open. The app therefore writes a fresh JSON snapshot of it into the
# session's scratch directory before every turn and points
# `LUFFY_HEALTH_SNAPSHOT` at it - the same file-bridge idea `SRELeadBridge`
# already proved for the much harder version of this problem (a request/
# response round trip through a live terminal), reduced to its simplest form:
# one direction, one file, no polling, nothing to correlate.
#
# `StrawHatRunner.writeHealthSnapshot` writes it atomically (`.tmp` +
# `os.rename`), so this side never reads a half-written file - the same
# discipline `sre_kubectl_mcp.py`'s `_execute_via_bridge` uses for a request.


def _health_snapshot():
    path = os.environ.get(_HEALTH_FILE_ENV)
    if not path:
        return {"ok": False, "error": f"machine health isn't available to me in this session ({_HEALTH_FILE_ENV} is not set)."}
    if not os.path.exists(path):
        # The app writes this before each turn, so its absence means the
        # write failed - not that nothing is being monitored.
        return {"ok": False, "error": "I couldn't read the machine's health - Grand Line hasn't written this turn's snapshot."}
    text, error = _read_text(path)
    if error:
        return {"ok": False, "error": f"I couldn't read the machine's health - {error}"}
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as e:
        return {"ok": False, "error": f"I couldn't read the machine's health snapshot ({e})"}
    if not isinstance(payload, dict):
        return {"ok": False, "error": "the machine health snapshot isn't in a format I can read"}

    # GL-14, and the single most load-bearing distinction in this file: a
    # registry that has not reported yet is NOT a healthy machine. The app
    # says which of the two it is; this must not flatten them.
    if not payload.get("available", False):
        reason = payload.get("reason") or "no service has reported yet this session"
        return {"ok": True, "available": False, "reason": reason, "services": []}
    services = payload.get("services")
    if not isinstance(services, list):
        return {"ok": False, "error": "the machine health snapshot's service list isn't readable"}
    out = {
        "ok": True,
        "available": True,
        "services": [s for s in services if isinstance(s, dict)],
    }
    if payload.get("generated_at"):
        out["generated_at"] = payload["generated_at"]
    return out


# --- MCP plumbing ---------------------------------------------------------


def _tool_schemas():
    return [
        {
            "name": SHIFT_TOOL,
            "description": (
                "Read the captain's OPEN tasks and follow-ups from their task board, optionally "
                "filtered by a search string. Read-only. Use this when you need more than the "
                "capped list in the turn's context block - e.g. to check whether a task already "
                "exists before proposing a new one. Completed tasks are not included. Returns "
                "exact counts plus a capped list; 'tasks_not_shown'/'follow_ups_not_shown' mean "
                "there were more matches than were returned."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "kind": {
                        "type": "string",
                        "enum": ["tasks", "follow_ups", "all"],
                        "description": "Which list to read. Defaults to 'all'.",
                    },
                    "query": {
                        "type": "string",
                        "description": "Optional case-insensitive substring to filter titles and notes by. Omit to list everything open.",
                    },
                    "limit": {"type": "integer", "description": "Optional maximum number of records per list."},
                },
            },
        },
        {
            "name": DOCS_TOOL,
            "description": (
                "Search the captain's runbooks and postmortems (title and full body) and get "
                "matching titles with an excerpt, or fetch one document's whole body by title. "
                "Read-only. Use this to answer 'is there already a runbook for X?' and to answer "
                "*from* a runbook rather than guessing at its contents. Pass 'title' to get a full "
                "body once a search has told you which document you want."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Case-insensitive substring to search titles and bodies for."},
                    "title": {
                        "type": "string",
                        "description": "Fetch this document's entire body instead of searching. Must be the document's exact title.",
                    },
                    "limit": {"type": "integer", "description": "Optional maximum number of results."},
                },
            },
        },
        {
            "name": COMMAND_TOOL,
            "description": (
                "Search the captain's saved DevOps command library and get each match's name, "
                "description, category, template and risk level. Read-only - this only reads the "
                "library, it never runs anything. Use it to answer 'do I have a command for X?' "
                "and to quote a command the captain already saved instead of writing a new one."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Case-insensitive substring to match against name, description, category, tags and the command template."},
                    "limit": {"type": "integer", "description": "Optional maximum number of results."},
                },
            },
        },
        {
            "name": HEALTH_TOOL,
            "description": (
                "Read the machine's current background-service health verdicts. Read-only, takes "
                "no arguments. Returns available=false with a reason when nothing has reported "
                "yet this session - that means 'nobody has checked', which is NOT the same as "
                "'nothing is broken'; say so plainly rather than reporting a healthy machine."
            ),
            "inputSchema": {"type": "object", "properties": {}},
        },
    ]


def _call_shift(args):
    return _shift_read(args.get("kind"), args.get("query"), args.get("limit"))


def _call_docs(args):
    return _docs_search(args.get("query") or "", args.get("limit"), args.get("title"))


def _call_commands(args):
    return _command_search(args.get("query") or "", args.get("limit"))


def _call_health(_args):
    return _health_snapshot()


# The complete, closed dispatch table - layer 2 of the read-only guarantee
# (this file's docstring). `tools/call` looks a name up here and errors on
# anything else; there is no fallthrough, no prefix match, and no handler in
# this file that writes.
_TOOLS = {
    SHIFT_TOOL: _call_shift,
    DOCS_TOOL: _call_docs,
    COMMAND_TOOL: _call_commands,
    HEALTH_TOOL: _call_health,
}


def _reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError:
            continue

        method = req.get("method")
        id_ = req.get("id")

        if method == "initialize":
            _reply(id_, result={
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "luffy-stores", "version": "1.0.0"},
            })
        elif method == "notifications/initialized":
            pass  # no response expected for a notification
        elif method == "tools/list":
            _reply(id_, result={"tools": _tool_schemas()})
        elif method == "tools/call":
            params = req.get("params", {})
            tool_name = params.get("name")
            handler = _TOOLS.get(tool_name)
            if handler is None:
                # Every write-shaped name lands here - there is nothing to
                # refuse *inside*, because no such handler exists at all.
                _reply(id_, error={"code": -32602, "message": f"unknown tool {tool_name!r}"})
                continue
            args_in = params.get("arguments") or {}
            if not isinstance(args_in, dict):
                _reply(id_, error={"code": -32602, "message": "arguments must be an object"})
                continue
            outcome = handler(args_in)
            _reply(id_, result={
                "content": [{"type": "text", "text": json.dumps(outcome, indent=2)}],
                "isError": not outcome.get("ok", False),
            })
        elif id_ is not None:
            _reply(id_, error={"code": -32601, "message": f"method not found: {method}"})


if __name__ == "__main__":
    main()

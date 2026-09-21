#!/usr/bin/env bash
# fm-doc-audience-check.sh - validate the tracked documentation audience inventory.
#
# Usage:
#   bin/fm-doc-audience-check.sh
#   bin/fm-doc-audience-check.sh --root <repo> [--inventory <path>]
#
# The inventory owns classification and setup routing.
# This check validates structure only and does not keyword-lint prose.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
exec python3 - "$@" <<'PY'
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path
from urllib.parse import unquote, urlsplit

MARKDOWN_LINK_RE = re.compile(r"!?\[[^\]]*\]\(([^)]+)\)")
HTML_LINK_RE = re.compile(r"\b(?:href|src)=[\"']([^\"']+)[\"']", re.IGNORECASE)
REQUIRED_TRACKED_PATTERNS = ["*.md", "*.mdx", "*.rst", "*.txt", "docs/examples/*"]


class CheckError(Exception):
    """One deterministic audience-check failure."""


def fail(message: str) -> None:
    raise CheckError(message)


def git_tracked(root: Path, patterns: list[str]) -> list[str]:
    proc = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", "--", *patterns],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", "replace").strip()
        fail(f"git ls-files failed: {detail or 'unknown error'}")
    return sorted(p for p in proc.stdout.decode("utf-8").split("\0") if p)


def load_inventory(path: Path) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        fail(f"inventory is missing: {path}")
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"inventory is unreadable: {exc}")
    if not isinstance(data, dict):
        fail("inventory root must be an object")
    if data.get("version") != 1:
        fail("inventory version must be 1")
    return data


def list_of_strings(value: object, label: str) -> list[str]:
    if not isinstance(value, list) or not value or not all(isinstance(v, str) and v for v in value):
        fail(f"{label} must be a non-empty string array")
    return value


def normalized_link_value(raw: str) -> str:
    value = raw.strip()
    if value.startswith("<") and value.endswith(">"):
        value = value[1:-1].strip()
    if " " in value:
        value = value.split()[0]
    return value


def resolve_local_target(root: Path, source: Path, raw: str) -> Path | None:
    split = urlsplit(normalized_link_value(raw))
    if split.scheme or split.netloc:
        return None
    if not split.path:
        return source.resolve(strict=False) if split.fragment else None
    decoded = unquote(split.path)
    if decoded.startswith("/"):
        fail(f"absolute local link in {source.relative_to(root)}: {raw}")
    target = (source.parent / decoded).resolve(strict=False)
    try:
        target.relative_to(root.resolve())
    except ValueError:
        fail(f"local link escapes repository in {source.relative_to(root)}: {raw}")
    return target


def markdown_local_links(root: Path, source: Path) -> list[tuple[str, Path]]:
    try:
        text = source.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cannot read prose surface {source.relative_to(root)}: {exc}")
    raw_links = MARKDOWN_LINK_RE.findall(text) + HTML_LINK_RE.findall(text)
    result: list[tuple[str, Path]] = []
    for raw in raw_links:
        target = resolve_local_target(root, source, raw)
        if target is not None:
            result.append((raw, target))
    return result


def github_heading_slug(value: str) -> str:
    value = re.sub(r"<[^>]+>", "", value)
    value = value.replace("`", "").strip().lower()
    value = re.sub(r"[^\w\- ]", "", value, flags=re.UNICODE)
    return re.sub(r"\s", "-", value)


def markdown_anchors(path: Path) -> set[str]:
    anchors: set[str] = set()
    counts: Counter[str] = Counter()
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"cannot read link target {path}: {exc}")
    for line in lines:
        match = re.match(r"^#{1,6}\s+(.+?)\s*#*\s*$", line)
        if match:
            base = github_heading_slug(match.group(1))
            if base:
                count = counts[base]
                anchors.add(base if count == 0 else f"{base}-{count}")
                counts[base] += 1
        for explicit in re.findall(r"<(?:a|span)\s+(?:name|id)=[\"']([^\"']+)[\"']", line, re.IGNORECASE):
            anchors.add(explicit)
    return anchors


def validate_agent_skill_pointers(root: Path, data: dict) -> int:
    """Every agent-only skill is either named by AGENTS.md or exempted on the record.

    A skill AGENTS.md names must exist, so a pointer cannot rot into a dangling
    reference; a skill AGENTS.md no longer names must carry the reason and, where
    another surface now triggers it, that surface must still name it.
    """
    spec = data.get("agentSkillPointers")
    if not isinstance(spec, dict):
        fail("agentSkillPointers must be an object")
    source = spec.get("source")
    skills_root_name = spec.get("skillsRoot")
    if not isinstance(source, str) or not source:
        fail("agentSkillPointers.source must be a non-empty string")
    if not isinstance(skills_root_name, str) or not skills_root_name:
        fail("agentSkillPointers.skillsRoot must be a non-empty string")
    source_path = root / source
    if not source_path.is_file():
        fail(f"agentSkillPointers.source is missing: {source}")
    try:
        source_text = source_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        fail(f"agentSkillPointers.source is unreadable {source}: {exc}")

    skills_root = root / skills_root_name
    if not skills_root.is_dir():
        fail(f"agentSkillPointers.skillsRoot is missing: {skills_root_name}")
    present = sorted(
        entry.name for entry in skills_root.iterdir() if (entry / "SKILL.md").is_file()
    )

    raw_referenced = spec.get("referenced")
    if not isinstance(raw_referenced, list) or not raw_referenced:
        fail("agentSkillPointers.referenced must be a non-empty array")
    referenced: list[str] = []
    for index, entry in enumerate(raw_referenced):
        if isinstance(entry, str) and entry:
            referenced.append(entry)
            continue
        if not isinstance(entry, dict):
            fail(f"agentSkillPointers.referenced[{index}] must be a name or an object")
        name = entry.get("name")
        if not isinstance(name, str) or not name:
            fail(f"agentSkillPointers.referenced[{index}].name must be a non-empty string")
        referenced.append(name)
        phrases = entry.get("contains")
        if phrases is None:
            continue
        phrases = list_of_strings(phrases, f"agentSkillPointers.referenced[{index}].contains")
        skill_file = skills_root / name / "SKILL.md"
        try:
            skill_text = skill_file.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            fail(f"{name}: SKILL.md is unreadable: {exc}")
        for phrase in phrases:
            if phrase not in skill_text:
                fail(
                    f"owning skill does not state the boundary: {name} is missing "
                    f"{phrase!r} required by {source}"
                )
    exemptions = spec.get("unreferenced")
    if not isinstance(exemptions, list):
        fail("agentSkillPointers.unreferenced must be an array")
    exempt_names: list[str] = []
    for index, entry in enumerate(exemptions):
        if not isinstance(entry, dict):
            fail(f"agentSkillPointers.unreferenced[{index}] must be an object")
        name = entry.get("name")
        reason = entry.get("reason")
        if not isinstance(name, str) or not name:
            fail(f"agentSkillPointers.unreferenced[{index}].name must be a non-empty string")
        if not isinstance(reason, str) or not reason:
            fail(f"{name}: an unreferenced skill needs a recorded reason")
        exempt_names.append(name)
        via = entry.get("via")
        if via is None:
            continue
        if not isinstance(via, str) or not via:
            fail(f"{name}: agentSkillPointers.unreferenced via must be a non-empty string")
        via_path = root / via
        if not via_path.is_file():
            fail(f"{name}: load-trigger owner is missing: {via}")
        try:
            via_text = via_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            fail(f"{name}: load-trigger owner is unreadable {via}: {exc}")
        if name not in via_text:
            fail(f"{name}: load-trigger owner {via} no longer names it")

    declared = referenced + exempt_names
    duplicates = sorted(name for name, count in Counter(declared).items() if count != 1)
    if duplicates:
        fail("skills declared more than once: " + ", ".join(duplicates))
    missing = sorted(set(present) - set(declared))
    extra = sorted(set(declared) - set(present))
    if missing or extra:
        details = []
        if missing:
            details.append("undeclared skills: " + ", ".join(missing))
        if extra:
            details.append("declared skill has no SKILL.md: " + ", ".join(extra))
        fail("; ".join(details))

    for name in referenced:
        if name not in source_text:
            fail(f"{source} no longer names the skill it is declared to trigger: {name}")
    for name in exempt_names:
        if name in source_text:
            fail(f"{source} names {name}, which is declared unreferenced; move it to referenced")
    return len(declared)


def validate_size_budgets(root: Path, data: dict) -> int:
    """Hold a trimmed instruction surface to its measured size.

    The budget is a ceiling, so further trimming passes and only re-inflation
    fails, naming the overshoot rather than a snapshot of the file's bytes.
    """
    budgets = data.get("sizeBudgets")
    if not isinstance(budgets, list) or not budgets:
        fail("sizeBudgets must be a non-empty array")
    for index, entry in enumerate(budgets):
        if not isinstance(entry, dict):
            fail(f"sizeBudgets[{index}] must be an object")
        path = entry.get("path")
        max_bytes = entry.get("maxBytes")
        note = entry.get("note")
        if not isinstance(path, str) or not path:
            fail(f"sizeBudgets[{index}].path must be a non-empty string")
        if not isinstance(max_bytes, int) or isinstance(max_bytes, bool) or max_bytes <= 0:
            fail(f"{path}: sizeBudgets maxBytes must be a positive whole number")
        if not isinstance(note, str) or not note:
            fail(f"{path}: sizeBudgets needs a note recording what the budget holds")
        target = root / path
        if not target.is_file():
            fail(f"sizeBudgets path is missing: {path}")
        actual = target.stat().st_size
        if actual > max_bytes:
            fail(
                f"{path} exceeds its size budget: {actual} bytes against {max_bytes} "
                f"({actual - max_bytes} over); trim it or raise the budget deliberately"
            )
    return len(budgets)


def validate(root: Path, inventory_path: Path) -> tuple[int, int, int, int]:
    data = load_inventory(inventory_path)
    scope = data.get("scope")
    if not isinstance(scope, dict):
        fail("scope must be an object")
    patterns = list_of_strings(scope.get("trackedPatterns"), "scope.trackedPatterns")
    if patterns != REQUIRED_TRACKED_PATTERNS:
        fail("scope.trackedPatterns must match the fixed maintained-prose scope")
    audiences = set(list_of_strings(data.get("allowedAudiences"), "allowedAudiences"))
    setup_audiences = set(list_of_strings(data.get("setupAudiences"), "setupAudiences"))
    if not setup_audiences <= audiences:
        fail("setupAudiences contains an audience outside allowedAudiences")

    surfaces = data.get("surfaces")
    if not isinstance(surfaces, list):
        fail("surfaces must be an array")
    paths: list[str] = []
    classifications: dict[str, str] = {}
    for index, entry in enumerate(surfaces):
        if not isinstance(entry, dict):
            fail(f"surfaces[{index}] must be an object")
        path = entry.get("path")
        audience = entry.get("audience")
        if not isinstance(path, str) or not path:
            fail(f"surfaces[{index}].path must be a non-empty string")
        if audience not in audiences:
            fail(f"{path}: unsupported audience {audience!r}")
        paths.append(path)
        classifications[path] = audience

    duplicates = sorted(path for path, count in Counter(paths).items() if count != 1)
    if duplicates:
        fail("surfaces classified more than once: " + ", ".join(duplicates))

    tracked = set(git_tracked(root, patterns))
    classified = set(paths)
    missing = sorted(tracked - classified)
    extra = sorted(classified - tracked)
    if missing or extra:
        details = []
        if missing:
            details.append("unclassified: " + ", ".join(missing))
        if extra:
            details.append("not tracked/in scope: " + ", ".join(extra))
        fail("; ".join(details))

    readme_path = root / "README.md"
    readme_targets = {
        os.path.relpath(target, root).replace(os.sep, "/")
        for _, target in markdown_local_links(root, readme_path)
    }
    setup_targets = list_of_strings(data.get("readmeSetupTargets"), "readmeSetupTargets")
    for target in setup_targets:
        if target not in readme_targets:
            fail(f"README setup target is not linked from README.md: {target}")
        if classifications.get(target) not in setup_audiences:
            fail(
                f"README setup target {target} has disallowed audience "
                f"{classifications.get(target)!r}"
            )

    pointers = data.get("requiredOwnerPointers")
    if not isinstance(pointers, list) or not pointers:
        fail("requiredOwnerPointers must be a non-empty array")
    for index, pointer in enumerate(pointers):
        if not isinstance(pointer, dict):
            fail(f"requiredOwnerPointers[{index}] must be an object")
        source = pointer.get("source")
        target = pointer.get("target")
        if not isinstance(source, str) or not isinstance(target, str) or not source or not target:
            fail(f"requiredOwnerPointers[{index}] needs non-empty source and target")
        source_path = root / source
        target_path = root / target
        if not source_path.exists():
            fail(f"owner-pointer source is missing: {source}")
        if not target_path.exists():
            fail(f"owner-pointer target is missing: {target}")
        try:
            source_text = source_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            fail(f"owner-pointer source is unreadable {source}: {exc}")
        linked_targets: set[str] = set()
        if source_path.suffix.lower() in {".md", ".mdx"}:
            linked_targets = {
                os.path.relpath(linked, root).replace(os.sep, "/")
                for _, linked in markdown_local_links(root, source_path)
            }
        if target not in source_text and target not in linked_targets:
            fail(f"required owner pointer missing: {source} -> {target}")
        required_phrases = pointer.get("contains")
        if required_phrases is None:
            continue
        required_phrases = list_of_strings(
            required_phrases, f"requiredOwnerPointers[{index}].contains"
        )
        try:
            target_text = target_path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            fail(f"owner-pointer target is unreadable {target}: {exc}")
        for phrase in required_phrases:
            if phrase not in target_text:
                fail(
                    f"owner pointer target does not state the boundary: "
                    f"{target} is missing {phrase!r} required by {source}"
                )

    skills = validate_agent_skill_pointers(root, data)
    budgets = validate_size_budgets(root, data)

    checked_links = 0
    anchor_cache: dict[Path, set[str]] = {}
    for path in sorted(tracked):
        if Path(path).suffix.lower() not in {".md", ".mdx"}:
            continue
        source = root / path
        for raw, target in markdown_local_links(root, source):
            checked_links += 1
            if not target.exists():
                fail(f"unresolved local link in {path}: {raw}")
            fragment = unquote(urlsplit(normalized_link_value(raw)).fragment)
            if fragment and target.is_file() and target.suffix.lower() in {".md", ".mdx"}:
                anchors = anchor_cache.setdefault(target, markdown_anchors(target))
                if fragment not in anchors:
                    fail(f"unresolved local anchor in {path}: {raw}")

    return len(tracked), checked_links, skills, budgets


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate Firstmate documentation audiences and local links.")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--inventory", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    inventory_path = args.inventory or (root / "docs/documentation-audiences.json")
    if not inventory_path.is_absolute():
        inventory_path = root / inventory_path
    try:
        surfaces, links, skills, budgets = validate(root, inventory_path)
    except CheckError as exc:
        print(f"fm-doc-audience-check: {exc}", file=sys.stderr)
        return 1
    print(
        f"fm-doc-audience-check: ok surfaces={surfaces} local_links={links} "
        f"skill_pointers={skills} size_budgets={budgets}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY

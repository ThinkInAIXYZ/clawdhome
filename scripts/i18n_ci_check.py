#!/usr/bin/env python3
from __future__ import annotations

import json
import pathlib
import re
import sys
from datetime import datetime, timezone
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP_DIR = ROOT / "ClawdHome"
SHARED_DIR = ROOT / "Shared"
SOURCE_DIRS = [APP_DIR, SHARED_DIR]
CATALOG_FILE = APP_DIR / "Stable.xcstrings"
PLACEHOLDER_EN_ALLOWLIST_FILE = ROOT / "scripts" / "i18n_placeholder_en_allowlist.json"
FEEDBACK_DIR = ROOT / "build" / "i18n-feedback"
LATEST_JSON = FEEDBACK_DIR / "latest.json"
LATEST_TXT = FEEDBACK_DIR / "latest.txt"
HISTORY_NDJSON = FEEDBACK_DIR / "history.ndjson"

CJK_RE = re.compile(r"[\u3400-\u9fff]")
KEY_USAGE_RE = re.compile(r'L10n\.(?:k|f)\(\s*"([^"]+)"')
KEY_CALL_RE = re.compile(r"L10n\.(?:k|f)\s*\(")
KEY_LITERAL_CALL_RE = re.compile(r'L10n\.(?:k|f)\(\s*"([^"]+)"')
KEY_FALLBACK_ANY_RE = re.compile(r'L10n\.(?:k|f)\(\s*"([^"]+)"\s*,\s*fallback:')
KEY_FALLBACK_LITERAL_RE = re.compile(r'L10n\.(?:k|f)\(\s*"([^"]+)"\s*,\s*fallback:\s*"((?:[^"\\]|\\.)*)"')
SWIFT_INTERP_RE = re.compile(r"\\\([^)]*\)")
PRINTF_PLACEHOLDER_RE = re.compile(r"%(?:\d+\$)?[@dDuUxXfFeEgGcCsSpaA]")
PLACEHOLDER_ONLY_RE = re.compile(r"^[\s:：,.，;；!！?？()（）/%@\\d\-]+$")
VALID_KEY_RE = re.compile(r"^[A-Za-z0-9._-]+$")


def load_catalog(path: pathlib.Path) -> dict[str, Any]:
    if not path.exists():
        raise FileNotFoundError(f"missing String Catalog: {path}")
    with path.open("r", encoding="utf-8") as f:
        payload = json.load(f)
    strings = payload.get("strings")
    if not isinstance(strings, dict):
        raise ValueError(f"invalid String Catalog structure: {path}")
    return strings


def collect_string_values(node: Any) -> list[str]:
    values: list[str] = []
    if isinstance(node, dict):
        string_unit = node.get("stringUnit")
        if isinstance(string_unit, dict):
            value = string_unit.get("value")
            if isinstance(value, str):
                values.append(value)
        for value in node.values():
            if isinstance(value, (dict, list)):
                values.extend(collect_string_values(value))
    elif isinstance(node, list):
        for value in node:
            values.extend(collect_string_values(value))
    return values


def localization_values(entry: dict[str, Any], language: str) -> list[str]:
    localizations = entry.get("localizations")
    if not isinstance(localizations, dict):
        return []
    lang_node = localizations.get(language)
    if lang_node is None:
        return []
    values = [v for v in collect_string_values(lang_node) if isinstance(v, str)]
    # De-duplicate while preserving order.
    deduped: list[str] = []
    for value in values:
        if value not in deduped:
            deduped.append(value)
    return deduped


def placeholder_signature(s: str) -> tuple[str, ...]:
    items = list(SWIFT_INTERP_RE.findall(s))
    items.extend(PRINTF_PLACEHOLDER_RE.findall(s))
    return tuple(sorted(items))


def extract_used_keys(app_dir: pathlib.Path) -> set[str]:
    keys: set[str] = set()
    for swift_file in app_dir.rglob("*.swift"):
        text = swift_file.read_text(encoding="utf-8", errors="ignore")
        for m in KEY_USAGE_RE.finditer(text):
            keys.add(m.group(1))
    return keys


def extract_dynamic_key_calls(app_dir: pathlib.Path) -> list[tuple[pathlib.Path, int, str]]:
    """
    Find L10n.k/f calls whose first argument is not a string literal.
    Those calls are not statically traceable and can cause i18n completeness checks to miss keys.
    """
    hits: list[tuple[pathlib.Path, int, str]] = []
    for swift_file in app_dir.rglob("*.swift"):
        text = swift_file.read_text(encoding="utf-8", errors="ignore")
        lines = text.splitlines()
        for m in KEY_CALL_RE.finditer(text):
            idx = m.end()
            while idx < len(text) and text[idx].isspace():
                idx += 1
            if idx < len(text) and text[idx] == '"':
                continue
            line_no = text.count("\n", 0, m.start()) + 1
            snippet = lines[line_no - 1].strip() if 0 <= line_no - 1 < len(lines) else "L10n.(...)"
            hits.append((swift_file, line_no, snippet))
    return hits


def iter_swift_files(source_dirs: list[pathlib.Path]) -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for source_dir in source_dirs:
        if not source_dir.exists():
            continue
        files.extend(source_dir.rglob("*.swift"))
    return files


def decode_swift_string_literal(raw: str) -> str:
    try:
        # Reuse JSON escaping behavior for common Swift string escapes.
        return json.loads(f'"{raw}"')
    except Exception:
        return raw


def extract_literal_key_calls(
    source_dirs: list[pathlib.Path],
) -> list[tuple[pathlib.Path, int, str, str, int]]:
    hits: list[tuple[pathlib.Path, int, str, str, int]] = []
    for swift_file in iter_swift_files(source_dirs):
        text = swift_file.read_text(encoding="utf-8", errors="ignore")
        lines = text.splitlines()
        for m in KEY_LITERAL_CALL_RE.finditer(text):
            key = m.group(1)
            line_no = text.count("\n", 0, m.start()) + 1
            snippet = lines[line_no - 1].strip() if 0 <= line_no - 1 < len(lines) else "L10n.(...)"
            hits.append((swift_file, line_no, key, snippet, m.start()))
    return hits


def extract_fallback_literals(source_dirs: list[pathlib.Path]) -> dict[str, list[str]]:
    values: dict[str, list[str]] = {}
    for swift_file in iter_swift_files(source_dirs):
        text = swift_file.read_text(encoding="utf-8", errors="ignore")
        for m in KEY_FALLBACK_LITERAL_RE.finditer(text):
            key = m.group(1)
            fallback_raw = m.group(2)
            fallback = decode_swift_string_literal(fallback_raw)
            bucket = values.setdefault(key, [])
            if fallback not in bucket:
                bucket.append(fallback)
    return values


def extract_fallback_call_starts(source_dirs: list[pathlib.Path]) -> dict[pathlib.Path, set[int]]:
    mapping: dict[pathlib.Path, set[int]] = {}
    for swift_file in iter_swift_files(source_dirs):
        text = swift_file.read_text(encoding="utf-8", errors="ignore")
        starts = {m.start() for m in KEY_FALLBACK_ANY_RE.finditer(text)}
        mapping[swift_file] = starts
    return mapping


def extract_missing_fallback_calls(
    source_dirs: list[pathlib.Path],
) -> list[tuple[pathlib.Path, int, str, str]]:
    literal_calls = extract_literal_key_calls(source_dirs)
    fallback_starts = extract_fallback_call_starts(source_dirs)
    missing: list[tuple[pathlib.Path, int, str, str]] = []
    for path, line_no, key, snippet, start in literal_calls:
        if start not in fallback_starts.get(path, set()):
            missing.append((path, line_no, key, snippet))
    return missing


def is_placeholder_only_text(s: str) -> bool:
    return PLACEHOLDER_ONLY_RE.fullmatch(s) is not None and ("%" in s or "\\(" in s)


def title_case_from_key(key: str) -> str:
    """Mirrors Xcode's auto-fill behavior: split on . and _ then Title-Case each part."""
    parts = re.split(r"[._]", key)
    return " ".join(p[:1].upper() + p[1:] for p in parts if p)


def is_placeholder_titlecased_en(en_value: str, key: str) -> bool:
    """True when the en value is just the Title-Cased key — Xcode's untranslated default."""
    return bool(en_value) and en_value == title_case_from_key(key)


def visual_width(s: str) -> int:
    """
    Approximate on-screen width: ASCII char = 1 unit, CJK char = 2 units.
    Used to compare zh-Hans / en lengths because UIs sized for one language often
    overflow in the other when the visual-width ratio is too lopsided.
    """
    width = 0
    for ch in s:
        if CJK_RE.search(ch):
            width += 2
        else:
            width += 1
    return width


# en visual-width must not exceed zh visual-width * RATIO unless en is short overall.
# Rationale: UIs in this project are typically sized for the Chinese copy first;
# when English grows much longer than Chinese, segmented/inline labels overflow.
# Only fires for short "label-style" entries — body copy with sentence punctuation
# or multi-line content is exempt because Chinese-English length deltas are normal
# in flowing text and don't break layout (line wrap handles it).
# Calibrated against the existing catalog: at 2.0 the warnings are a useful
# review list (~150 entries); at 1.5 the noise dominates (~900) because Chinese
# is naturally denser than English and many borderline cases are non-issues.
LENGTH_DISPARITY_RATIO = 2.0
LENGTH_DISPARITY_MIN_EN_WIDTH = 12   # ignore tiny labels where a 1–2 unit gap reads as a huge ratio
LENGTH_DISPARITY_MAX_EN_WIDTH = 30   # over this is paragraph copy — line wrap handles it
LENGTH_DISPARITY_SENTENCE_CHARS = ".!?。！？\n"


def looks_like_label(en_value: str, zh_value: str) -> bool:
    """Heuristic: short, single-line, no sentence punctuation → likely a UI label."""
    if any(ch in en_value for ch in LENGTH_DISPARITY_SENTENCE_CHARS):
        return False
    if any(ch in zh_value for ch in LENGTH_DISPARITY_SENTENCE_CHARS):
        return False
    return visual_width(en_value) <= LENGTH_DISPARITY_MAX_EN_WIDTH


def length_disparity_warning(en_value: str, zh_value: str) -> bool:
    en_w = visual_width(en_value)
    zh_w = visual_width(zh_value)
    if en_w <= LENGTH_DISPARITY_MIN_EN_WIDTH or zh_w == 0:
        return False
    if not looks_like_label(en_value, zh_value):
        return False
    return en_w > zh_w * LENGTH_DISPARITY_RATIO


def load_placeholder_en_allowlist() -> set[str]:
    if not PLACEHOLDER_EN_ALLOWLIST_FILE.exists():
        return set()
    with PLACEHOLDER_EN_ALLOWLIST_FILE.open("r", encoding="utf-8") as f:
        payload = json.load(f)
    keys = payload.get("keys")
    if isinstance(keys, list):
        return {k for k in keys if isinstance(k, str)}
    return set()


def suspicious_en_value(en_value: str, key: str, zh_values: list[str]) -> bool:
    if en_value == key:
        return True
    if is_placeholder_only_text(en_value):
        # Some keys are intentionally placeholder-only in every locale, e.g. "%d/%d".
        if any(not is_placeholder_only_text(v) for v in zh_values):
            return True
    if "%@" in en_value and any(ch in en_value for ch in ["；", "。", "，", "："]):
        return True
    return False


def print_keys(title: str, keys: list[str]) -> None:
    print(f"- {title}: {len(keys)}")
    for key in keys:
        print(f"  {key}")


def print_dynamic_calls(hits: list[tuple[pathlib.Path, int, str]]) -> None:
    print(f"- dynamic L10n key calls (first arg is not string literal): {len(hits)}")
    for path, line_no, snippet in hits:
        print(f"  {path}:{line_no}: {snippet}")


def print_calls_with_key(
    title: str, hits: list[tuple[pathlib.Path, int, str, str]]
) -> None:
    print(f"- {title}: {len(hits)}")
    for path, line_no, key, snippet in hits:
        print(f"  {path}:{line_no}: [{key}] {snippet}")


def print_fallback_conflicts(conflicts: list[tuple[str, list[str]]]) -> None:
    print(f"- keys with conflicting fallback literals (warning): {len(conflicts)}")
    for key, values in conflicts:
        shown = " | ".join(values)
        print(f"  {key}: {shown}")


def print_length_disparity(items: list[tuple[str, int, int, str, str]]) -> None:
    print(
        f"- length_disparity (warning, en visual width > zh × {LENGTH_DISPARITY_RATIO}, "
        f"label-style only): {len(items)}  — English may overflow UI sized for Chinese; "
        f"shorten or use .labelsHidden()+external label. See docs/i18n.md."
    )
    # Cap console output so it doesn't drown the report; full list lives in latest.json
    SHOW = 30
    for key, en_w, zh_w, en_v, zh_v in items[:SHOW]:
        print(f"  {key}: en={en_w}u zh={zh_w}u  EN={en_v!r}  ZH={zh_v!r}")
    if len(items) > SHOW:
        print(f"  … and {len(items) - SHOW} more (see build/i18n-feedback/latest.json)")


def rel_path(path: pathlib.Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def write_feedback_artifacts(
    *,
    has_error: bool,
    stable_keys_count: int,
    used_keys_count: int,
    invalid_key_format: list[str],
    cjk_keys: list[str],
    used_missing_in_catalog: list[str],
    missing_en: list[str],
    missing_zh: list[str],
    en_contains_cjk: list[str],
    placeholder_mismatch: list[str],
    suspicious_en_values: list[str],
    placeholder_en_values: list[str],
    stale_placeholder_en_allowlist: list[str],
    length_disparity: list[tuple[str, int, int, str, str]],
    dynamic_key_calls: list[tuple[pathlib.Path, int, str]],
    missing_fallback_calls: list[tuple[pathlib.Path, int, str, str]],
    fallback_conflicts: list[tuple[str, list[str]]],
) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path]:
    FEEDBACK_DIR.mkdir(parents=True, exist_ok=True)
    now = datetime.now(timezone.utc).isoformat()

    report = {
        "timestamp_utc": now,
        "status": "failed" if has_error else "passed",
        "summary": {
            "stable_keys": stable_keys_count,
            "used_keys": used_keys_count,
            "has_error": has_error,
            "warning_fallback_conflicts": len(fallback_conflicts),
        },
        "errors": {
            "invalid_key_format": invalid_key_format,
            "keys_containing_cjk": cjk_keys,
            "used_missing_in_catalog": used_missing_in_catalog,
            "missing_en": missing_en,
            "missing_zh_hans": missing_zh,
            "en_contains_cjk": en_contains_cjk,
            "placeholder_mismatch": placeholder_mismatch,
            "suspicious_en_values": suspicious_en_values,
            "placeholder_en_values": placeholder_en_values,
            "stale_placeholder_en_allowlist": stale_placeholder_en_allowlist,
            "dynamic_key_calls": [
                {"file": rel_path(path), "line": line_no, "snippet": snippet}
                for path, line_no, snippet in dynamic_key_calls
            ],
            "missing_literal_fallback_calls": [
                {"file": rel_path(path), "line": line_no, "key": key, "snippet": snippet}
                for path, line_no, key, snippet in missing_fallback_calls
            ],
        },
        "warnings": {
            "fallback_conflicts": [
                {"key": key, "fallbacks": values} for key, values in fallback_conflicts
            ],
            "length_disparity": [
                {
                    "key": key,
                    "en_width": en_w,
                    "zh_width": zh_w,
                    "ratio": round(en_w / zh_w, 2) if zh_w else 0,
                    "en": en_v,
                    "zh": zh_v,
                }
                for key, en_w, zh_w, en_v, zh_v in length_disparity
            ],
        },
    }

    LATEST_JSON.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    lines: list[str] = [
        f"timestamp_utc: {now}",
        f"status: {'failed' if has_error else 'passed'}",
        f"stable_keys: {stable_keys_count}",
        f"used_keys: {used_keys_count}",
        f"warning_fallback_conflicts: {len(fallback_conflicts)}",
    ]
    if invalid_key_format:
        lines.append(f"- invalid_key_format ({len(invalid_key_format)})")
        lines.extend(f"  {k}" for k in invalid_key_format)
    if cjk_keys:
        lines.append(f"- keys_containing_cjk ({len(cjk_keys)})")
        lines.extend(f"  {k}" for k in cjk_keys)
    if used_missing_in_catalog:
        lines.append(f"- used_missing_in_catalog ({len(used_missing_in_catalog)})")
        lines.extend(f"  {k}" for k in used_missing_in_catalog)
    if missing_en:
        lines.append(f"- missing_en ({len(missing_en)})")
        lines.extend(f"  {k}" for k in missing_en)
    if missing_zh:
        lines.append(f"- missing_zh_hans ({len(missing_zh)})")
        lines.extend(f"  {k}" for k in missing_zh)
    if en_contains_cjk:
        lines.append(f"- en_contains_cjk ({len(en_contains_cjk)})")
        lines.extend(f"  {k}" for k in en_contains_cjk)
    if placeholder_mismatch:
        lines.append(f"- placeholder_mismatch ({len(placeholder_mismatch)})")
        lines.extend(f"  {k}" for k in placeholder_mismatch)
    if suspicious_en_values:
        lines.append(f"- suspicious_en_values ({len(suspicious_en_values)})")
        lines.extend(f"  {k}" for k in suspicious_en_values)
    if placeholder_en_values:
        lines.append(f"- placeholder_en_values ({len(placeholder_en_values)})")
        lines.extend(f"  {k}" for k in placeholder_en_values)
    if stale_placeholder_en_allowlist:
        lines.append(f"- stale_placeholder_en_allowlist ({len(stale_placeholder_en_allowlist)})")
        lines.extend(f"  {k}" for k in stale_placeholder_en_allowlist)
    if dynamic_key_calls:
        lines.append(f"- dynamic_key_calls ({len(dynamic_key_calls)})")
        lines.extend(f"  {rel_path(path)}:{line_no}: {snippet}" for path, line_no, snippet in dynamic_key_calls)
    if missing_fallback_calls:
        lines.append(f"- missing_literal_fallback_calls ({len(missing_fallback_calls)})")
        lines.extend(
            f"  {rel_path(path)}:{line_no}: [{key}] {snippet}"
            for path, line_no, key, snippet in missing_fallback_calls
        )
    if fallback_conflicts:
        lines.append(f"- fallback_conflicts_warning ({len(fallback_conflicts)})")
        lines.extend(f"  {key}: {' | '.join(values)}" for key, values in fallback_conflicts)
    if length_disparity:
        lines.append(f"- length_disparity_warning ({len(length_disparity)})")
        lines.extend(
            f"  {key}: en={en_w}u zh={zh_w}u  EN={en_v!r}  ZH={zh_v!r}"
            for key, en_w, zh_w, en_v, zh_v in length_disparity
        )
    LATEST_TXT.write_text("\n".join(lines) + "\n", encoding="utf-8")

    history_row = {
        "timestamp_utc": now,
        "status": "failed" if has_error else "passed",
        "stable_keys": stable_keys_count,
        "used_keys": used_keys_count,
        "invalid_key_format": len(invalid_key_format),
        "keys_containing_cjk": len(cjk_keys),
        "used_missing_in_catalog": len(used_missing_in_catalog),
        "missing_en": len(missing_en),
        "missing_zh_hans": len(missing_zh),
        "en_contains_cjk": len(en_contains_cjk),
        "placeholder_mismatch": len(placeholder_mismatch),
        "suspicious_en_values": len(suspicious_en_values),
        "placeholder_en_values": len(placeholder_en_values),
        "stale_placeholder_en_allowlist": len(stale_placeholder_en_allowlist),
        "dynamic_key_calls": len(dynamic_key_calls),
        "missing_literal_fallback_calls": len(missing_fallback_calls),
        "fallback_conflicts_warning": len(fallback_conflicts),
        "length_disparity_warning": len(length_disparity),
    }
    with HISTORY_NDJSON.open("a", encoding="utf-8") as f:
        f.write(json.dumps(history_row, ensure_ascii=False) + "\n")

    return (LATEST_JSON, LATEST_TXT, HISTORY_NDJSON)


def main() -> int:
    strings = load_catalog(CATALOG_FILE)
    used_keys: set[str] = set()
    dynamic_key_calls: list[tuple[pathlib.Path, int, str]] = []
    for source_dir in SOURCE_DIRS:
        if not source_dir.exists():
            continue
        used_keys.update(extract_used_keys(source_dir))
        dynamic_key_calls.extend(extract_dynamic_key_calls(source_dir))
    missing_fallback_calls = extract_missing_fallback_calls(SOURCE_DIRS)
    fallback_literals = extract_fallback_literals(SOURCE_DIRS)

    invalid_key_format = sorted(k for k in strings if not VALID_KEY_RE.fullmatch(k))
    cjk_keys = sorted(k for k in strings if CJK_RE.search(k))
    used_missing_in_catalog = sorted(k for k in used_keys if k not in strings)

    missing_en: list[str] = []
    missing_zh: list[str] = []
    en_contains_cjk: list[str] = []
    placeholder_mismatch: list[str] = []
    suspicious_en_values: list[str] = []
    placeholder_en_values: list[str] = []  # en is just the Title-Cased key (untranslated)
    length_disparity: list[tuple[str, int, int, str, str]] = []  # warning, not error

    placeholder_en_allowlist = load_placeholder_en_allowlist()

    for key, entry_any in strings.items():
        if not isinstance(entry_any, dict):
            continue
        entry = entry_any
        zh_values = localization_values(entry, "zh-Hans")
        en_values = localization_values(entry, "en")

        if not zh_values:
            missing_zh.append(key)
        if not en_values:
            missing_en.append(key)
            continue

        if any(CJK_RE.search(v) for v in en_values):
            en_contains_cjk.append(key)
        if any(suspicious_en_value(v, key, zh_values) for v in en_values):
            suspicious_en_values.append(key)
        if any(is_placeholder_titlecased_en(v, key) for v in en_values):
            if key not in placeholder_en_allowlist:
                placeholder_en_values.append(key)

        # Visual-width disparity warning (skip placeholders to avoid noisy double-flag).
        if (
            zh_values
            and key not in placeholder_en_allowlist
            and not any(is_placeholder_titlecased_en(v, key) for v in en_values)
        ):
            primary_zh = zh_values[0]
            primary_en = en_values[0]
            if length_disparity_warning(primary_en, primary_zh):
                length_disparity.append(
                    (
                        key,
                        visual_width(primary_en),
                        visual_width(primary_zh),
                        primary_en,
                        primary_zh,
                    )
                )

        if zh_values:
            zh_signatures = {placeholder_signature(v) for v in zh_values}
            en_signatures = {placeholder_signature(v) for v in en_values}
            if zh_signatures != en_signatures:
                placeholder_mismatch.append(key)

    # Flag stale allowlist entries (key was cleaned up — should be removed from allowlist)
    stale_placeholder_en_allowlist = sorted(
        k for k in placeholder_en_allowlist
        if k in strings
        and not any(
            is_placeholder_titlecased_en(v, k)
            for v in localization_values(strings[k], "en")
        )
    )

    fallback_conflicts = sorted((k, v) for k, v in fallback_literals.items() if len(v) > 1)

    has_error = any(
        [
            invalid_key_format,
            cjk_keys,
            used_missing_in_catalog,
            missing_en,
            missing_zh,
            en_contains_cjk,
            placeholder_mismatch,
            suspicious_en_values,
            placeholder_en_values,
            stale_placeholder_en_allowlist,
            dynamic_key_calls,
            missing_fallback_calls,
        ]
    )
    latest_json, latest_txt, history_ndjson = write_feedback_artifacts(
        has_error=has_error,
        stable_keys_count=len(strings),
        used_keys_count=len(used_keys),
        invalid_key_format=invalid_key_format,
        cjk_keys=cjk_keys,
        used_missing_in_catalog=used_missing_in_catalog,
        missing_en=missing_en,
        missing_zh=missing_zh,
        en_contains_cjk=en_contains_cjk,
        placeholder_mismatch=placeholder_mismatch,
        suspicious_en_values=suspicious_en_values,
        placeholder_en_values=placeholder_en_values,
        stale_placeholder_en_allowlist=stale_placeholder_en_allowlist,
        length_disparity=length_disparity,
        dynamic_key_calls=dynamic_key_calls,
        missing_fallback_calls=missing_fallback_calls,
        fallback_conflicts=fallback_conflicts,
    )

    if has_error:
        print("i18n CI check failed")
        if invalid_key_format:
            print_keys("invalid key format (expect [A-Za-z0-9._-])", invalid_key_format)
        if cjk_keys:
            print_keys("keys containing CJK", cjk_keys)
        if used_missing_in_catalog:
            print_keys("keys used in code but missing in Stable.xcstrings", used_missing_in_catalog)
        if missing_en:
            print_keys("keys missing en localization", missing_en)
        if missing_zh:
            print_keys("keys missing zh-Hans localization", missing_zh)
        if en_contains_cjk:
            print_keys("en localized values still containing CJK", en_contains_cjk)
        if placeholder_mismatch:
            print_keys("placeholder mismatch between zh-Hans and en", placeholder_mismatch)
        if suspicious_en_values:
            print_keys("suspicious en localization values", suspicious_en_values)
        if placeholder_en_values:
            print_keys(
                "en value is just the auto-titlecased key — please write a real, short English translation (≤14 chars for picker labels, ≤12 chars for segmented options, ≤14 for buttons; see docs/i18n-style.md)",
                placeholder_en_values,
            )
        if stale_placeholder_en_allowlist:
            print_keys(
                "stale entries in scripts/i18n_placeholder_en_allowlist.json — these keys have been translated, please remove them from the allowlist",
                stale_placeholder_en_allowlist,
            )
        if dynamic_key_calls:
            print_dynamic_calls(dynamic_key_calls)
        if missing_fallback_calls:
            print_calls_with_key(
                "L10n.k/f calls missing literal fallback (fallback: \"...\")",
                missing_fallback_calls,
            )
        if fallback_conflicts:
            print_fallback_conflicts(fallback_conflicts)
        if length_disparity:
            print_length_disparity(length_disparity)
        print(f"- feedback log: {rel_path(latest_json)}")
        print(f"- feedback text: {rel_path(latest_txt)}")
        print(f"- feedback history: {rel_path(history_ndjson)}")
        return 1

    print("i18n CI check passed")
    print(f"- stable keys: {len(strings)}")
    print(f"- used keys in code: {len(used_keys)}")
    if fallback_conflicts:
        print_fallback_conflicts(fallback_conflicts)
    if length_disparity:
        print_length_disparity(length_disparity)
    print(f"- feedback log: {rel_path(latest_json)}")
    print(f"- feedback text: {rel_path(latest_txt)}")
    print(f"- feedback history: {rel_path(history_ndjson)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

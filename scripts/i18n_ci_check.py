#!/usr/bin/env python3
from __future__ import annotations

import json
import pathlib
import re
import sys
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP_DIR = ROOT / "ClawdHome"
CATALOG_FILE = APP_DIR / "Stable.xcstrings"

CJK_RE = re.compile(r"[\u3400-\u9fff]")
KEY_USAGE_RE = re.compile(r'L10n\.(?:k|f)\(\s*"([^"]+)"')
SWIFT_INTERP_RE = re.compile(r"\\\([^)]*\)")
PRINTF_PLACEHOLDER_RE = re.compile(r"%(?:\d+\$)?[@dDuUxXfFeEgGcCsSpaA]")
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


def main() -> int:
    strings = load_catalog(CATALOG_FILE)
    used_keys = extract_used_keys(APP_DIR)

    invalid_key_format = sorted(k for k in strings if not VALID_KEY_RE.fullmatch(k))
    cjk_keys = sorted(k for k in strings if CJK_RE.search(k))
    used_missing_in_catalog = sorted(k for k in used_keys if k not in strings)

    missing_en: list[str] = []
    missing_zh: list[str] = []
    en_contains_cjk: list[str] = []
    placeholder_mismatch: list[str] = []

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

        if zh_values:
            zh_signatures = {placeholder_signature(v) for v in zh_values}
            en_signatures = {placeholder_signature(v) for v in en_values}
            if zh_signatures != en_signatures:
                placeholder_mismatch.append(key)

    has_error = any(
        [
            invalid_key_format,
            cjk_keys,
            used_missing_in_catalog,
            missing_en,
            missing_zh,
            en_contains_cjk,
            placeholder_mismatch,
        ]
    )

    if has_error:
        print("i18n CI check failed")
        if invalid_key_format:
            print(f"- invalid key format (expect [A-Za-z0-9._-]): {len(invalid_key_format)}")
            for key in invalid_key_format[:50]:
                print(f"  {key}")
        if cjk_keys:
            print(f"- keys containing CJK: {len(cjk_keys)}")
            for key in cjk_keys[:50]:
                print(f"  {key}")
        if used_missing_in_catalog:
            print(f"- keys used in code but missing in Stable.xcstrings: {len(used_missing_in_catalog)}")
            for key in used_missing_in_catalog[:50]:
                print(f"  {key}")
        if missing_en:
            print(f"- keys missing en localization: {len(missing_en)}")
            for key in missing_en[:50]:
                print(f"  {key}")
        if missing_zh:
            print(f"- keys missing zh-Hans localization: {len(missing_zh)}")
            for key in missing_zh[:50]:
                print(f"  {key}")
        if en_contains_cjk:
            print(f"- en localized values still containing CJK: {len(en_contains_cjk)}")
            for key in en_contains_cjk[:50]:
                print(f"  {key}")
        if placeholder_mismatch:
            print(f"- placeholder mismatch between zh-Hans and en: {len(placeholder_mismatch)}")
            for key in placeholder_mismatch[:50]:
                print(f"  {key}")
        return 1

    print("i18n CI check passed")
    print(f"- stable keys: {len(strings)}")
    print(f"- used keys in code: {len(used_keys)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

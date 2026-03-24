#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP_DIR = ROOT / "ClawdHome"

# Detect direct UI literals that should go through stable keys.
UI_LITERAL_RE = re.compile(
    r'''(?:\b(?:Text|Label|Button|Toggle|Section|SecureField|TextField|Picker|Menu|LabeledContent|ContentUnavailableView)\b|\.(?:help|navigationTitle|alert))\s*\(\s*"((?:[^"\\]|\\.)*)"'''
)
CJK_RE = re.compile(r"[\u3400-\u9fff]")
SKIP_PREFIXES = ("/Users/", "http://", "https://", "openclaw ")


def unescape(s: str) -> str:
    return s.replace('\\"', '"').replace('\\\\', '\\')


def should_keep(s: str) -> bool:
    if not s.strip():
        return False
    if any(s.startswith(prefix) for prefix in SKIP_PREFIXES):
        return False
    return True


def main() -> int:
    hits: list[tuple[pathlib.Path, int, str]] = []

    for swift_file in APP_DIR.rglob("*.swift"):
        text = swift_file.read_text(encoding="utf-8", errors="ignore")
        for m in UI_LITERAL_RE.finditer(text):
            raw = unescape(m.group(1))
            if not CJK_RE.search(raw):
                continue
            if not should_keep(raw):
                continue
            line = text.count("\n", 0, m.start()) + 1
            hits.append((swift_file, line, raw))

    if hits:
        print("i18n check failed: found direct CJK UI literals in Swift")
        for path, line, literal in hits[:200]:
            print(f"{path}:{line}: {literal}")
        return 1

    print("i18n check passed")
    print("- no direct CJK UI literals found")
    return 0


if __name__ == "__main__":
    sys.exit(main())

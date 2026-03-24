#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
APP_DIR = ROOT / "ClawdHome"
PATTERN = re.compile(r"L10n\.t\(")


def main() -> int:
    hits: list[tuple[pathlib.Path, int, str]] = []
    for path in APP_DIR.rglob("*.swift"):
        if path.name == "L10n.swift":
            continue
        text = path.read_text(encoding="utf-8", errors="ignore")
        for idx, line in enumerate(text.splitlines(), start=1):
            if PATTERN.search(line):
                hits.append((path, idx, line.strip()))

    if hits:
        print("legacy i18n API check failed: found L10n.t(...) usages")
        for p, ln, content in hits[:200]:
            print(f"{p}:{ln}: {content}")
        return 1

    print("legacy i18n API check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())

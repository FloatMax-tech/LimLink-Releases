#!/usr/bin/env python3
"""Check Apple translation coverage and interpolation arguments without Xcode."""

import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = {"zh-Hans", "zh-Hant", "en", "ja", "ko", "fr", "de", "es", "it"}
CALL = re.compile(r'L10n\.(?:text|message)\(\s*("(?:\\.|[^"\\])*")')
PLACEHOLDER = re.compile(r"\{\d+\}")


def main():
    errors = []
    catalogs = sorted((ROOT / "apple/Shared").rglob("*.xcstrings"))
    catalogs += sorted((ROOT / "apple/LimLink-iOS/ShareExtension").glob("*.xcstrings"))
    if not catalogs:
        errors.append("No shared Apple String Catalogs found")
    keys = set()
    count = 0
    for path in catalogs:
        catalog = json.loads(path.read_text())
        source = catalog["sourceLanguage"]
        for key, entry in catalog["strings"].items():
            if path.name == "Localizable.xcstrings":
                keys.add(key)
            count += 1
            expected = sorted(PLACEHOLDER.findall(key))
            translations = entry.get("localizations", {})
            for language in sorted(LANGUAGES):
                # The source-language key itself is a valid source translation.
                if language == source and language not in translations:
                    continue
                unit = translations.get(language, {}).get("stringUnit", {})
                value = unit.get("value")
                if not isinstance(value, str) or not value.strip():
                    errors.append(f"{path.name}: {key!r}: missing {language}")
                elif sorted(PLACEHOLDER.findall(value)) != expected:
                    errors.append(f"{path.name}: {key!r}: {language} placeholder mismatch")

    source_roots = [
        "apple/Shared", "apple/LimLink-iOS/App", "apple/LimLink-iOS/ShareExtension",
        "apple/LimLink-iOS/Support/Sources", "apple/LimLink-mac/App", "apple/LimLink-mac/Sources",
    ]
    for source_root in source_roots:
        for path in sorted((ROOT / source_root).rglob("*.swift")):
            text = path.read_text()
            for match in CALL.finditer(text):
                try:
                    key = json.loads(match[1])
                except json.JSONDecodeError:
                    errors.append(f"{path.relative_to(ROOT)}: unsupported dynamic localization key {match[1]}")
                    continue
                if key not in keys:
                    line = text.count("\n", 0, match.start()) + 1
                    errors.append(f"{path.relative_to(ROOT)}:{line}: missing catalog key {key!r}")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Validated {count} catalog entries across {len(catalogs)} catalogs and {len(LANGUAGES)} languages; source keys and placeholders match.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

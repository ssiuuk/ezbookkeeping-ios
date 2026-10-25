#!/usr/bin/env python3
"""Checks that every string the app shows is translated.

The Swift compiler lists the localizable strings it finds (Text("..."), String(localized: "...") and so on) in
.stringsdata files next to the build products when SWIFT_EMIT_LOC_STRINGS is on. This compares them with
EzBookkeeping/Resources/Localizable.xcstrings and prints each string that is missing from it or lacks a language.

    python3 scripts/check-strings.py <DerivedData folder> [--add]

--add puts the missing strings into the catalog, in English only, ready to be translated.
"""
import glob
import json
import os
import sys

CATALOG = os.path.join(os.path.dirname(__file__), "..", "EzBookkeeping", "Resources", "Localizable.xcstrings")
LANGUAGES = ["de", "el", "es", "fr", "it", "ja", "kn", "ko", "nl", "pl", "pt", "ro", "ru", "sl", "ta", "th", "tr", "uk",
             "vi", "zh-Hans", "zh-Hant"]


def extracted_keys(derived_data):
    keys = {}

    for path in glob.glob(os.path.join(derived_data, "**", "*.stringsdata"), recursive=True):
        with open(path, encoding="utf-8") as file:
            data = json.load(file)

        for entry in data.get("tables", {}).get("Localizable", []):
            key = entry.get("key")

            if key:
                keys.setdefault(key, entry.get("comment") or "")

    return keys


def translated(entry, language):
    unit = entry.get("localizations", {}).get(language)
    return bool(unit) and ("stringUnit" in unit or "variations" in unit)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2

    keys = extracted_keys(sys.argv[1])

    if not keys:
        print("::error::No .stringsdata files were found; is SWIFT_EMIT_LOC_STRINGS on?")
        return 1

    with open(CATALOG, encoding="utf-8") as file:
        catalog = json.load(file)

    strings = catalog.setdefault("strings", {})
    missing = sorted(key for key in keys if key not in strings)
    untranslated = sorted(key for key, entry in strings.items()
                          if key in keys and entry.get("shouldTranslate", True)
                          and not all(translated(entry, language) for language in LANGUAGES))
    unused = sorted(key for key in strings if key not in keys)

    print(f"{len(keys)} strings in the code, {len(strings)} in the catalog")

    for key in missing:
        print("::warning::Not in Localizable.xcstrings: " + json.dumps(key, ensure_ascii=False))

    for key in untranslated:
        print("::warning::Not translated into every language: " + json.dumps(key, ensure_ascii=False))

    for key in unused:
        print("No longer used: " + json.dumps(key, ensure_ascii=False))

    if "--add" in sys.argv and missing:
        for key in missing:
            strings[key] = {"comment": keys[key]} if keys[key] else {}

        with open(CATALOG, "w", encoding="utf-8") as file:
            json.dump(catalog, file, ensure_ascii=False, indent=2, sort_keys=True)
            file.write("\n")

    return 1 if missing or untranslated else 0


if __name__ == "__main__":
    sys.exit(main())

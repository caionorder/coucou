#!/usr/bin/env bash
# Checks the Mac app's String Catalog (NotchBuddy/Resources/Localizable.xcstrings):
#  - every text the code can show (see scripts/extract-strings.py) is a key of the catalog;
#  - every such key has a pt-BR value, unless the catalog marks it shouldTranslate = false;
#  - every pt-BR value keeps the format placeholders of its key (%@, %lld, ...);
#  - the extractor finds the String(localized:) / SwiftUI keys it is supposed to (sanity check).
# Needs only python3.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 scripts/extract-strings.py --json > "${TMPDIR:-/tmp}/coucou-extracted-keys.json"

python3 - "${TMPDIR:-/tmp}/coucou-extracted-keys.json" <<'PY'
import json, os, re, sys

CATALOG = os.environ.get("LOCALIZATION_CATALOG", "NotchBuddy/Resources/Localizable.xcstrings")
extracted = json.load(open(sys.argv[1], encoding="utf-8"))
catalog = json.load(open(CATALOG, encoding="utf-8"))
strings = catalog["strings"]
failures = []

def norm(key):
    """Compares keys whatever the guessed placeholder type: %@, %lld, %d... all become %#."""
    key = key.replace("%%", "%")
    return re.sub(r"%(?:\d+\$)?(?:l{0,2}|h{0,2})[@dDiufsS]", "%#", key)

def placeholders(text):
    """Conversion letters of the placeholders, positional or not, ignoring %%."""
    text = text.replace("%%", "")
    return sorted(m.group(1) for m in re.finditer(r"%(?:\d+\$)?(?:l{0,2}|h{0,2})([@dDiufsS])", text))

def has_letters(key):
    return re.search(r"[A-Za-z]", re.sub(r"%(?:\d+\$)?(?:l{0,2}|h{0,2})[@dDiufsS]", "", key)) is not None

check = lambda ok, msg: print(("  ok  " if ok else "  FAIL ") + msg) or (None if ok else failures.append(msg))

print("catalog")
check(catalog.get("sourceLanguage") == "en", "source language is en")
by_norm = {}
for key in strings:
    by_norm.setdefault(norm(key), []).append(key)

def lookup(key):
    if key in strings:
        return key
    candidates = by_norm.get(norm(key), [])
    return candidates[0] if candidates else None

used = {}
for key, where in extracted.items():
    cat_key = lookup(key)
    if cat_key is None:
        # texts without letters (numbers, symbols, "%@/%@") need no entry
        if has_letters(key):
            failures.append("missing from the catalog: %r (%s)" % (key, where[0]))
        continue
    used[cat_key] = where[0]

missing_pt = []
lost_placeholders = []
for cat_key, where in sorted(used.items()):
    entry = strings[cat_key]
    if entry.get("shouldTranslate") is False:
        continue
    unit = entry.get("localizations", {}).get("pt-BR", {}).get("stringUnit", {})
    value = unit.get("value", "")
    if not value or unit.get("state") != "translated":
        missing_pt.append((cat_key, where))
        continue
    if placeholders(value) != placeholders(cat_key):
        lost_placeholders.append((cat_key, value, where))

# a status text is told apart by its leading symbol (the Settings status bar colors "❌" in red): keep it
for cat_key, entry in strings.items():
    value = entry.get("localizations", {}).get("pt-BR", {}).get("stringUnit", {}).get("value")
    if value and cat_key[:1] in "❌✓" and value[:1] != cat_key[:1]:
        failures.append("pt-BR value loses the leading symbol: %r -> %r" % (cat_key, value))

# every catalog entry with a translation must also keep its placeholders (used or not)
for cat_key, entry in strings.items():
    value = entry.get("localizations", {}).get("pt-BR", {}).get("stringUnit", {}).get("value")
    if value and placeholders(value) != placeholders(cat_key) and not any(cat_key == k for k, _, _ in lost_placeholders):
        lost_placeholders.append((cat_key, value, "catalog"))

print("keys")
print("  catalog keys:            %d" % len(strings))
print("  keys found in the code:  %d" % len(extracted))
print("  of which with a letter:  %d" % sum(1 for k in extracted if has_letters(k)))
print("  keys without pt-BR:      %d" % len(missing_pt))
print("  placeholder mismatches:  %d" % len(lost_placeholders))
unused = sorted(k for k in strings if k not in used)
if unused:
    print("  note: %d catalog keys are not found by the extractor (compiler-only forms are fine): %s"
          % (len(unused), ", ".join(repr(k) for k in unused[:6]) + (" ..." if len(unused) > 6 else "")))

for key, where in missing_pt:
    failures.append("no pt-BR value: %r (%s)" % (key, where))
for key, value, where in lost_placeholders:
    failures.append("pt-BR value changes the placeholders: %r -> %r (%s)" % (key, value, where))

# the extractor must see the forms the app relies on
for probe in ("Settings…", "Allow", "Language", "Open Coucou", "Connected · %@", "Hermes agents"):
    check(any(norm(k) == norm(probe) for k in extracted), "extractor finds %r" % probe)

# extractor behaviour on small synthetic sources
import importlib.util
spec = importlib.util.spec_from_file_location("extract_strings", "scripts/extract-strings.py")
ex = importlib.util.module_from_spec(spec); spec.loader.exec_module(ex)
def keys_of(src):
    return sorted(k for k, _ in ex.Scanner(src).scan())

print("extractor probes")
check("Uploading %@" in keys_of('Text("Uploading \\(state.file?.name ?? String(localized: "file"))")'),
      "keeps the outer key when an interpolation holds String(localized:)")
check(keys_of('Text(ok ? String(localized: "Yes") : "path/to")') == ["Yes"],
      "a String(localized:) at the argument level still disables extraction of the other literals")
check(keys_of('var advanceKey: LocalizedStringKey { isLast ? "Send" : "Next" }') == ["Next", "Send"],
      "extracts the literals of a LocalizedStringKey property")
check(keys_of('func title(_ n: Int) -> LocalizedStringKey {\n    n == 1 ? "One" : "Many"\n}') == ["Many", "One"],
      "extracts the literals of a function returning LocalizedStringKey")
check(keys_of('let k: LocalizedStringKey = "Constant"\nlet other = "not a key"') == ["Constant"],
      "extracts a LocalizedStringKey constant and ignores plain strings")
check(keys_of('var plain: String { "not a key" }') == [],
      "ignores a String property")
check(keys_of('String(localized: "\\(String(n)) items")') == ["%@ items"],
      "a number wrapped in String() is a %@ placeholder")
check(keys_of('Text(verbatim: "raw")') == [], "Text(verbatim:) is skipped")

if failures:
    print("\n%d failure(s):" % len(failures))
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("\nAll localization tests passed.")
PY

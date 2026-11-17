#!/usr/bin/env python3
"""Count the App Store Connect fields in listing.md against Apple's limits.

Each counted field is a level-3 heading followed by a ```text block. Characters are
Python len(); the keyword field is also measured in UTF-8 bytes, which is what
App Store Connect limits.  Run: python3 appstore/listing/count.py
"""
import pathlib
import re
import sys

LIMITS = {
    "Name": 30,
    "Subtitle": 30,
    "Promotional Text": 170,
    "Description": 4000,
    "Keywords": 100,
    "App Review Notes": 4000,
}

text = (pathlib.Path(__file__).parent / "listing.md").read_text()
fields = dict(re.findall(r"^### ([^\n]+)\n+```text\n(.*?)\n```", text, re.S | re.M))

ok = True
for name, limit in LIMITS.items():
    value = fields.get(name)
    if value is None:
        print(f"{name}: missing")
        ok = False
        continue
    size = len(value.encode()) if name == "Keywords" else len(value)
    unit = "bytes" if name == "Keywords" else "chars"
    flag = "ok" if size <= limit else "OVER"
    ok &= size <= limit
    print(f"{name}: {size} / {limit} {unit} {flag}")

keywords = fields.get("Keywords", "")
words = keywords.split(",")
if any(w != w.strip() or not w for w in words):
    print("Keywords: empty entry or space around a comma")
    ok = False
taken = set(re.findall(r"[a-z0-9]+", (fields.get("Name", "") + " " + fields.get("Subtitle", "")).lower()))
repeats = [w for w in words if set(re.findall(r"[a-z0-9]+", w.lower())) & taken]
if repeats:
    print("Keywords repeating the name or subtitle:", ", ".join(repeats))
    ok = False
print(f"Keywords: {len(words)} terms")
for bad in ("**", "# ", "](", "`"):
    if bad in fields.get("Description", ""):
        print(f"Description contains markdown {bad!r}")
        ok = False
sys.exit(0 if ok else 1)

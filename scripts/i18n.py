#!/usr/bin/env python3
"""Porthole localization tool.

Translations live in Localization/<lang>.json as {"English key": "translation"}.
A plural entry is an object such as {"one": "%lld tunnel", "other": "%lld tunnels"}
(CLDR categories: zero, one, two, few, many, other).

  scripts/i18n.py extract            rebuild with the compiler's string extraction, write Localization/keys.json
  scripts/i18n.py check              report missing/extra keys and placeholder mismatches (exit 1 on errors)
  scripts/i18n.py compile <dir>      write <dir>/<lang>.lproj/Localizable.strings(+.stringsdict)
"""
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOC = ROOT / "Localization"
KEYS = LOC / "keys.json"

# Keys that read the same in every language.
NEUTRAL = {"%lld", "/usr/bin/ssh", "Porthole", "OpenSSH", "localhost", "~/.ssh/id_ed25519", "SOCKS"}

SPEC = re.compile(r"%(?:(\d+)\$)?(lld|ld|d|@|lf|f)")


def languages():
    return sorted(p.stem for p in LOC.glob("*.json") if p.stem != "keys")


def load(lang):
    return json.loads((LOC / f"{lang}.json").read_text(encoding="utf-8"))


def specs(s):
    """Placeholder types in argument order (positional specifiers re-ordered)."""
    found = SPEC.findall(s)
    if any(pos for pos, _ in found):
        ordered = sorted(found, key=lambda m: int(m[0] or 0))
        return [t for _, t in ordered]
    return [t for _, t in found]


def extract():
    with tempfile.TemporaryDirectory() as tmp:
        data = Path(tmp) / "data"
        data.mkdir()
        cmd = ["swift", "build", "--scratch-path", str(Path(tmp) / "build"),
               "-Xswiftc", "-emit-localized-strings", "-Xswiftc", "-emit-localized-strings-path", "-Xswiftc", str(data)]
        subprocess.run(cmd, cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
        keys = set()
        for f in data.glob("*.stringsdata"):
            for entries in json.loads(f.read_text()).get("tables", {}).values():
                keys.update(e["key"] for e in entries)
    keys = sorted(k for k in keys if re.search("[A-Za-z]", k))
    KEYS.write_text(json.dumps(keys, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(keys)} keys -> {KEYS.relative_to(ROOT)}")


def check():
    keys = json.loads(KEYS.read_text())
    keyset = set(keys)
    errors = 0
    for lang in languages():
        table = load(lang)
        missing = [k for k in keys if k not in table and k not in NEUTRAL] if lang != "en" else []
        extra = [k for k in table if k not in keyset]
        bad = []
        for k, v in table.items():
            forms = v.values() if isinstance(v, dict) else [v]
            for form in forms:
                if sorted(specs(form)) != sorted(specs(k)):
                    bad.append((k, form))
        status = "ok" if not (missing or bad) else "ERROR"
        print(f"{lang:8} {len(table):4} entries  missing={len(missing)} extra={len(extra)} placeholder-mismatch={len(bad)}  {status}")
        for k in missing[:20]:
            print(f"    missing: {k}")
        for k in extra[:20]:
            print(f"    unused:  {k}")
        for k, form in bad[:20]:
            print(f"    placeholders differ: {k!r} -> {form!r}")
        errors += len(missing) + len(bad)
    sys.exit(1 if errors else 0)


def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def compile_to(out_dir):
    out = Path(out_dir)
    for lang in languages():
        table = load(lang)
        lproj = out / f"{lang}.lproj"
        lproj.mkdir(parents=True, exist_ok=True)
        lines, plurals = [], {}
        for k in sorted(table):
            v = table[k]
            if isinstance(v, dict):
                if set(v) == {"other"}:
                    lines.append(f'"{escape(k)}" = "{escape(v["other"])}";')
                else:
                    plurals[k] = v
            else:
                lines.append(f'"{escape(k)}" = "{escape(v)}";')
        (lproj / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
        if plurals:
            sd = {}
            for k, forms in plurals.items():
                spec = specs(k)[0] if specs(k) else "lld"
                rule = {"NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": spec}
                # Every plural key has a single %lld; each form is the whole sentence.
                rule.update(forms)
                sd[k] = {"NSStringLocalizedFormatKey": "%#@count@", "count": rule}
            with open(lproj / "Localizable.stringsdict", "wb") as f:
                plistlib.dump(sd, f)
        elif (lproj / "Localizable.stringsdict").exists():
            (lproj / "Localizable.stringsdict").unlink()
    print(f"compiled {len(languages())} languages into {out}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    if cmd == "extract":
        extract()
    elif cmd == "check":
        check()
    elif cmd == "compile" and len(sys.argv) > 2:
        compile_to(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)

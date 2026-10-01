#!/usr/bin/env python3
"""Supabase'e özgü kısıtları migrationlarda statik olarak denetler.
- pg_safeupdate: API isteklerinde WHERE'siz UPDATE/DELETE reddedilir."""
import glob, re, sys
bad = []
for f in sorted(glob.glob("supabase/migrations/*.sql")):
    s = open(f, encoding="utf-8").read()
    for m in re.finditer(r"\b(update\s+[\w\.]+\s+set\b|delete\s+from\s+[\w\.]+)[^;]*;", s, re.S | re.I):
        if not re.search(r"\bwhere\b", m.group(0), re.I):
            bad.append(f"{f}:{s[:m.start()].count(chr(10)) + 1}: WHERE'siz {m.group(1).split()[0].upper()} (pg_safeupdate reddeder)")
print("\n".join(bad) if bad else "SQL denetimi: sorun yok")
sys.exit(1 if bad else 0)

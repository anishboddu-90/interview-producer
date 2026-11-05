#!/usr/bin/env python3
"""Scan only tracked distributable files. Private deny terms can be supplied outside Git."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

parser=argparse.ArgumentParser()
parser.add_argument("--deny-file",type=Path,help="Private JSON array of terms; never print the matched values")
args=parser.parse_args()
root=Path(__file__).resolve().parents[1]
paths=subprocess.check_output(["git","ls-files","-z"],cwd=root).decode().split("\0")
terms=json.loads(args.deny_file.read_text()) if args.deny_file else []
patterns=[re.compile(rb'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|sk-[A-Za-z0-9_-]{30,})\b'),re.compile(rb'/(?:Users|home)/[A-Za-z0-9_.-]+/')]
failures=[]
for name in filter(None,paths):
    path=root/name
    if not path.exists():continue
    if any(part in {".build","dist",".venv","__pycache__","PersonalMemoryImport"} for part in path.parts) or path.suffix.lower() in {".sqlite",".db",".caf",".zip",".aiff"} or path.name in {".env","settings.json","profiles.json","research.json"}:
        failures.append((name,"private/build artifact"));continue
    data=path.read_bytes()
    if any(pattern.search(data) for pattern in patterns):failures.append((name,"credential or absolute home path pattern"))
    lowered=data.lower()
    if any(term.encode().lower() in lowered for term in terms):failures.append((name,"private deny-term match"))
if failures:
    for name,reason in failures:print(f"FAIL: {name}: {reason}")
    sys.exit(1)
print(f"PASS: {len(list(filter(None,paths)))} tracked files checked for private artifacts, credential patterns and configured deny terms.")

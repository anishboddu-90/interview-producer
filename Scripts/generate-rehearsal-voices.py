#!/usr/bin/env python3
"""Generate fictional macOS speech; nothing is played or recorded from a microphone."""
import argparse, json, pathlib, subprocess
p = argparse.ArgumentParser()
p.add_argument("output", type=pathlib.Path)
p.add_argument("--voice", default="Samantha")
args = p.parse_args()
manifest = json.loads((pathlib.Path(__file__).resolve().parents[1] / "Tests/Fixtures/Rehearsal/manifest.json").read_text())
args.output.mkdir(parents=True, exist_ok=True)
for turn in manifest:
    wav = args.output / turn["file"]
    aiff = wav.with_suffix(".aiff")
    subprocess.run(["/usr/bin/say", "-v", args.voice, "-r", "170", "-o", str(aiff), turn["text"]], check=True)
    subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)], check=True)
    aiff.unlink()
(args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("Generated five synthetic speech WAVs in", args.output.resolve())

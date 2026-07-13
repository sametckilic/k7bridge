#!/usr/bin/env python3
import argparse, hashlib, json, pathlib, sys

parser = argparse.ArgumentParser(description="Create an AudioBridge gate only from a completed physical-device report")
parser.add_argument("report", type=pathlib.Path)
parser.add_argument("--output", type=pathlib.Path, default=pathlib.Path("audio-gate.json"))
args = parser.parse_args()
raw = args.report.read_bytes()
report = json.loads(raw)
required_true = ("downlinkCaptured", "uplinkReplaced", "remotePartyHeardInjectedAudio", "noProcessCrash")
errors = [key for key in required_true if report.get(key) is not True]
if report.get("durationSeconds", 0) < 1800: errors.append("durationSeconds>=1800")
if not report.get("deviceBuild") or not report.get("hookArtifactSHA256"): errors.append("deviceBuild/hookArtifactSHA256")
if errors:
    print("Audio gate rejected: " + ", ".join(errors), file=sys.stderr)
    raise SystemExit(2)
gate = {
    "passed": True,
    "deviceBuild": report["deviceBuild"],
    "hookArtifactSHA256": report["hookArtifactSHA256"],
    "reportSHA256": hashlib.sha256(raw).hexdigest(),
    "durationSeconds": report["durationSeconds"]
}
args.output.write_text(json.dumps(gate, indent=2) + "\n")
print(args.output)


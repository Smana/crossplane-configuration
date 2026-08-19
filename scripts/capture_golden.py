#!/usr/bin/env python3
"""Capture golden render output from cloud-native-ref's OCI-sourced Compositions.

Run ONCE, before the old Compositions go away. The output becomes the contract
that scripts/render_check.py enforces forever after: the extraction is correct
if and only if the inlined Compositions reproduce these bytes.

Usage: CNR=/path/to/cloud-native-ref python3 scripts/capture_golden.py
"""
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "tests" / "golden"

# example file -> the OLD composition filename in cloud-native-ref
EXAMPLES = {
    "app-basic.yaml": "app-composition.yaml",
    "app-complete.yaml": "app-composition.yaml",
    "app-worker.yaml": "app-composition.yaml",
    "app-cron.yaml": "app-composition.yaml",
    "sqlinstance-basic.yaml": "sql-instance-composition.yaml",
    "sqlinstance-complete.yaml": "sql-instance-composition.yaml",
    "epi.yaml": "epi-composition.yaml",
    "inferenceservice-basic.yaml": "inference-service-composition.yaml",
    "inferenceservice-complete.yaml": "inference-service-composition.yaml",
    "inferenceservice-endpointpicker.yaml": "inference-service-composition.yaml",
    "kvstore-basic.yaml": "kvstore-composition.yaml",
    "kvstore-complete.yaml": "kvstore-composition.yaml",
}


def main() -> int:
    cnr = os.environ.get("CNR")
    if not cnr:
        print("error: set CNR to the cloud-native-ref checkout path", file=sys.stderr)
        return 2
    cfg = pathlib.Path(cnr) / "infrastructure/base/crossplane/configuration"
    if not cfg.is_dir():
        print(f"error: {cfg} is not a directory", file=sys.stderr)
        return 2

    GOLDEN.mkdir(parents=True, exist_ok=True)
    failures = 0
    for example, composition in EXAMPLES.items():
        proc = subprocess.run(
            ["crossplane", "render", f"examples/{example}", composition, "functions.yaml",
             "--extra-resources", "examples/environmentconfig.yaml"],
            cwd=cfg, capture_output=True, text=True,
        )
        if proc.returncode != 0:
            print(f"FAIL  {example}\n{proc.stderr}", file=sys.stderr)
            failures += 1
            continue
        out = GOLDEN / example
        out.write_text(proc.stdout)
        # len() on a str from text=True counts CHARACTERS. The inference-service
        # renders carry 8 non-ASCII bytes each, so reporting len() labelled "B"
        # understates them by 8 and makes an identical capture look like a drift.
        print(f"captured {example:<40} {out.stat().st_size:>6} B")

    print(f"\n{len(EXAMPLES) - failures}/{len(EXAMPLES)} captured")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

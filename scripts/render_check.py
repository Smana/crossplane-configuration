#!/usr/bin/env python3
"""Render every claim example through the inlined Compositions and diff against golden.

Examples are enumerated from disk rather than hardcoded, so a new example cannot
be silently untested - which is how inferenceservice-endpointpicker.yaml went
unrendered in cloud-native-ref's validator.
"""
import difflib
import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "tests" / "golden"
EXAMPLES = ROOT / "examples"

# environmentconfig.yaml is an --extra-resources input, not a claim.
NOT_A_CLAIM = {"environmentconfig.yaml"}


def composition_for(kind: str) -> pathlib.Path:
    """Find the Composition whose compositeTypeRef matches this claim's kind."""
    for comp in sorted(ROOT.glob("apis/*/composition.yaml")):
        doc = yaml.safe_load(comp.read_text())
        if doc["spec"]["compositeTypeRef"]["kind"] == kind:
            return comp
    raise SystemExit(f"no Composition found for kind {kind}")


def main() -> int:
    examples = sorted(p for p in EXAMPLES.glob("*.yaml") if p.name not in NOT_A_CLAIM)
    if not examples:
        raise SystemExit("no examples found")

    missing = [p.name for p in examples if not (GOLDEN / p.name).exists()]
    if missing:
        raise SystemExit(
            f"no golden fixture for: {', '.join(missing)}\n"
            "Every example must have one. Capture it or delete the example."
        )
    orphans = [p.name for p in GOLDEN.glob("*.yaml") if not (EXAMPLES / p.name).exists()]
    if orphans:
        raise SystemExit(f"golden fixture with no example: {', '.join(orphans)}")

    failures = 0
    for example in examples:
        kind = yaml.safe_load(example.read_text())["kind"]
        comp = composition_for(kind)
        proc = subprocess.run(
            ["crossplane", "render", f"examples/{example.name}",
             str(comp.relative_to(ROOT)), "functions.yaml",
             "--extra-resources", "examples/environmentconfig.yaml"],
            cwd=ROOT, capture_output=True, text=True,
        )
        if proc.returncode != 0:
            print(f"ERROR  {example.name}\n{proc.stderr}", file=sys.stderr)
            failures += 1
            continue
        want = (GOLDEN / example.name).read_text()
        if proc.stdout == want:
            print(f"MATCH  {example.name:<40} {(GOLDEN / example.name).stat().st_size:>6} B")
        else:
            print(f"DIFFER {example.name}", file=sys.stderr)
            sys.stderr.writelines(difflib.unified_diff(
                want.splitlines(keepends=True), proc.stdout.splitlines(keepends=True),
                fromfile="golden", tofile="rendered"))
            failures += 1

    print(f"\n{len(examples) - failures}/{len(examples)} match")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())

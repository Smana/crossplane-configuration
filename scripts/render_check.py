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


def composition_for(example: pathlib.Path, kind: str) -> pathlib.Path:
    """Find the Composition whose compositeTypeRef matches this claim's kind.

    An API directory may ship one Composition per cloud (composition-aws.yaml,
    composition-gcp.yaml) rather than a single composition.yaml -- see Task 3's
    build-machinery change. Several files can share the same compositeTypeRef.kind,
    so kind alone no longer picks a unique file.

    Claims are deliberately cloud-neutral (that is the whole point of this
    package), so the claim's own content cannot disambiguate. Resolve by the
    EXAMPLE'S FILENAME instead: a "-gcp" marker selects the Composition labelled
    `provider: gcp`; anything else selects the non-gcp one. This used to be
    "sorted() picks the alphabetically-first match", which only ever worked
    because every example happened to be AWS-shaped and "aws" < "gcp" -- true by
    coincidence, not by selection, and it broke the moment a GCP-shaped example
    (examples/app-gcp-objectstore.yaml) was added.
    """
    candidates = [
        comp for comp in sorted(ROOT.glob("apis/*/composition*.yaml"))
        if yaml.safe_load(comp.read_text())["spec"]["compositeTypeRef"]["kind"] == kind
    ]
    if not candidates:
        raise SystemExit(f"no Composition found for kind {kind}")
    if len(candidates) == 1:
        return candidates[0]

    wantProvider = "gcp" if "-gcp" in example.stem else "aws"
    for comp in candidates:
        provider = (yaml.safe_load(comp.read_text()).get("metadata", {}).get("labels", {}) or {}).get("provider")
        if provider == wantProvider:
            return comp
    raise SystemExit(
        f"no provider={wantProvider!r}-labelled Composition found for kind {kind} "
        f"among {[str(c.relative_to(ROOT)) for c in candidates]}"
    )


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
        comp = composition_for(example, kind)
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

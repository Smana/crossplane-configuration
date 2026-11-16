#!/usr/bin/env python3
"""Validate every composed resource in tests/golden/ against its schema.

`task render` proves the Compositions reproduce the goldens byte for byte, so
validating the goldens is validating what the Compositions emit. Neither that
diff nor `task schema` (claims only) would notice a composed Deployment the
apiserver rejects.

Requires build/schemas from `task schema`, and flux with the schema plugin.
"""
import os
import pathlib
import shutil
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
GOLDEN = ROOT / "tests" / "golden"
EXAMPLES = ROOT / "examples"
CRDS = ROOT / "tests" / "crds"
XRD_SCHEMAS = ROOT / "build" / "schemas"
VENDORED_SCHEMAS = ROOT / "build" / "schemas-vendored"
RENDERED = ROOT / "build" / "rendered"

FLUX = os.environ.get("FLUX_BIN", "flux")


def split_docs(text: str) -> list[str]:
    docs, cur = [], []
    for line in text.splitlines(keepends=True):
        if line.rstrip("\n") == "---":
            if cur:
                docs.append("".join(cur))
            cur = []
        else:
            cur.append(line)
    if cur:
        docs.append("".join(cur))
    return [d for d in docs if d.strip()]


def strip_xr(golden: pathlib.Path) -> str:
    """Drop the leading XR: render output carries it without spec, so it fails its own XRD.

    The kind is asserted so a change in render order cannot silently drop a
    composed resource instead.
    """
    want = yaml.safe_load((EXAMPLES / golden.name).read_text())["kind"]
    docs = split_docs(golden.read_text())
    got = (yaml.safe_load(docs[0]) or {}).get("kind")
    if got != want:
        raise SystemExit(f"{golden.name}: first document is {got!r}, expected the {want} XR")
    return "".join("---\n" + d for d in docs[1:])


def main() -> int:
    if not any(XRD_SCHEMAS.rglob("*.json")):
        raise SystemExit(f"no XRD schemas under {XRD_SCHEMAS.relative_to(ROOT)}; run `task schema` first")

    crds = sorted(CRDS.glob("*.yaml"))
    shutil.rmtree(VENDORED_SCHEMAS, ignore_errors=True)
    subprocess.run([FLUX, "schema", "extract", "crd", *map(str, crds), "-d", str(VENDORED_SCHEMAS)],
                   check=True, stdout=subprocess.DEVNULL)
    # `extract crd` exits 0 having written nothing when an input holds no CRD.
    if len(list(VENDORED_SCHEMAS.rglob("*.json"))) < len(crds):
        raise SystemExit(f"fewer schemas extracted than the {len(crds)} vendored CRD file(s)")

    goldens = sorted(GOLDEN.glob("*.yaml"))
    if not goldens:
        raise SystemExit("no golden fixtures found")
    shutil.rmtree(RENDERED, ignore_errors=True)
    RENDERED.mkdir(parents=True)
    for g in goldens:
        (RENDERED / g.name).write_text(strip_xr(g))

    # No --skip-missing-schemas: a composed kind with no schema must fail, or
    # it goes unvalidated forever. Local schemas come first so the pinned CRD
    # versions win over whatever the hosted catalogs carry.
    cmd = [FLUX, "schema", "validate", str(RENDERED.relative_to(ROOT)),
           "--schema-location", str(XRD_SCHEMAS.relative_to(ROOT)),
           "--schema-location", str(VENDORED_SCHEMAS.relative_to(ROOT)),
           "--schema-location", "default",
           "--schema-location", "ecosystem"]
    print(f"==> Validating composed resources from {len(goldens)} golden fixture(s)", flush=True)
    return subprocess.run(cmd, cwd=ROOT).returncode


if __name__ == "__main__":
    sys.exit(main())

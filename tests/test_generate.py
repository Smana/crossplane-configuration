import pathlib
import subprocess
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
APIS = ["app", "sqlinstance", "kvstore", "inferenceservice", "epi"]


def _source_of(api: str) -> str:
    doc = yaml.safe_load((ROOT / "apis" / api / "composition.yaml").read_text())
    for step in doc["spec"]["pipeline"]:
        spec = (step.get("input") or {}).get("spec") or {}
        if "source" in spec:
            return spec["source"]
    raise AssertionError(f"no KCL step found in {api}")


def test_generate_inlines_every_module():
    """After generate, no Composition may reference an OCI module."""
    subprocess.run([sys.executable, "scripts/generate.py"], cwd=ROOT, check=True)
    for api in APIS:
        assert not _source_of(api).startswith("oci://"), f"{api} still OCI-sourced"


def test_inlined_source_is_byte_identical_to_main_k():
    """The embedded copy must equal main.k exactly - no reformatting, no trimming."""
    subprocess.run([sys.executable, "scripts/generate.py"], cwd=ROOT, check=True)
    for api in APIS:
        main_k = (ROOT / "apis" / api / "kcl" / "main.k").read_text()
        assert _source_of(api) == main_k, f"{api} source drifted from main.k"


def test_generate_is_idempotent():
    """Running generate twice must not change the file - CI relies on this."""
    subprocess.run([sys.executable, "scripts/generate.py"], cwd=ROOT, check=True)
    first = {a: (ROOT / "apis" / a / "composition.yaml").read_bytes() for a in APIS}
    subprocess.run([sys.executable, "scripts/generate.py"], cwd=ROOT, check=True)
    for api in APIS:
        assert (ROOT / "apis" / api / "composition.yaml").read_bytes() == first[api], api

#!/usr/bin/env python3
"""Inline each KCL module into its Composition.

`apis/<api>/kcl/main.k` is the source of truth. This rewrites the KCL pipeline
step's `input.spec.source` with the module's contents as a literal block scalar,
so the published Composition is self-contained and function-kcl pulls nothing at
render time.

Idempotent: the previous value of `source` is always discarded, so running this
against an already-generated file is a no-op.
"""
import pathlib
import sys

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]

# api directory -> KCL module directory name (they differ for three APIs, because
# the modules were named after their implementation and the APIs after their kind).
MODULE = {
    "app": "app",
    "sqlinstance": "cloudnativepg",
    "kvstore": "kvstore",
    "inferenceservice": "inference-service",
    "epi": "eks-pod-identity",
}


class Literal(str):
    """A str that PyYAML emits as a `|` block scalar."""


def _repr_literal(dumper, data):
    return dumper.represent_scalar("tag:yaml.org,2002:str", str(data), style="|")


yaml.add_representer(Literal, _repr_literal)


def inline_composition(comp_path: pathlib.Path) -> str:
    """Rewrite comp_path with its KCL inlined. Returns the module directory name."""
    api = comp_path.parent.name
    module = MODULE[api]
    main_k = (comp_path.parent / "kcl" / "main.k").read_text()

    doc = yaml.safe_load(comp_path.read_text())
    hits = 0
    for step in doc["spec"]["pipeline"]:
        spec = (step.get("input") or {}).get("spec") or {}
        if "source" not in spec:
            continue
        spec["source"] = Literal(main_k)
        hits += 1
    if hits != 1:
        raise SystemExit(f"{comp_path}: expected exactly 1 KCL step, found {hits}")

    out = yaml.dump(doc, default_flow_style=False, width=10**9,
                    allow_unicode=True, sort_keys=False)

    # A block scalar cannot represent trailing whitespace; PyYAML silently falls
    # back to a quoted style, which would still parse but would stop being
    # reviewable. Prove the round-trip instead of trusting it.
    back = yaml.safe_load(out)
    for step in back["spec"]["pipeline"]:
        spec = (step.get("input") or {}).get("spec") or {}
        if "source" in spec and spec["source"] != main_k:
            raise SystemExit(
                f"{comp_path}: source did not survive the YAML round-trip. "
                "Check main.k for trailing whitespace."
            )

    comp_path.write_text(out)
    return module


def main() -> int:
    for comp in sorted(ROOT.glob("apis/*/composition.yaml")):
        module = inline_composition(comp)
        size = comp.stat().st_size
        print(f"{comp.relative_to(ROOT)}  <- apis/{comp.parent.name}/kcl/main.k "
              f"(module {module}, {size} B)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

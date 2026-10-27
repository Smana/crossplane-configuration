"""A parent's rule never compares a child object or array with oldSelf.

On gcp-0 (2026-10-27) the apiserver priced `self.loop == oldSelf.loop`, a spec rule comparing the
loop object, at more than 100x the CEL cost budget and refused the CRD Crossplane renders, so the
AgentRun XRD never established. The same comparison written on the field itself (`self ==
oldSelf` on loop, as task and egress hold theirs) was accepted. Nothing offline runs the
apiserver's estimate, so this holds the shape the apiserver accepted.
"""

import pathlib
import re

import yaml

ROOT = pathlib.Path(__file__).resolve().parent.parent
EQ = re.compile(r"\bself((?:\.[A-Za-z_][A-Za-z0-9_]*)*)\s*==\s*oldSelf((?:\.[A-Za-z_][A-Za-z0-9_]*)*)")


def resolve(node, path):
    for part in [p for p in path.split(".") if p]:
        node = (node.get("properties") or {}).get(part)
        if node is None:
            return None
    return node


def offenders(schema, where="spec"):
    found = []
    for rule in schema.get("x-kubernetes-validations") or []:
        for left, right in EQ.findall(rule["rule"]):
            target = resolve(schema, left)
            if left and left == right and target is not None and target.get("type") in ("object", "array"):
                found.append(f"{where}: {rule['rule']}")
    for name, child in (schema.get("properties") or {}).items():
        found += offenders(child, f"{where}.{name}")
    if isinstance(schema.get("items"), dict):
        found += offenders(schema["items"], f"{where}[]")
    return found


def xrd_schemas(text):
    doc = yaml.safe_load(text)
    for version in doc["spec"]["versions"]:
        yield version["name"], version["schema"]["openAPIV3Schema"]


def test_no_transition_rule_compares_a_whole_object_or_array():
    bad = []
    for path in sorted(ROOT.glob("apis/*/definition.yaml")):
        for version, schema in xrd_schemas(path.read_text()):
            bad += [f"{path.relative_to(ROOT)} {version} {o}" for o in offenders(schema)]
    assert not bad, "object or array compared with oldSelf:\n" + "\n".join(bad)


def test_the_check_catches_the_object_comparison():
    schema = {
        "properties": {
            "spec": {
                "x-kubernetes-validations": [{"rule": "!has(self.loop) || self.loop == oldSelf.loop"}],
                "properties": {"loop": {"type": "object", "properties": {"n": {"type": "integer"}}}},
            }
        }
    }
    assert offenders(schema) == ["spec.spec: !has(self.loop) || self.loop == oldSelf.loop"]


def test_the_check_allows_a_field_holding_itself():
    schema = {"type": "object", "x-kubernetes-validations": [{"rule": "self == oldSelf"}]}
    assert offenders(schema) == []

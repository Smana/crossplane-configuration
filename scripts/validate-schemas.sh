#!/usr/bin/env bash
# Validate the example claims against the XRDs this repository ships.
#
# Why this exists
# ---------------
# The packages' whole purpose is to define an API. Without this gate a malformed
# XRD passes CI here, ships in a release, and is only discovered downstream when
# a consumer feeds the published xrd-crds.yaml into its own schema catalog —
# the wrong end of the pipeline, and after the release is already public.
#
# `make test` checks the KCL renders. `make render` checks the output matches the
# golden fixtures. Neither reads the XRD's OpenAPI schema, so neither would catch
# a required field dropped from `definition.yaml`.
#
# It also produces build/xrd-crds.yaml, which is the release asset consumers pin.
# Generating it here rather than in the release workflow means the artifact that
# ships is the same one CI validated against.
#
# Usage:
#   ./scripts/validate-schemas.sh
#
# Requires: flux >= 2.9 with the schema plugin (`flux plugin install schema`).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FLUX_BIN="${FLUX_BIN:-flux}"

if ! command -v "${FLUX_BIN}" >/dev/null 2>&1; then
    echo "error: '${FLUX_BIN}' not found. Install flux >= 2.9, then: flux plugin install schema" >&2
    exit 1
fi

if ! "${FLUX_BIN}" schema --help >/dev/null 2>&1; then
    echo "error: the flux schema plugin is missing. Run: flux plugin install schema" >&2
    exit 1
fi

build_dir="build"
schema_dir="${build_dir}/schemas"
asset="${build_dir}/xrd-crds.yaml"

mkdir -p "${build_dir}"
rm -rf "${schema_dir}"
mkdir -p "${schema_dir}"

echo "==> Converting XRDs to CRDs"
python3 scripts/xrd-to-crd.py apis/*/definition.yaml > "${asset}"

# `flux schema extract crd` exits 0 and writes nothing when handed an input with
# no CRDs in it. Without this count the next step would build an empty catalog,
# validate every claim against nothing, and report success.
crd_count="$(grep -c '^kind: CustomResourceDefinition' "${asset}" || true)"
api_count="$(find apis -maxdepth 2 -name definition.yaml | wc -l | tr -d ' ')"

if [[ "${crd_count}" -ne "${api_count}" ]]; then
    echo "error: converted ${crd_count} CRD(s) from ${api_count} XRD(s) — expected one each" >&2
    exit 1
fi
echo "    ${crd_count} CRD(s) -> ${asset}"

echo "==> Building the schema catalog"
"${FLUX_BIN}" schema extract crd "${asset}" -d "${schema_dir}"

schema_files="$(find "${schema_dir}" -name '*.json' | wc -l | tr -d ' ')"
if [[ "${schema_files}" -ne "${crd_count}" ]]; then
    echo "error: extracted ${schema_files} schema(s) from ${crd_count} CRD(s)" >&2
    exit 1
fi

echo "==> Validating example claims against the shipped XRDs"
# environmentconfig.yaml is an --extra-resources input to `crossplane render`,
# not a claim, and its Kind is not one this repo defines.
claims=()
while IFS= read -r f; do
    [[ "$(basename "$f")" == "environmentconfig.yaml" ]] && continue
    claims+=("$f")
done < <(find examples -maxdepth 1 -name '*.yaml' | sort)

if [[ "${#claims[@]}" -eq 0 ]]; then
    echo "error: no example claims found under examples/" >&2
    exit 1
fi

# --skip-missing-schemas is deliberately NOT passed. It defaults to off, and off
# is what we want: an unrecognised Kind here means an example references an API
# this repo does not ship, which is a real error rather than something to skip.
# This is the same property `.fluxschema.yml` pins in cloud-native-ref, and the
# reason SPEC-007 was written — kubeconform ran with -ignore-missing-schemas and
# every cloud.ogenki.io claim went unvalidated for the life of that repo.
#
# Only this repo's own schemas are given: no 'default', no 'ecosystem'. The
# examples are claims for APIs defined here, so a lookup that falls through to a
# hosted catalog would mean the local XRD did not match, and should fail.
"${FLUX_BIN}" schema validate \
    --schema-location "${schema_dir}" \
    "${claims[@]}"

echo ""
echo "==> ${#claims[@]} example claim(s) valid against ${crd_count} shipped XRD(s)"

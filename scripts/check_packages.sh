#!/usr/bin/env bash
# Inspect the built .xpkg files and assert what they actually ship.
#
# `make build` exiting 0 only says crossplane accepted the input. It does not say
# the package contains the resources we think, and it does not say the KCL was
# inlined — a package that still carried `oci://` would build fine and then need
# network access to a registry this repo does not control, at render time on
# someone else's cluster. That is the failure the extraction exists to remove, so
# it is asserted rather than assumed.
#
# An .xpkg is an OCI image tarball: the layer holding package.yaml is a nested
# .tar.gz, so this extracts rather than greps the outer archive.

set -euo pipefail
cd "$(dirname "$0")/.."

declare -A EXPECT_XRD=([core]=4 [aws]=1)
declare -A EXPECT_COMP=([core]=1 [aws]=4)

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

for pkg in core aws; do
    xpkg="build/crossplane-configuration-${pkg}.xpkg"
    [[ -f "${xpkg}" ]] || { echo "error: ${xpkg} not found — run 'make build'" >&2; exit 1; }

    dir="${tmp}/${pkg}"
    mkdir -p "${dir}"
    tar -xf "${xpkg}" -C "${dir}"

    # The package.yaml lives in one of the layers; find it rather than guessing.
    found=""
    for layer in "${dir}"/*.tar.gz; do
        if tar -tzf "${layer}" 2>/dev/null | grep -qx 'package.yaml'; then
            tar -xzf "${layer}" -C "${dir}" package.yaml
            found="${dir}/package.yaml"
            break
        fi
    done
    [[ -n "${found}" ]] || { echo "error: no package.yaml layer in ${xpkg}" >&2; exit 1; }

    if grep -q 'oci://' "${found}"; then
        echo "error: crossplane-configuration-${pkg} still references an OCI module:" >&2
        grep -n 'oci://' "${found}" | head -5 >&2
        exit 1
    fi

    xrds="$(grep -c '^kind: CompositeResourceDefinition' "${found}" || true)"
    comps="$(grep -c '^kind: Composition' "${found}" || true)"

    if [[ "${xrds}" -ne "${EXPECT_XRD[$pkg]}" || "${comps}" -ne "${EXPECT_COMP[$pkg]}" ]]; then
        echo "error: crossplane-configuration-${pkg} ships ${xrds} XRD(s) and ${comps} Composition(s);" >&2
        echo "       expected ${EXPECT_XRD[$pkg]} and ${EXPECT_COMP[$pkg]}. Check scripts/assemble.sh." >&2
        exit 1
    fi

    echo "crossplane-configuration-${pkg}: ${xrds} XRD(s), ${comps} Composition(s), no OCI references"
done

echo ""
echo "==> both packages are self-contained"

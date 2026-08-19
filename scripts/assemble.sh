#!/usr/bin/env bash
# Stage a clean build root per package. crossplane xpkg build recurses through
# --package-root and --ignore cannot exclude directories, so the KCL sources and
# the other package's files must simply not be there.
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf build
mkdir -p build/core/apis build/core/examples build/aws/apis build/aws/examples

# --- core: the cloud-neutral contracts, plus the one neutral Composition ------
for api in app sqlinstance kvstore inferenceservice; do
  cp "apis/$api/definition.yaml" "build/core/apis/$api-definition.yaml"
done
cp apis/kvstore/composition.yaml build/core/apis/kvstore-composition.yaml
cp packages/core/crossplane.yaml build/core/crossplane.yaml
cp examples/kvstore-basic.yaml examples/kvstore-complete.yaml build/core/examples/

# --- aws: the AWS contract, plus every AWS Composition ------------------------
cp apis/epi/definition.yaml build/aws/apis/epi-definition.yaml
for api in app sqlinstance inferenceservice epi; do
  cp "apis/$api/composition.yaml" "build/aws/apis/$api-composition.yaml"
done
cp packages/aws/crossplane.yaml build/aws/crossplane.yaml
cp examples/app-*.yaml examples/sqlinstance-*.yaml examples/inferenceservice-*.yaml \
   examples/epi.yaml examples/environmentconfig.yaml build/aws/examples/

echo "staged:"
find build -name '*.yaml' | sort | sed 's/^/  /'

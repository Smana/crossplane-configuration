#!/usr/bin/env bash
# Stage a clean build root per package. crossplane xpkg build recurses through
# --package-root and --ignore cannot exclude directories, so the KCL sources and
# the other package's files must simply not be there.
set -euo pipefail
cd "$(dirname "$0")/.."

rm -rf build
mkdir -p build/core/apis build/core/examples \
         build/aws/apis build/aws/examples \
         build/gcp/apis build/gcp/examples

# --- core: the cloud-neutral contracts, plus the one neutral Composition ------
for api in app sqlinstance kvstore inferenceservice; do
  cp "apis/$api/definition.yaml" "build/core/apis/$api-definition.yaml"
done
cp apis/kvstore/composition.yaml build/core/apis/kvstore-composition.yaml
cp packages/core/crossplane.yaml build/core/crossplane.yaml
cp examples/kvstore-basic.yaml examples/kvstore-complete.yaml build/core/examples/

# --- aws: the AWS contract, plus every AWS Composition ------------------------
#
# inferenceservice joined the -aws/-gcp pair when the GCP branch landed; only
# epi is still a single cloud-specific Composition with no sibling, because EPI
# is an AWS-only contract (GCPWorkloadIdentity is its GCP counterpart, and ships
# in the gcp package rather than as a second Composition for the same kind).
cp apis/epi/definition.yaml build/aws/apis/epi-definition.yaml
for api in app sqlinstance inferenceservice; do
  cp "apis/$api/composition-aws.yaml" "build/aws/apis/$api-composition.yaml"
done
cp apis/epi/composition.yaml build/aws/apis/epi-composition.yaml
cp packages/aws/crossplane.yaml build/aws/crossplane.yaml
# Explicit, not globbed. `examples/app-*.yaml` also matches
# app-gcp-objectstore.yaml, so the AWS package shipped a GCP example as its own
# documentation -- harmless at runtime, actively misleading to read.
cp examples/app-basic.yaml examples/app-complete.yaml examples/app-cron.yaml \
   examples/app-worker.yaml \
   examples/sqlinstance-basic.yaml examples/sqlinstance-complete.yaml \
   examples/inferenceservice-basic.yaml examples/inferenceservice-complete.yaml \
   examples/inferenceservice-endpointpicker.yaml \
   examples/epi.yaml examples/environmentconfig.yaml build/aws/examples/

# --- gcp: the GCP contract and its Compositions -------------------------------
cp apis/gcpworkloadidentity/definition.yaml build/gcp/apis/gcpworkloadidentity-definition.yaml
cp apis/gcpworkloadidentity/composition.yaml build/gcp/apis/gcpworkloadidentity-composition.yaml
for api in app sqlinstance inferenceservice; do
  cp "apis/$api/composition-gcp.yaml" "build/gcp/apis/$api-composition.yaml"
done
cp packages/gcp/crossplane.yaml build/gcp/crossplane.yaml
cp examples/gcpworkloadidentity.yaml examples/gcpworkloadidentity-bucket.yaml \
   examples/app-gcp-objectstore.yaml examples/sqlinstance-gcp.yaml \
   examples/inferenceservice-gcp.yaml \
   examples/environmentconfig.yaml build/gcp/examples/

echo "staged:"
find build -name '*.yaml' | sort | sed 's/^/  /'

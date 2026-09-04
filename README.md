# crossplane-configuration

Crossplane Configuration packages for the [ogenki](https://blog.ogenki.io) platform — the API
surface used by [Smana/cloud-native-ref](https://github.com/Smana/cloud-native-ref).

Composed with [KCL](https://kcl-lang.io) via
[function-kcl](https://github.com/crossplane-contrib/function-kcl). The KCL is **inlined into the
Compositions**, so installing a package pulls no further artifacts at render time.

## Packages

| Package | Contents |
|---|---|
| `ghcr.io/smana/crossplane-configuration-core` | Cloud-neutral contracts: `App`, `SQLInstance`, `KVStore`, `InferenceService` + the `KVStore` Composition |
| `ghcr.io/smana/crossplane-configuration-aws` | `EPI` (EKS Pod Identity) + the AWS Compositions for `App`, `SQLInstance`, `InferenceService`, `EPI`. Depends on `-core` |
| `ghcr.io/smana/crossplane-configuration-gcp` | `GCPWorkloadIdentity` + its Composition. Depends on `-core` |

Background on the cloud split:
[dual-cloud design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-08-18-gcp-support-design.md).

## APIs

All in group `cloud.ogenki.io`.

| Kind | Purpose |
|---|---|
| `App` | Application abstraction: Deployment, Service, HTTPRoute, HPA, PDB, CiliumNetworkPolicy, optional database / cache / object storage |
| `SQLInstance` | PostgreSQL via CloudNativePG, optional S3 barman backup and Atlas schema migrations |
| `KVStore` | Valkey cache via the official chart |
| `InferenceService` | Self-hosted LLM inference: vLLM, KEDA autoscaling, Envoy AI Gateway routes |
| `EPI` | EKS Pod Identity — an IAM role bound to a (namespace, ServiceAccount) pair |
| `GCPWorkloadIdentity` | GKE Workload Identity — Google IAM roles bound to a (namespace, ServiceAccount) pair, no key and no annotation |

## Install

```yaml
apiVersion: pkg.crossplane.io/v1
kind: Configuration
metadata:
  name: crossplane-configuration-aws
spec:
  package: ghcr.io/smana/crossplane-configuration-aws:v0.1.0
```

`-aws` pulls `-core` through its `dependsOn`.

The OCI tag is the git tag verbatim, `v`-prefixed. One spelling for the git tag,
the published package, and the `dependsOn` constraint.

### You must install the functions yourself

These packages deliberately do **not** declare Composition functions in
`dependsOn`. Install them alongside the Configuration:

| Function | Used by |
|---|---|
| `xpkg.upbound.io/crossplane-contrib/function-kcl` | every Composition |
| `xpkg.crossplane.io/crossplane-contrib/function-auto-ready` | every Composition's `ready` step |
| `xpkg.crossplane.io/crossplane-contrib/function-environment-configs` | `-aws` and `-gcp` Compositions |

**Why not `dependsOn`?** Because most consumers already pin these functions
themselves, and declaring them here as well produces *two* `Function` resources
for one package. Crossplane keys its dependency graph on package source, so two
nodes with the same source make the graph fail to initialise and every
Configuration goes unhealthy:

```
cannot initialize dependency graph from the packages in the lock:
node xpkg.crossplane.io/crossplane-contrib/function-auto-ready already exists
```

It is a race — Crossplane only creates its own copy when it resolves before
noticing the existing one — so it passes often enough to look fine and then
wedges a from-scratch install. Verified on a live cluster that Crossplane does
not dedupe by source: adding a second `Function` for an already-satisfied
package took every Configuration unhealthy within seconds, and removing it
restored them.

Pinning the functions yourself is also stricter than the `>=` floors this
package used to declare. See Smana/cloud-native-ref#1971.

## Releasing

Releases are cut by pushing a tag; nothing publishes from `main`.

```bash
git tag v0.1.0
git push origin v0.1.0
```

`.github/workflows/release.yaml` then runs `task check` — the same gates as CI,
re-run here because a tag can be pushed at any commit, including one that never
passed — before building, pushing every package to `ghcr.io/smana`, and creating
the GitHub release with `xrd-crds.yaml` attached.

That asset is what `cloud-native-ref` consumes: its `gen-catalog.sh` reads it via
`XRD_CRDS_FILE`, so a single version string drives both the installed
Configuration and the schemas its claims are validated against.

## Development

```bash
mise install
task check   # generate-sync + kcl fmt/test + render against golden fixtures
task build   # produce every .xpkg file
```

`apis/<api>/kcl/main.k` is the source of truth. `apis/<api>/composition.yaml` is **generated** by
`task generate` — edit the KCL, never the inlined copy.

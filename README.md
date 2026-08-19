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

A GCP package is added when it has content; see the
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

## Releasing

Releases are cut by pushing a tag; nothing publishes from `main`.

```bash
git tag v0.1.0
git push origin v0.1.0
```

`.github/workflows/release.yaml` then runs `task check` — the same gates as CI,
re-run here because a tag can be pushed at any commit, including one that never
passed — before building, pushing both packages to `ghcr.io/smana`, and creating
the GitHub release with `xrd-crds.yaml` attached.

That asset is what `cloud-native-ref` consumes: its `gen-catalog.sh` reads it via
`XRD_CRDS_FILE`, so a single version string drives both the installed
Configuration and the schemas its claims are validated against.

## Development

```bash
mise install
task check   # generate-sync + kcl fmt/test + render against golden fixtures
task build   # produce both .xpkg files
```

`apis/<api>/kcl/main.k` is the source of truth. `apis/<api>/composition.yaml` is **generated** by
`task generate` — edit the KCL, never the inlined copy.

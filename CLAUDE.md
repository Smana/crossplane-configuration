# CLAUDE.md

Crossplane Configuration packages for the [ogenki](https://blog.ogenki.io) platform. Consumed by
[`Smana/cloud-native-ref`](https://github.com/Smana/cloud-native-ref), which installs them as a
`Configuration` and pins a version in
`infrastructure/base/crossplane/configuration/configuration-packages.yaml`.

## The one thing to know

`apis/<api>/kcl/main.k` is the source of truth. `apis/<api>/composition.yaml` is **generated** —
`task generate` inlines the KCL into it as a block scalar. Never edit the inlined copy; CI
regenerates and fails if the two disagree.

Inlining is the point of this repo: an installed package pulls nothing at render time.

## Layout

| Path | Contents |
|---|---|
| `apis/<api>/definition.yaml` | XRD |
| `apis/<api>/composition.yaml` | Composition — **generated** |
| `apis/<api>/kcl/` | the KCL module (source of truth) |
| `examples/` | claims, flat — `crossplane xpkg build --examples-root` takes exactly one directory |
| `packages/{core,aws}/crossplane.yaml` | package metadata and `dependsOn` |
| `tests/golden/` | rendered fixtures captured pre-extraction; render equivalence is diffed against these |

APIs: `App`, `SQLInstance`, `KVStore`, `InferenceService` (core) and `EPI` + the AWS Compositions
(aws). All in group `cloud.ogenki.io`.

## Commands

```bash
mise install
task check     # generate-sync + kcl fmt/test + XRD schema + render equivalence
task build     # both .xpkg files
task render    # render every example, diff against tests/golden/
```

`task check` is the gate. CI runs the same targets plus `check_packages.sh`, which asserts the built
packages carry no `oci://` module reference.

## Releasing

Tag; nothing publishes from `main`.

```bash
git tag v0.2.0 && git push origin v0.2.0
```

The release workflow re-runs `task check` (a tag can point at a commit that never passed CI), pushes
both packages to `ghcr.io/smana`, and attaches `xrd-crds.yaml` — the asset `cloud-native-ref`'s
`gen-catalog.sh` reads to build its schema catalog.

The OCI tag is the git tag verbatim, `v`-prefixed: one spelling for the git tag, the published
package, and the `dependsOn` constraint.

**After releasing, two things in `cloud-native-ref` must move together:** the package pin, and the
App Wizard's `fetch-crossplane-configuration` init clone tag in
`apps/platform/app-wizard/app.yaml`. The wizard reads the App XRD and Composition from that clone to
build its form and render previews.

## Authoring

Rules: [`.claude/rules/kcl.md`](.claude/rules/kcl.md) (auto-loads when editing KCL).
Reference with examples: [`docs/kcl-authoring.md`](docs/kcl-authoring.md).

The short version: never mutate a dict after creation (it emits the resource twice), keep list
comprehensions single-line, don't shadow the loop variable in a dict comprehension, and run
`task check`.

## Known gap

No automated security audit of composition output. `cloud-native-ref`'s Polaris gate sees the
*claims*, not the Deployments Crossplane expands them into, and the retired
`validate-kcl-compositions.sh` never had a security stage despite the constitution's table. Review
pod specs by hand. `task render` output is the natural input for closing this.

## Installing on a cluster that already has these XRDs

Installing the package **adopts** existing XRDs rather than recreating them, but adoption does not
remove them from a GitOps controller's inventory, and it does not guarantee the *content* is the
package's. Both traps are written up in `cloud-native-ref`'s
`docs/superpowers/specs/2026-08-18-crossplane-configuration-extraction-design.md`. Read it before
repeating this migration on another cluster.

---
description: KCL authoring rules for the Crossplane compositions in this repo
globs:
  - "apis/**/kcl/**/*.k"
  - "apis/**/kcl/**/settings*.yaml"
  - "apis/**/composition.yaml"
---

# KCL rules

Full reference with examples: [`docs/kcl-authoring.md`](../../docs/kcl-authoring.md).

1. **`apis/<api>/composition.yaml` is GENERATED.** Edit `apis/<api>/kcl/main.k`, then
   `make generate`. CI fails if the inlined copy is stale.
2. **Always `kcl fmt`.** `make test` formats in place and fails on a dirty diff (`kcl fmt` has no
   `--check` flag in 0.11.3).
3. **Never mutate a dict after creation** — function-kcl hashes at creation, so a mutation emits the
   resource **twice** ([function-kcl#285](https://github.com/crossplane-contrib/function-kcl/issues/285)).
   Use inline conditionals. Covers conditional assignment, `["key"] =` updates, and accumulating in
   a loop.
4. **List comprehensions must be single-line.**
5. **Never shadow the loop variable in a dict comprehension** — `[{name = name} for name in xs]`
   yields `{<value>: <value>}`. Use `for n in xs`. Symptom is remote: `field not declared in schema`.
6. **Validate with `make check`** before committing.

There is no `kcl mod push` flow any more — the KCL is inlined into the Compositions, and the
`version` in each `kcl.mod` is vestigial.

**No automated security gate exists for composition output** (see the doc). Check pod specs by hand
against the constitution: `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`,
`capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`, plus requests **and** limits.

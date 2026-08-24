# GCPWorkloadIdentity

Grants Google IAM roles to a Kubernetes ServiceAccount using GKE Workload Identity.

The GCP counterpart to [`EPI`](../../epi/kcl/README.md), and deliberately not a shared abstraction
with it — the two clouds differ in mechanism, not just in field names (ADR-0007 in
`cloud-native-ref`).

## What it renders

One `ProjectIAMMember` per role in `spec.roles`. Nothing else.

No Google service account, no exported key, and **no `iam.gke.io/gcp-service-account` annotation on
the KSA** — GKE binds by *subject*, so the pod authenticates with no mounted credential and the
ServiceAccount needs no marking. That absence is the point of the API.

## Example

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: GCPWorkloadIdentity
metadata:
  name: xplane-external-dns
  namespace: infrastructure
spec:
  serviceAccount:
    name: external-dns
    namespace: infrastructure
  roles:
    - projects/ogenki-435905/roles/xplane_dns_editor
```

## API

| Field | Required | Notes |
|---|---|---|
| `serviceAccount.name` / `.namespace` | yes | The KSA that receives the identity |
| `roles` | yes, ≥1 | Exact GCP role names — `roles/<x>` or `projects/<p>/roles/<id>`. Org-level roles are rejected, see below |
| `projectID` | no | Where the binding lands. Defaults to `gke-environment`'s `projectID` |
| `managementPolicies` | no | Standard Crossplane management policies |
| `providerConfigRef` | no | Defaults to `ClusterProviderConfig/default` |

`spec.projectID` overrides only the binding *target*. The identity always comes from the cluster's
own workload identity pool, which is what makes cross-project grants work at all.

## Five things that will bite

**1. `projects/` takes the NUMBER, `workloadIdentityPools/` takes the ID.** Reversed, the GCP API
*accepts* the binding and it silently never matches — a permission error that points nowhere.
`main_test.k` pins the whole principal string rather than checking its shape, because a structural
assertion cannot catch this.

**2. `projectNumber` arrives as an int**, not a string, so `main.k` calls `str()` on it. The example
EnvironmentConfig leaves it unquoted so `task render` exercises that path. Why quoting cannot fix it
is explained at `_projectNumber` in `main.k`.

**3. Never `ProjectIAMPolicy` or `ProjectIAMBinding`.** Both are *authoritative* and overwrite the
project policy for the roles they manage. Rendered once per workload, either deletes other
workloads' and humans' bindings — including break-glass access. `test_never_authoritative` guards
it.

**4. Organization-level custom roles are rejected by the XRD pattern.**
`organizations/<id>/roles/<id>` is a legitimate GCP role name that can be bound at project level,
but the pattern accepts only predefined and *project*-level custom roles. That is deliberate — this
platform has no org-level governance, and cross-organisation identity is a stated non-goal — but the
rejection reads as a generic "should match pattern" error, so it is worth knowing. Widen the pattern
in `definition.yaml` if org roles ever apply.

**5. Roles the cluster may not grant are refused at the provider, not here.** `cloud-native-ref`'s
`opentofu/gcp/gke/init/iam.tf` binds Crossplane's own identity with an IAM Condition allowlisting
specific roles. A claim naming anything outside that list fails with a message naming the role. Add
the role there first.

## No `customRole`

The API deliberately cannot create custom roles, though an earlier design sketched it.

The allowlist above matches exact role names via `hasOnly`, so a role whose name this composition
invents at render time can never be allowlisted in advance. Supporting it would mean dropping the
condition and restoring the privilege-escalation path it exists to close.

Add capabilities by creating a `google_project_iam_custom_role` in OpenTofu — where the name is
deterministic — and referencing it from `spec.roles`.

## Tests

```bash
kcl fmt . && kcl test . -Y settings-example.yaml
```

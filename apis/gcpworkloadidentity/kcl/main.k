# This module grants Google IAM roles to a Kubernetes ServiceAccount using GKE
# Workload Identity, via the Crossplane GCP provider.
#
# It renders one ProjectIAMMember per requested role in spec.roles, plus one
# BucketIAMMember per entry in spec.bucketRoles, and nothing else. There is
# no Google service account, no key, and no `iam.gke.io/gcp-service-account`
# annotation on the KSA -- GKE binds by SUBJECT, so the KSA needs no annotation
# and the pod needs no mounted credential.
oxr = option("params").oxr
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]

_metadata = lambda suffix: str -> any {
    {
        name = oxr.metadata.name + "-" + suffix
        namespace = oxr.metadata.namespace
        annotations = {
            "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-" + suffix
        }
    }
}

# Defaulted FIELD BY FIELD, not as a whole object. A claim setting only
# `providerConfigRef: {kind: ClusterProviderConfig}` — which is also what CRD
# defaulting produces from `providerConfigRef: {}` — is truthy, so an
# `or {kind = ..., name = ...}` on the whole dict never fires and the rendered
# resource ships a ref with no name. (apis/epi/kcl/main.k has that shape.)
_pcr = oxr.spec.providerConfigRef or {}
_providerConfigRef = {
    kind = _pcr.kind or "ClusterProviderConfig"
    name = _pcr.name or "default"
}

# str() is REQUIRED, not defensive. THIS IS THE CANONICAL EXPLANATION -- the
# other mentions of it in this API point here rather than restating it.
#
# projectNumber reaches the EnvironmentConfig through Flux postBuild
# substitution, which writes into rendered YAML text. A 12-digit project number
# lands as a bare scalar and parses as an INT. Quoting it in the manifest does
# not help: kustomize strips quotes it considers unnecessary before Flux ever
# substitutes. Concatenating an int here fails the type check.
#
# The GCP example EnvironmentConfig deliberately leaves projectNumber unquoted so
# this path is exercised by `task render` rather than only in production.
_projectNumber = str(envConfig.projectNumber)

# spec.projectID overrides only where the BINDING lands, never which pool the
# identity comes from -- the two differ when granting access to a project other
# than the cluster's. The pool always belongs to the cluster's own project and
# always reads "<PROJECT_ID>.svc.id.goog".
_projectID = oxr.spec.projectID or envConfig.projectID

# TRAP: `projects/` takes the project NUMBER, `workloadIdentityPools/` takes the
# project ID. Reversed, the GCP API ACCEPTS the binding and it simply never
# matches -- a permission error that points nowhere. test_member_string_exact
# pins the whole string for that reason.
# The subject namespace comes from the CLAIM, never from spec — see the
# serviceAccount comment in definition.yaml. A claim cannot bind a
# ServiceAccount outside its own namespace because there is nowhere to say so.
_member = "principal://iam.googleapis.com/projects/" + _projectNumber + "/locations/global/workloadIdentityPools/" + envConfig.workloadPool + "/subject/ns/" + oxr.metadata.namespace + "/sa/" + oxr.spec.serviceAccount.name

# Defense in depth. The XRD's x-kubernetes-validations rule is the real
# enforcement point -- an identity granting nothing is rejected at admission,
# before this composition ever runs. This mirrors the SAME predicate so a
# direct `crossplane render` invocation (which bypasses admission) fails the
# same way instead of silently producing an XR with no resources.
_hasAnyGrant = lambda roles: [str], bucketRoles: [any] -> bool {
    len(roles) > 0 or len(bucketRoles) > 0
}

assert _hasAnyGrant(oxr.spec.roles or [], oxr.spec.bucketRoles or []), "spec must set at least one of roles or bucketRoles -- an identity granting nothing is not valid"

# Role names carry characters that are illegal in a Kubernetes object name, so
# each one is slugged to build a stable resource name:
#   roles/dns.admin                                -> dns-admin
#   projects/ogenki-435905/roles/xplane_dns_editor -> xplane-dns-editor
#
# Slugging by CONTENT rather than by list index is deliberate: an index-based
# name would change when someone reorders spec.roles, and renaming a managed
# resource is a delete-and-recreate of the live IAM binding.
# The trailing strip("-") is not cosmetic. GCP permits `_` and `.` at the end of
# a custom role id, so `projects/p/roles/dns_editor_` would slug to `dns-editor-`
# and the resource name would end in a dash — which DNS-1123 forbids. The
# apiserver then rejects the resource with a message naming neither the role nor
# the slug. Same for a leading separator.
_slug = lambda role: str -> str {
    role.split("/")[-1].replace("_", "-").replace(".", "-").lower().strip("-")
}

_slugs = [_slug(role) for role in oxr.spec.roles or []]
_uniqueSlugs = {slug: "" for slug in _slugs}

# Two roles that slug identically would emit two resources with one name, which
# surfaces as a confusing duplicate-resource error. Fail here with the cause,
# naming the ROLES the operator has to change rather than the slugs.
assert len(_uniqueSlugs) == len(_slugs), "spec.roles contains roles whose names collide once normalised: {}. Rename or drop one.".format(oxr.spec.roles or [])

# Loop variable is `roleName`, NOT `role`: a dict key sharing a name with the
# enclosing loop variable makes KCL drop the field SILENTLY, yielding a binding
# that grants nothing. Documented in .claude/rules/kcl.md rule 5 for dict
# comprehensions -- it bites in a plain dict literal inside a list comprehension
# too. Guarded by test_roles_passed_through.
_projectMembers = [{
    apiVersion = "cloudplatform.gcp.m.upbound.io/v1beta1"
    kind = "ProjectIAMMember"
    metadata = _metadata(_slug(roleName))
    spec: {
        if oxr.spec.managementPolicies:
            managementPolicies = oxr.spec.managementPolicies
        providerConfigRef = _providerConfigRef
        forProvider = {
            project = _projectID
            role = roleName
            member = _member
        }
    }
} for roleName in oxr.spec.roles or []]

# Bucket-scoped bindings. Rendered as BucketIAMMember so the grant
# reaches ONE bucket: a project-level roles/storage.* would reach every bucket
# in the project, including OpenBao's snapshots and CNPG's backups.
#
# `_member` is reused verbatim rather than rebuilt -- see the comment on its
# definition above. Both the bucket and the role are slugged through the same
# `_slug` helper used for project roles: the XRD's bucket-name pattern permits
# `.` and `_` (real GCS buckets are often domain-style, e.g. "assets.corp.com"),
# neither of which DNS-1123 allows in a Kubernetes object name.
_bucketSlugs = [_slug(br.role) + "-" + _slug(br.bucket) for br in oxr.spec.bucketRoles or []]
_uniqueBucketSlugs = {slug: "" for slug in _bucketSlugs}

# Same failure class as the roles collision above: two {bucket, role} pairs
# that slug identically (e.g. "my.app-data" and "my-app.data", which `_slug`
# maps onto the same string) emit two resources with one name -- a `crossplane
# render` fatal error naming the SLUG, not the pairs. Fail here instead, naming
# the pairs the operator has to change.
assert len(_uniqueBucketSlugs) == len(_bucketSlugs), "spec.bucketRoles contains bucket/role pairs whose names collide once normalised: {}. Rename or drop one.".format(oxr.spec.bucketRoles or [])

_bucketMembers = [{
    apiVersion = "storage.gcp.m.upbound.io/v1beta1"
    kind = "BucketIAMMember"
    metadata = _metadata(_slug(br.role) + "-" + _slug(br.bucket))
    spec: {
        if oxr.spec.managementPolicies:
            managementPolicies = oxr.spec.managementPolicies
        providerConfigRef = _providerConfigRef
        forProvider = {
            bucket = br.bucket
            role = br.role
            member = _member
        }
    }
} for br in oxr.spec.bucketRoles or []]

items = _projectMembers + _bucketMembers

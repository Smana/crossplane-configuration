# This module grants Google IAM roles to a Kubernetes ServiceAccount using GKE
# Workload Identity, via the Crossplane GCP provider.
#
# It renders one ProjectIAMMember per requested role and nothing else. There is
# no Google service account, no key, and no `iam.gke.io/gcp-service-account`
# annotation on the KSA -- GKE binds by SUBJECT, so the KSA needs no annotation
# and the pod needs no mounted credential.
oxr = option("params").oxr
ocds = option("params").ocds
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]

_providerConfigRef = oxr.spec.providerConfigRef or {
    kind = "ClusterProviderConfig"
    name = "default"
}

# str() is REQUIRED, not defensive.
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

# The workload identity pool belongs to the project that owns the CLUSTER, and
# always appears as "<PROJECT_ID>.svc.id.goog". spec.projectID overrides only
# where the BINDING lands, never which pool the identity comes from -- the two
# differ when granting access to a project other than the cluster's.
_workloadPool = envConfig.workloadPool
_projectID = oxr.spec.projectID or envConfig.projectID

# TRAP: `projects/` takes the project NUMBER, `workloadIdentityPools/` takes the
# project ID. Reversed, the GCP API ACCEPTS the binding and it simply never
# matches -- a permission error that points nowhere. main_test.k asserts the
# exact string for that reason.
_member = "principal://iam.googleapis.com/projects/" + _projectNumber + "/locations/global/workloadIdentityPools/" + _workloadPool + "/subject/ns/" + oxr.spec.serviceAccount.namespace + "/sa/" + oxr.spec.serviceAccount.name

# Role names carry characters that are illegal in a Kubernetes object name, so
# each one is slugged to build a stable resource name:
#   roles/dns.admin                              -> dns-admin
#   projects/ogenki-435905/roles/xplane_dns_editor -> xplane-dns-editor
#
# Slugging by CONTENT rather than by list index is deliberate: an index-based
# name would change when someone reorders spec.roles, and renaming a managed
# resource is a delete-and-recreate of the live IAM binding.
_slug = lambda role: str -> str {
    role.split("/")[-1].replace("_", "-").replace(".", "-").lower()
}

_slugs = [_slug(role) for role in oxr.spec.roles]
_uniqueSlugs = {slug: "" for slug in _slugs}

# Two roles that slug identically would emit two resources with one name, which
# surfaces as a confusing duplicate-resource error. Fail here with the cause.
assert len(_uniqueSlugs) == len(_slugs), "spec.roles contains roles whose names collide once normalised: {}. Rename or drop one.".format(_slugs)

# The loop variable is `roleName`, NOT `role`, and that is load-bearing.
#
# `forProvider = { role = role }` — key and loop variable sharing a name — makes
# KCL drop the field ENTIRELY. No error, no warning: the rendered
# ProjectIAMMember simply has no `role`, which is a binding that grants nothing.
# Measured here, caught by test_roles_passed_through in main_test.k. This is the
# dict-comprehension shadowing rule in .claude/rules/kcl.md, and it bites in a
# plain dict literal inside a list comprehension too.
items = [{
    apiVersion = "cloudplatform.gcp.m.upbound.io/v1beta1"
    kind = "ProjectIAMMember"
    metadata = {
        name = oxr.metadata.name + "-" + _slug(roleName)
        namespace = oxr.metadata.namespace
        annotations = {
            "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-" + _slug(roleName)
        }
    }
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
} for roleName in oxr.spec.roles]

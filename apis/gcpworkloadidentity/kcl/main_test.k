import regex

# Tests for the GCP Workload Identity composition
# Run: kcl test . -Y settings-example.yaml

# ---- Test: one ProjectIAMMember per requested role ----
test_one_binding_per_role = lambda {
    _roles = option("params").oxr.spec.roles
    _members = [r for r in items if r.kind == "ProjectIAMMember"]
    _bucketMembers = [r for r in items if r.kind == "BucketIAMMember"]
    assert len(_members) == len(_roles), "expected one ProjectIAMMember per role, got {} for {} roles".format(len(_members), len(_roles))
    assert len(items) == len(_members) + len(_bucketMembers), "composition must render only ProjectIAMMember and BucketIAMMember"
}

# ---- Test: additive IAM only ----
# ProjectIAMPolicy and ProjectIAMBinding are AUTHORITATIVE -- either would
# overwrite the project's policy for the roles it manages, deleting other
# workloads' and humans' bindings. Rendered once per workload, that breaks the
# moment a second claim exists. This is design criterion 20.
test_never_authoritative = lambda {
    _bad = [r.kind for r in items if r.kind in ["ProjectIAMPolicy", "ProjectIAMBinding"]]
    assert len(_bad) == 0, "authoritative IAM kinds would delete other bindings: {}".format(_bad)
}

# ---- Test: the principal string, asserted exactly ----
# `projects/` takes the project NUMBER and `workloadIdentityPools/` takes the
# project ID. Reversed, the API accepts the binding and it never matches. A
# structural check would not catch that, so the whole string is pinned.
test_member_string_exact = lambda {
    _members = [r for r in items if r.kind == "ProjectIAMMember"]
    _want = "principal://iam.googleapis.com/projects/323586397743/locations/global/workloadIdentityPools/ogenki-435905.svc.id.goog/subject/ns/infrastructure/sa/external-dns"
    _bad = [m.spec.forProvider.member for m in _members if m.spec.forProvider.member != _want]
    assert len(_bad) == 0, "unexpected member string: {}".format(_bad)
}

# ---- Test: projectNumber survives as a string ----
# Supplied as an int (see main.k, _projectNumber). Asserts the RESULT rather than
# the mechanism, so it still holds if the conversion moves.
test_project_number_not_mangled = lambda {
    _members = [r for r in items if r.kind == "ProjectIAMMember"]
    assert "projects/323586397743/" in _members[0].spec.forProvider.member, "project number missing or reformatted in {}".format(_members[0].spec.forProvider.member)
}

# ---- Test: role slugging produces legal, stable names ----
test_resource_naming = lambda {
    _name = option("params").oxr.metadata.name
    _bad = [r.metadata.name for r in items if not r.metadata.name.startswith(_name)]
    assert len(_bad) == 0, "resources with wrong prefix: {}".format(_bad)
    _names = [r.metadata.name for r in items]
    assert "xplane-external-dns-xplane-dns-editor" in _names, "custom role should slug to xplane-dns-editor, got {}".format(_names)
    assert "xplane-external-dns-monitoring-viewer" in _names, "predefined role should slug to monitoring-viewer, got {}".format(_names)
}

# ---- Test: names are valid Kubernetes object names ----
# Asserts the real DNS-1123 regex, not a hand-picked list of bad characters. The
# earlier version only rejected `_`, `.` and `/`, so it passed a name ending in a
# dash — which the apiserver rejects and which GCP can produce, because a custom
# role id may end in `_` or `.`.
test_names_are_dns1123 = lambda {
    _bad = [r.metadata.name for r in items if not regex.match(r.metadata.name, "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")]
    assert len(_bad) == 0, "resource names are not valid DNS-1123: {}".format(_bad)
    _long = [r.metadata.name for r in items if len(r.metadata.name) > 253]
    assert len(_long) == 0, "resource names exceed the 253-char limit: {}".format(_long)
}

# ---- Test: the slugger strips separators GCP allows at the edges ----
# A role id ending in `_` or `.` becomes a trailing dash without the strip, and
# the resulting resource is rejected by the apiserver with a message naming
# neither the role nor the slug.
test_slug_strips_edge_separators = lambda {
    assert _slug("projects/p/roles/dns_editor_") == "dns-editor", "trailing separator not stripped: {}".format(_slug("projects/p/roles/dns_editor_"))
    assert _slug("roles/dns.admin.") == "dns-admin", "trailing dot not stripped: {}".format(_slug("roles/dns.admin."))
    assert _slug("roles/iam.serviceAccountTokenCreator") == "iam-serviceaccounttokencreator", "camelCase not lowered"
}

# ---- Test: the subject namespace comes from the claim ----
# The security invariant. spec has no namespace field, so a claim cannot bind a
# ServiceAccount outside its own namespace — this asserts the rendered principal
# actually reflects that rather than picking the namespace up from somewhere else.
test_subject_namespace_is_the_claims = lambda {
    _ns = option("params").oxr.metadata.namespace
    _bad = [r.spec.forProvider.member for r in items if "/subject/ns/" + _ns + "/sa/" not in r.spec.forProvider.member]
    assert len(_bad) == 0, "subject namespace is not the claim's ({}): {}".format(_ns, _bad)
}

# ---- Test: the binding target project ----
# ProjectIAMMember-specific: BucketIAMMember scopes to a bucket, not a
# project, and its forProvider has no `project` field at all.
test_project_set = lambda {
    _env = option("params").ctx["apiextensions.crossplane.io/environment"]
    _want = option("params").oxr.spec.projectID or _env.projectID
    _members = [r for r in items if r.kind == "ProjectIAMMember"]
    _bad = [r.metadata.name for r in _members if r.spec.forProvider.project != _want]
    assert len(_bad) == 0, "resources bound to the wrong project: {}".format(_bad)
}

# ---- Test: every role reaches a binding verbatim ----
test_roles_passed_through = lambda {
    _roles = option("params").oxr.spec.roles
    _got = [r.spec.forProvider.role for r in items]
    _missing = [role for role in _roles if role not in _got]
    assert len(_missing) == 0, "roles not rendered: {}".format(_missing)
}

# ---- Test: provider config ref defaults ----
test_provider_config_ref = lambda {
    _providerRef = option("params").oxr.spec.providerConfigRef or {kind = "ClusterProviderConfig", name = "default"}
    _bad = [r.metadata.name for r in items if r.spec.providerConfigRef != _providerRef]
    assert len(_bad) == 0, "resources with wrong providerConfigRef: {}".format(_bad)
}

# ---- Test: management policies propagation ----
test_management_policies = lambda {
    _mgmt = option("params").oxr.spec.managementPolicies
    _bad = [r.metadata.name for r in items if _mgmt and r.spec.managementPolicies != _mgmt]
    assert len(_bad) == 0, "resources missing managementPolicies: {}".format(_bad)
}

# ---- Test: apiVersion, per kind ----
test_api_versions = lambda {
    _wantApiVersion = {
        "ProjectIAMMember" = "cloudplatform.gcp.m.upbound.io/v1beta1"
        "BucketIAMMember" = "storage.gcp.m.upbound.io/v1beta1"
    }
    _bad = [r.kind for r in items if r.apiVersion != _wantApiVersion[r.kind]]
    assert len(_bad) == 0, "resources with wrong apiVersion: {}".format(_bad)
}

# ---- Test: namespaced, as Crossplane v2 requires ----
# v2 managed resources are namespaced; omitting the namespace fails the
# Kustomization dry-run with "<Kind>/<name> namespace not specified".
test_namespaced = lambda {
    _ns = option("params").oxr.metadata.namespace
    _bad = [r.metadata.name for r in items if r.metadata.namespace != _ns]
    assert len(_bad) == 0, "resources not in the claim's namespace: {}".format(_bad)
}

# ---- Test: bucketRoles render BucketIAMMember, not ProjectIAMMember ----
test_bucket_roles_are_bucket_scoped = lambda {
    bucketMembers = [r for r in items if r.kind == "BucketIAMMember"]
    assert len(bucketMembers) == 1, "expected 1 BucketIAMMember, got {}".format(len(bucketMembers))
    m = bucketMembers[0]
    assert m.spec.forProvider.bucket == "test-bucket", "expected bucket test-bucket, got {}".format(m.spec.forProvider.bucket)
    assert m.spec.forProvider.role == "roles/storage.objectAdmin", "expected roles/storage.objectAdmin, got {}".format(m.spec.forProvider.role)
}

# ---- Test: the bucket member binds the SAME principal as the project members ----
# A second construction of the principal:// string is exactly the drift this
# contract exists to prevent, so assert both kinds agree.
test_bucket_role_member_matches_project_member = lambda {
    bucketMembers = [r for r in items if r.kind == "BucketIAMMember"]
    projectMembers = [r for r in items if r.kind == "ProjectIAMMember"]
    assert bucketMembers[0].spec.forProvider.member == projectMembers[0].spec.forProvider.member, "bucket and project bindings must name the same principal"
}

# NOTE: there used to be a test_bucket_roles_optional here ("omitting
# bucketRoles changes nothing"). It asserted only len(projectMembers) >= 1 --
# a strictly weaker duplicate of test_one_binding_per_role -- because
# settings-example.yaml is the ONE fixture every test in this file shares, and
# it sets both roles and bucketRoles. A kcl-test lambda cannot exercise "the
# other field is absent" against that shared fixture without contradicting
# every other test that relies on it.
#
# The claim it was trying to make -- that either field is independently
# optional -- is instead pinned where it can be made for real: two example
# claims rendered through the actual composition pipeline.
# examples/gcpworkloadidentity.yaml has no bucketRoles; the bucket-only
# examples/gcpworkloadidentity-bucket.yaml has no roles at all. Both pass
# `task schema` and `task render` with a golden fixture, which is the stronger
# claim ("this shape renders correctly end-to-end") rather than the weaker one
# ("some ProjectIAMMember exists in a fixture that always sets roles").

# ---- Test: a claim granting nothing is invalid ----
# The XRD's x-kubernetes-validations rule is the real enforcement point (an
# identity that grants nothing is rejected at admission, before this
# composition ever runs). This exercises the SAME predicate the module asserts
# on, in isolation, so a change to one without the other is caught here rather
# than only against a live cluster.
test_empty_roles_and_bucket_roles_is_invalid = lambda {
    assert not _hasAnyGrant([], []), "roles=[] and bucketRoles=[] must be treated as invalid"
    assert _hasAnyGrant(["roles/monitoring.viewer"], []), "a non-empty roles list alone must be valid"
    assert _hasAnyGrant([], [{bucket = "test-bucket", role = "roles/storage.objectAdmin"}]), "a non-empty bucketRoles list alone must be valid"
}

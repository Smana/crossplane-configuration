# Tests for the GCP Workload Identity composition
# Run: kcl test . -Y settings-example.yaml

# ---- Test: one ProjectIAMMember per requested role ----
test_one_binding_per_role = lambda {
    _roles = option("params").oxr.spec.roles
    _members = [r for r in items if r.kind == "ProjectIAMMember"]
    assert len(_members) == len(_roles), "expected one ProjectIAMMember per role, got {} for {} roles".format(len(_members), len(_roles))
    assert len(items) == len(_members), "composition must render ProjectIAMMember and nothing else"
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
test_names_are_dns1123 = lambda {
    _illegal = [r.metadata.name for r in items if "_" in r.metadata.name or "." in r.metadata.name or "/" in r.metadata.name]
    assert len(_illegal) == 0, "role characters leaked into resource names: {}".format(_illegal)
}

# ---- Test: the binding target project ----
test_project_set = lambda {
    _env = option("params").ctx["apiextensions.crossplane.io/environment"]
    _want = option("params").oxr.spec.projectID or _env.projectID
    _bad = [r.metadata.name for r in items if r.spec.forProvider.project != _want]
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

# ---- Test: apiVersion ----
test_api_versions = lambda {
    _bad = [r.kind for r in items if r.apiVersion != "cloudplatform.gcp.m.upbound.io/v1beta1"]
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

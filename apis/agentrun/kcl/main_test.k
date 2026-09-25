# Tests for the AgentRun composition. Run: kcl test . -Y settings-example.yaml
#
# Every variant calls _render directly with a synthetic XR, so one run covers
# the phase table, revocation, projection and both data classes whatever
# settings-example.yaml holds.
_NAME = "xplane-run-7f3cq2xz"
_BASE_SPEC = {
    role = "implementer"
    repository = "Smana/cloud-native-ref"
    principal = "human:312345678901234567"
    dataClass = "public"
    task = {text = "Fix the broken link in docs/README.md."}
}
_DXR = {apiVersion = "cloud.ogenki.io/v1alpha1", kind = "AgentRun", metadata = {name = _NAME, namespace = "agents"}}

_xr = lambda spec: any, annotations: any, labels: any, status: any -> any {
    {
        metadata = {name = _NAME, namespace = "agents", uid = "0b3c6f0e-5d1a-4b8e-9f41-2a7c3e9d8b10", annotations = annotations, labels = labels}
        spec = _BASE_SPEC | spec
        status = status
    }
}

_run = lambda spec: any -> [any] {
    _render(_xr(spec, {}, {}, {}), {}, _DXR)
}

_kind = lambda res: [any], kind: str -> [any] {
    [r for r in res if r.kind == kind]
}

_status = lambda res: [any] -> any {
    _kind(res, "AgentRun")[0].status
}

_pod = lambda res: [any] -> any {
    _kind(res, "Sandbox")[0].spec.podTemplate.spec
}

_sandboxWith = lambda conditions: [any] -> any {
    {
        "xplane-run-7f3cq2xz-sandbox" = {
            Resource = {metadata = {creationTimestamp = "2026-09-25T10:00:00Z"}, status = {conditions = conditions}}
        }
    }
}

_phaseFor = lambda annotations: any, status: any, observed: any -> str {
    _status(_render(_xr({}, annotations, {}, status), observed, _DXR)).phase
}

test_renders_four_resources_and_status = lambda {
    _res = _run({})
    assert [r.kind for r in _res] == ["ServiceAccount", "ConfigMap", "CiliumNetworkPolicy", "Sandbox", "AgentRun"]
}

test_names_labels_and_principal = lambda {
    _res = _run({})
    assert [r.metadata.name for r in _res if r.kind != "AgentRun"] == [_NAME, _NAME + "-task", _NAME, _NAME]
    _composed = [r for r in _res if r.kind != "AgentRun"]
    assert all r in _composed {
        r.metadata.labels["agents.ogenki.io/run-id"] == "7f3cq2xz" and r.metadata.labels["agents.ogenki.io/role"] == "implementer" and r.metadata.annotations["agents.ogenki.io/principal"] == "human:312345678901234567"
    }
}

test_task_label_propagates_from_the_claim = lambda {
    _res = _render(_xr({}, {}, {"agents.ogenki.io/task" = "t-9f2k"}, {}), {}, _DXR)
    assert _kind(_res, "Sandbox")[0].spec.podTemplate.metadata.labels["agents.ogenki.io/task"] == "t-9f2k"
    assert "agents.ogenki.io/task" not in _kind(_run({}), "Sandbox")[0].metadata.labels
}

test_service_account_has_no_token = lambda {
    assert _kind(_run({}), "ServiceAccount")[0].automountServiceAccountToken == False
}

test_pod_shape = lambda {
    _sbx = _kind(_run({}), "Sandbox")[0]
    _p = _sbx.spec.podTemplate.spec
    assert _sbx.spec.service == False, "nothing dials into a sandbox (C4)"
    assert _p.runtimeClassName == "gvisor"
    assert _p.automountServiceAccountToken == False
    assert _p.serviceAccountName == _NAME
    assert _p.restartPolicy == "Never"
    assert _p.activeDeadlineSeconds == 7200, "maxMinutes defaults to 120"
    assert _p.dnsConfig.options == [{name = "ndots", value = "1"}]
    assert _p.shareProcessNamespace == False
    assert _p.securityContext.runAsUser == 10001 and _p.securityContext.runAsNonRoot == True
    assert _sbx.spec.podTemplate.metadata.annotations["karpenter.sh/do-not-disrupt"] == "true"
    _all = _p.containers + _p.initContainers
    assert all c in _all {
        c.securityContext.allowPrivilegeEscalation == False and c.securityContext.readOnlyRootFilesystem == True and c.securityContext.capabilities.drop == ["ALL"] and c.securityContext.seccompProfile.type == "RuntimeDefault" and c.resources.limits.cpu and c.resources.limits.memory
    }
}

test_only_the_proxy_mounts_tokens = lambda {
    _p = _pod(_run({}))
    _proxy = _p.initContainers[0]
    assert _proxy.name == "identity-proxy" and _proxy.restartPolicy == "Always", "native sidecar"
    assert sorted([m.name for m in _proxy.volumeMounts if m.name.endswith("-token")]) == ["gateway-token", "sts-token"]
    _containers = _p.containers
    assert not any c in _containers {
        any m in c.volumeMounts {
            m.name.endswith("-token")
        }
    }, "the harness never holds a token (S5)"
}

test_token_audiences_and_ttl = lambda {
    _vols = {v.name: v for v in _pod(_run({})).volumes}
    _gw = _vols["gateway-token"].projected.sources[0].serviceAccountToken
    _sts = _vols["sts-token"].projected.sources[0].serviceAccountToken
    assert _gw.audience == "agent-router.implementer.public"
    assert _sts.audience == "octo-sts/Smana/cloud-native-ref/implementer"
    assert _gw.expirationSeconds == 600 and _sts.expirationSeconds == 600, "C3: TTL <= 600 s"
}

test_data_class_picks_port_and_audience = lambda {
    _res = _run({role = "tester", dataClass = "internal", task = {url = "https://github.com/Smana/cloud-native-ref/pull/2081"}})
    _env = {e.name: e.value for e in _pod(_res).containers[0].env}
    assert _env.LLM_BASE_URL == "http://127.0.0.1:4002/v1"
    assert _env.MCP_URL == "http://127.0.0.1:4002/mcp"
    _router = [e for e in _kind(_res, "CiliumNetworkPolicy")[0].spec.egress if e.toEndpoints and e.toEndpoints[0].matchLabels["io.kubernetes.pod.namespace"] == "envoy-gateway-system"][0]
    assert _router.toPorts[0].ports == [{port = "8081", protocol = "TCP"}], "internal runs reach only the internal listener"
    assert {v.name: v for v in _pod(_res).volumes}["gateway-token"].projected.sources[0].serviceAccountToken.audience == "agent-router.tester.internal"
}

test_public_run_reaches_only_the_public_listener = lambda {
    _egress = _kind(_run({}), "CiliumNetworkPolicy")[0].spec.egress
    _ports = [p.port for e in _egress if e.toEndpoints and e.toEndpoints[0].matchLabels["io.kubernetes.pod.namespace"] == "envoy-gateway-system" for t in e.toPorts for p in t.ports]
    assert _ports == ["8080"]
}

test_cnp_is_default_deny_with_named_egress = lambda {
    _spec = _kind(_run({
        egress = {profiles = ["pypi"]}
    }), "CiliumNetworkPolicy")[0].spec
    assert _spec.ingress == [{fromEntities = ["host"], toPorts = [{ports = [{port = "8000", protocol = "TCP"}, {port = "9901", protocol = "TCP"}]}]}]
    _fqdn = [e for e in _spec.egress if e.toFQDNs][0]
    assert [f.matchName for f in _fqdn.toFQDNs] == ["github.com", "api.github.com", "codeload.github.com", "objects.githubusercontent.com", "raw.githubusercontent.com", "pypi.org", "files.pythonhosted.org"]
    _dns = [n.matchName for n in _spec.egress[0].toPorts[0].rules.dns]
    assert "agent-router.envoy-gateway-system.svc.cluster.local" in _dns and "pypi.org" in _dns
    _dnsRules = _spec.egress[0].toPorts[0].rules.dns
    _egressRules = _spec.egress
    assert not any n in _dnsRules {
        "matchPattern" in n
    }, "the DNS rule answers allowlisted names only"
    assert not any e in _egressRules {
        "toEntities" in e
    }, "no world, no kube-apiserver"
}

test_room_ref_adds_broker_egress = lambda {
    _egress = _kind(_run({roomRef = "r-3kq9x2ma"}), "CiliumNetworkPolicy")[0].spec.egress
    assert any e in _egress {
        e.toEndpoints and e.toEndpoints[0].matchLabels["app.kubernetes.io/name"] == "room-broker" and e.toPorts[0].ports[0].port == "8443"
    }
    _plain = _kind(_run({}), "CiliumNetworkPolicy")[0].spec.egress
    assert not any e in _plain {
        e.toEndpoints and e.toEndpoints[0].matchLabels["app.kubernetes.io/name"] == "room-broker"
    }
}

test_size_presets = lambda {
    _small = _pod(_run({})).containers[0].resources
    _large = _pod(_run({size = "large"})).containers[0].resources
    assert _small.requests.cpu == "1" and _small.limits.cpu == "2" and _small.limits.memory == "4Gi"
    assert _large.requests.cpu == "4" and _large.limits.cpu == "8" and _large.limits.memory == "16Gi" and _large.limits["ephemeral-storage"] == "40Gi"
}

test_branch_defaults_to_run_id = lambda {
    assert _status(_run({})).branch == "agent/7f3cq2xz"
    assert _status(_run({branch = "agent/t-9f2k"})).branch == "agent/t-9f2k"
    assert {e.name: e.value for e in _pod(_run({branch = "agent/t-9f2k"})).containers[0].env}.BRANCH == "agent/t-9f2k"
}

test_queue_label = lambda {
    assert _kind(_run({queueName = "agents-standard"}), "Sandbox")[0].spec.podTemplate.metadata.labels["kueue.x-k8s.io/queue-name"] == "agents-standard"
}

test_rules_depend_on_role = lambda {
    _impl = _kind(_run({}), "ConfigMap")[0].data["rules.md"]
    _rev = _kind(_run({role = "reviewer", task = {url = "https://github.com/Smana/cloud-native-ref/pull/1"}}), "ConfigMap")[0].data["rules.md"]
    assert "Push only to agent/7f3cq2xz" in _impl
    assert "read-only" in _rev and "Push only" not in _rev
}

# ---- Phase table, rows 1-6 (design §2) ----
test_phase_pending_without_sandbox = lambda {
    assert _phaseFor({}, {}, {}) == "Pending"
}

test_phase_running = lambda {
    assert _phaseFor({}, {}, _sandboxWith([{type = "Ready", status = "True"}])) == "Running"
}

test_phase_succeeded = lambda {
    assert _phaseFor({}, {}, _sandboxWith([{type = "Ready", status = "False"}, {type = "Finished", status = "True", reason = "PodSucceeded", lastTransitionTime = "2026-09-25T10:20:00Z"}])) == "Succeeded"
}

test_phase_failed_with_reason = lambda {
    _res = _render(_xr({}, {}, {}, {}), _sandboxWith([{type = "Finished", status = "True", reason = "PodFailed", lastTransitionTime = "2026-09-25T12:00:00Z"}]), _DXR)
    assert _status(_res).phase == "Failed"
    assert _status(_res).reason == "PodFailed"
    assert _status(_res).startedAt == "2026-09-25T10:00:00Z"
    assert _status(_res).finishedAt == "2026-09-25T12:00:00Z"
}

test_phase_revoked_budget_wins_over_manual_and_success = lambda {
    _done = _sandboxWith([{type = "Finished", status = "True", reason = "PodSucceeded"}])
    assert _phaseFor({"agents.ogenki.io/revoked" = "budget-run"}, {}, _done) == "BudgetExhausted"
    assert _phaseFor({"agents.ogenki.io/revoked" = "manual"}, {}, _done) == "Revoked"
}

test_unknown_revocation_reason_is_ignored = lambda {
    assert _phaseFor({"agents.ogenki.io/revoked" = "because"}, {}, {}) == "Pending"
}

test_revocation_latches = lambda {
    assert _phaseFor({}, {phase = "Revoked"}, {}) == "Revoked", "removing the annotation never resurrects a run"
    assert _phaseFor({}, {phase = "BudgetExhausted"}, {}) == "BudgetExhausted"
    assert _phaseFor({}, {phase = "Succeeded"}, {}) == "Succeeded", "a vanished Sandbox does not regress status"
}

# ---- SC-13 offline: revocation drops the identity and the sandbox ----
test_revoked_run_keeps_only_its_record = lambda {
    _res = _render(_xr({}, {"agents.ogenki.io/revoked" = "budget-run"}, {}, {}), {}, _DXR)
    assert [r.kind for r in _res] == ["ConfigMap", "CiliumNetworkPolicy", "AgentRun"]
    assert _status(_res).phase == "BudgetExhausted" and _status(_res).reason == "budget-run"
}

# ---- SC-13 offline: annotation projection ----
test_valid_annotations_are_projected = lambda {
    _res = _render(_xr({}, {"agents.ogenki.io/usage-tokens" = "123456", "agents.ogenki.io/pull-request" = "https://github.com/Smana/cloud-native-ref/pull/2090"}, {}, {}), {}, _DXR)
    assert _status(_res).usage.tokens == 123456
    assert _status(_res).pullRequest == "https://github.com/Smana/cloud-native-ref/pull/2090"
}

test_malformed_annotations_are_not_projected = lambda {
    _bad = {"agents.ogenki.io/usage-tokens" = "-5", "agents.ogenki.io/pull-request" = "https://github.com/Evil/cloud-native-ref/pull/1"}
    _fresh = _status(_render(_xr({}, _bad, {}, {}), {}, _DXR))
    assert "usage" not in _fresh and "pullRequest" not in _fresh
    _kept = _status(_render(_xr({}, _bad, {}, {usage = {tokens = 42}, pullRequest = "https://github.com/Smana/cloud-native-ref/pull/7"}), {}, _DXR))
    assert _kept.usage.tokens == 42 and _kept.pullRequest == "https://github.com/Smana/cloud-native-ref/pull/7", "the last valid value stays"
}

test_pull_request_regex_escapes_the_repository = lambda {
    _res = _render(_xr({repository = "Smana/a.b"}, {"agents.ogenki.io/pull-request" = "https://github.com/Smana/aXb/pull/1"}, {}, {}), {}, _DXR)
    assert "pullRequest" not in _status(_res)
}

test_readiness_follows_the_sandbox = lambda {
    _pending = _kind(_run({}), "Sandbox")[0].metadata.annotations
    assert "krm.kcl.dev/ready" not in _pending
    _done = _render(_xr({}, {}, {}, {}), _sandboxWith([{type = "Finished", status = "True", reason = "PodSucceeded"}]), _DXR)
    assert _kind(_done, "Sandbox")[0].metadata.annotations["krm.kcl.dev/ready"] == "True"
}

test_harness_binds_for_probes = lambda {
    assert _pod(_run({})).containers[0].args == ["--host", "0.0.0.0", "--port", "8000"]
}

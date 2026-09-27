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

_tokenTTLs = lambda spec: any -> [int] {
    _vols = {v.name: v for v in _pod(_run(spec)).volumes}
    [_vols[n].projected.sources[0].serviceAccountToken.expirationSeconds for n in ["gateway-token", "sts-token"]]
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

# A Sandbox the composition already suspended: agent-sandbox deleted the pod,
# so Finished is gone and Ready is False (SandboxSuspended).
_suspendedSandbox = lambda finishedFor: str -> any {
    {
        "xplane-run-7f3cq2xz-sandbox" = {
            Resource = {
                metadata = {creationTimestamp = "2026-09-25T10:00:00Z", annotations = {"agents.ogenki.io/finished-phase" = finishedFor}}
                spec.operatingMode = "Suspended"
                status.conditions = [{type = "Ready", status = "False", reason = "SandboxSuspended"}]
            }
        }
    }
}

# A still-Running Sandbox carrying a stray/stale finished-phase annotation:
# the recovery path must require operatingMode == "Suspended" too, or a
# leftover annotation would short-circuit an in-progress run to terminal.
_runningSandboxWithStaleAnnotation = lambda finishedFor: str -> any {
    {
        "xplane-run-7f3cq2xz-sandbox" = {
            Resource = {
                metadata = {creationTimestamp = "2026-09-25T10:00:00Z", annotations = {"agents.ogenki.io/finished-phase" = finishedFor}}
                spec.operatingMode = "Running"
                status.conditions = [{type = "Ready", status = "True"}]
            }
        }
    }
}

_phaseFor = lambda annotations: any, status: any, observed: any -> str {
    _status(_render(_xr({}, annotations, {}, status), observed, _DXR)).phase
}

test_renders_five_resources_and_status = lambda {
    _res = _run({})
    assert [r.kind for r in _res] == ["ServiceAccount", "ConfigMap", "CiliumNetworkPolicy", "Usage", "Sandbox", "AgentRun"]
}

test_names_labels_and_principal = lambda {
    _res = _run({})
    assert [r.metadata.name for r in _res if r.kind != "AgentRun"] == [_NAME, _NAME + "-task", _NAME, _NAME + "-cnp", _NAME]
    _composed = [r for r in _res if r.kind != "AgentRun"]
    assert all r in _composed {
        r.metadata.labels["agents.ogenki.io/run-id"] == "7f3cq2xz" and r.metadata.labels["agents.ogenki.io/role"] == "implementer" and r.metadata.annotations["agents.ogenki.io/principal"] == "human:312345678901234567"
    }
}

test_task_label_propagates_from_the_claim = lambda {
    _res = _render(_xr({}, {}, {"agents.ogenki.io/task" = "6f2kq3ma"}, {}), {}, _DXR)
    assert _kind(_res, "Sandbox")[0].spec.podTemplate.metadata.labels["agents.ogenki.io/task"] == "6f2kq3ma"
    assert "agents.ogenki.io/task" not in _kind(_run({}), "Sandbox")[0].metadata.labels
    # C3: every object the run creates carries the task label when the claim has one.
    _withTask = [r for r in _res if r.kind != "AgentRun"]
    assert all r in _withTask {
        r.metadata.labels["agents.ogenki.io/task"] == "6f2kq3ma"
    }
    _withoutTask = [r for r in _run({}) if r.kind != "AgentRun"]
    assert not any r in _withoutTask {
        "agents.ogenki.io/task" in r.metadata.labels
    }
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
    # The CNP's endpointSelector matches these exact labels on the pod (C4).
    assert _sbx.spec.podTemplate.metadata.labels["agents.ogenki.io/run-id"] == "7f3cq2xz"
    assert _sbx.spec.podTemplate.metadata.labels["agents.ogenki.io/role"] == "implementer"
    _all = _p.containers + _p.initContainers
    assert all c in _all {
        c.securityContext.allowPrivilegeEscalation == False and c.securityContext.readOnlyRootFilesystem == True and c.securityContext.capabilities.drop == ["ALL"] and c.securityContext.seccompProfile.type == "RuntimeDefault" and c.resources.limits.cpu and c.resources.limits.memory
    }

    # Constitution §3.3 (requests AND limits) and §5.3 (liveness AND readiness).
    assert all c in _all {
        c.resources.requests.cpu and c.resources.requests.memory and c.livenessProbe and c.readinessProbe
    }
    assert _p.containers[0].startupProbe, "the harness also has a startup probe"
}

_projectsToken = lambda v: any -> bool {
    _sources = v?.projected?.sources or []
    any src in _sources {
        "serviceAccountToken" in src
    }
}

test_only_the_proxy_mounts_tokens = lambda {
    _p = _pod(_run({}))
    _proxy = _p.initContainers[0]
    assert _proxy.name == "identity-proxy" and _proxy.restartPolicy == "Always", "native sidecar"

    # A token volume is whatever projects a ServiceAccount token, whatever its name.
    _tokens = sorted([v.name for v in _p.volumes if _projectsToken(v)])
    assert _tokens == ["gateway-token", "sts-token"]
    assert sorted([m.name for m in _proxy.volumeMounts if m.name in _tokens]) == _tokens
    _containers = _p.containers
    assert not any c in _containers {
        any m in c.volumeMounts {
            m.name in _tokens
        }
    }, "the harness never holds a token (S5)"
}

test_token_audiences_and_ttl = lambda {
    _vols = {v.name: v for v in _pod(_run({})).volumes}
    _gw = _vols["gateway-token"].projected.sources[0].serviceAccountToken
    _sts = _vols["sts-token"].projected.sources[0].serviceAccountToken
    assert _gw.audience == "agent-router.implementer.public"
    assert _sts.audience == "octo-sts/Smana/cloud-native-ref/implementer"
}

# R2 (SP1 spike Q2): gVisor raises no inotify for kubelet's host-side rotation, so the
# proxy never reloads a rotated token. Both tokens outlive the run instead.
test_tokens_outlive_the_run = lambda {
    assert _tokenTTLs({}) == [7200, 7200], "maxMinutes defaults to 120"
    assert _tokenTTLs({
        budget = {maxMinutes = 480}
    }) == [28800, 28800], "the XRD's maximum"
    assert _tokenTTLs({
        budget = {maxMinutes = 5}
    }) == [600, 600], "the apiserver's floor"
}

test_data_class_picks_port_and_audience = lambda {
    _res = _run({role = "tester", dataClass = "internal", task = {url = "https://github.com/Smana/cloud-native-ref/pull/2081"}})
    _env = {e.name: e.value for e in _pod(_res).containers[0].env}
    assert _env.LLM_BASE_URL == "http://127.0.0.1:4002/v1"
    assert _env.MCP_URL == "http://127.0.0.1:4002/mcp"
    _router = [e for e in _kind(_res, "CiliumNetworkPolicy")[0].spec.egress if e.toEndpoints and e.toEndpoints[0].matchLabels["io.kubernetes.pod.namespace"] == "envoy-gateway-system"][0]
    assert _router.toPorts[0].ports == [{port = "8081", protocol = "TCP"}, {port = "8082", protocol = "TCP"}], "internal runs reach only the internal and sts listeners"
    assert {v.name: v for v in _pod(_res).volumes}["gateway-token"].projected.sources[0].serviceAccountToken.audience == "agent-router.tester.internal"
}

test_public_run_reaches_only_the_public_listener = lambda {
    _egress = _kind(_run({}), "CiliumNetworkPolicy")[0].spec.egress
    _ports = [p.port for e in _egress if e.toEndpoints and e.toEndpoints[0].matchLabels["io.kubernetes.pod.namespace"] == "envoy-gateway-system" for t in e.toPorts for p in t.ports]
    assert _ports == ["8080", "8082"]
}

# Owner decision 2026-09-26: octo-sts is reached only through agent-router's sts
# listener, whose JWT check is pinned to this cluster's issuer. A token minted in
# another EKS cluster matches octo-sts's issuer pattern, so no direct path may exist.
test_sts_goes_through_the_router = lambda {
    _spec = _kind(_run({}), "CiliumNetworkPolicy")[0].spec
    _names = [n.matchName for n in _spec.egress[0].toPorts[0].rules.dns]
    assert "octo-sts.agent-system.svc.cluster.local" not in _names
    _egressRules = _spec.egress
    assert not any e in _egressRules {
        e.toEndpoints and e.toEndpoints[0].matchLabels["app.kubernetes.io/name"] == "octo-sts"
    }, "no direct egress to octo-sts"
}

# The preStop revokes the GitHub token through api.github.com, and Crossplane
# deletes composed resources in parallel: without the Usage the CNP can go first.
# The meter's counter resets when an agent-router data-plane pod restarts, so a
# smaller reading is a reset, never a refund: the run's recorded spend only rises.
test_usage_never_goes_down = lambda {
    _lower = _status(_render(_xr({}, {"agents.ogenki.io/usage-tokens" = "10"}, {}, {
        usage = {tokens = 1900000}
    }), {}, _DXR))
    assert _lower.usage.tokens == 1900000
    _higher = _status(_render(_xr({}, {"agents.ogenki.io/usage-tokens" = "1950000"}, {}, {
        usage = {tokens = 1900000}
    }), {}, _DXR))
    assert _higher.usage.tokens == 1950000
}

test_usage_keeps_the_cnp_until_the_sandbox_is_gone = lambda {
    _u = _kind(_run({}), "Usage")
    assert len(_u) == 1
    assert _u[0].apiVersion == "protection.crossplane.io/v1beta1"
    assert _u[0].spec.replayDeletion == True
    assert _u[0].spec.of == {apiVersion = "cilium.io/v2", kind = "CiliumNetworkPolicy", resourceRef = {name = "xplane-run-7f3cq2xz"}}
    assert _u[0].spec.by == {apiVersion = "agents.x-k8s.io/v1beta1", kind = "Sandbox", resourceRef = {name = "xplane-run-7f3cq2xz"}}
}

test_cnp_is_default_deny_with_named_egress = lambda {
    _spec = _kind(_run({
        egress = {profiles = ["pypi"]}
    }), "CiliumNetworkPolicy")[0].spec
    # Only the proxy's health listener: not agent-server (M6), not Envoy admin (I2).
    assert _spec.ingress == [{fromEntities = ["host"], toPorts = [{ports = [{port = "9902", protocol = "TCP"}]}]}]
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

    # F1: the namespace is pinned too, so a tenant Gateway named "agent-router"
    # in some other namespace can never match this selector.
    _router = [e for e in _egressRules if e.toEndpoints and e.toEndpoints[0].matchLabels["gateway.envoyproxy.io/owning-gateway-name"] == "agent-router"][0]
    assert _router.toEndpoints[0].matchLabels["gateway.envoyproxy.io/owning-gateway-namespace"] == "agent-system"
}

test_room_ref_adds_broker_egress = lambda {
    _egress = _kind(_run({roomRef = "3kq7x2ma"}), "CiliumNetworkPolicy")[0].spec.egress
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
    assert _status(_run({branch = "agent/6f2kq3ma"})).branch == "agent/6f2kq3ma"
    assert {e.name: e.value for e in _pod(_run({branch = "agent/6f2kq3ma"})).containers[0].env}.BRANCH == "agent/6f2kq3ma"
}

test_queue_label = lambda {
    assert _kind(_run({queueName = "agents-standard"}), "Sandbox")[0].spec.podTemplate.metadata.labels["kueue.x-k8s.io/queue-name"] == "agents-standard"
}

test_rules_depend_on_role = lambda {
    _impl = _kind(_run({}), "ConfigMap")[0].data["rules.md"]
    _rev = _kind(_run({role = "reviewer", task = {url = "https://github.com/Smana/cloud-native-ref/pull/1"}}), "ConfigMap")[0].data["rules.md"]
    assert "Push only to agent/7f3cq2xz" in _impl
    assert "read-only" in _rev and "Push only" not in _rev

    # F6: the read-only branch is gap-free (1-4) and drops the commit-trailer
    # rule entirely -- a read-only role never commits.
    assert "3. Never modify .github/workflows/" in _rev
    assert "4. A 429 from the model gateway" in _rev
    assert "Every commit carries the trailer" not in _rev
    assert "6. A 429 from the model gateway" in _impl, "the write branch keeps all 6 rules"
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

# ---- F2: phase and reason latch after a terminal state, whatever annotation
# arrives later. A VALID revocation still stops the ServiceAccount and the
# Sandbox regardless of the latched phase (that's a rendering rule, not a
# phase change). ----
test_revocation_after_success_does_not_override_the_phase = lambda {
    _res = _render(_xr({}, {"agents.ogenki.io/revoked" = "budget-run"}, {}, {phase = "Succeeded"}), {}, _DXR)
    assert _status(_res).phase == "Succeeded"
    assert "reason" not in _status(_res), "the previous (absent) reason is unchanged"
    assert [r.kind for r in _res] == ["ConfigMap", "CiliumNetworkPolicy", "AgentRun"], "a valid revocation still withholds the SA and the Sandbox"
}

test_revoked_manual_latches_over_a_later_budget_revocation = lambda {
    _res = _render(_xr({}, {"agents.ogenki.io/revoked" = "budget-run"}, {}, {phase = "Revoked", reason = "manual"}), {}, _DXR)
    assert _status(_res).phase == "Revoked"
    assert _status(_res).reason == "manual"
}

test_budget_exhausted_latches_over_a_later_manual_revocation = lambda {
    _res = _render(_xr({}, {"agents.ogenki.io/revoked" = "manual"}, {}, {phase = "BudgetExhausted", reason = "budget-run"}), {}, _DXR)
    assert _status(_res).phase == "BudgetExhausted"
    assert _status(_res).reason == "budget-run"
}

# ---- F2b: a terminal run never gets a fresh ServiceAccount, so a pod
# agent-sandbox recreates from a finished Sandbox cannot start and run again.
# Succeeded/Failed keep the Sandbox object, suspended (M2). ----
test_succeeded_run_has_no_service_account_but_keeps_its_sandbox = lambda {
    _res = _render(_xr({}, {}, {}, {phase = "Succeeded"}), {}, _DXR)
    assert [r.kind for r in _res] == ["ConfigMap", "CiliumNetworkPolicy", "Usage", "Sandbox", "AgentRun"]
}

# ---- F3: startedAt/finishedAt survive a vanished Sandbox, same "last valid
# value stays" contract as usage/pullRequest. ----
test_started_and_finished_at_survive_a_vanished_sandbox = lambda {
    _prev = {phase = "Succeeded", startedAt = "2026-09-25T10:00:00Z", finishedAt = "2026-09-25T10:20:00Z"}
    _res = _render(_xr({}, {}, {}, _prev), {}, _DXR)
    assert _status(_res).startedAt == "2026-09-25T10:00:00Z"
    assert _status(_res).finishedAt == "2026-09-25T10:20:00Z"
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
    _trailing = _status(_render(_xr({}, {"agents.ogenki.io/usage-tokens" = "12a"}, {}, {}), {}, _DXR))
    assert "usage" not in _trailing, "the $ anchor rejects a trailing non-digit"
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

# ---- S7: the openhands profile runs the repo-built harness image ----
# Pinned to the #2110 pre-release tag for live testing; re-pin to the plain
# "ghcr.io/smana/agent-harness:v0.1.0@sha256:" prefix once #2110 merges and CI
# publishes that tag.
test_harness_profile_is_the_platform_image = lambda {
    _c = _pod(_run({})).containers[0]
    assert _c.image.startswith("ghcr.io/smana/agent-harness:"), "the openhands profile is the repo-built harness (S7)"
    assert "@sha256:" in _c.image, "pinned by digest"
    assert _c.args == [], "agent-run starts agent-server on 127.0.0.1:8000 itself"
}

# ---- M6: agent-server stays on loopback, probed from inside the container ----
test_harness_stays_on_loopback = lambda {
    _h = _pod(_run({})).containers[0]
    assert "ports" not in _h
    _probes = [_h.startupProbe, _h.readinessProbe, _h.livenessProbe]
    assert not any p in _probes {
        "httpGet" in p
    }, "kubelet cannot reach a loopback listener"
    assert _h.startupProbe.exec.command == ["python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/ready', timeout=2)"]
    assert _h.readinessProbe.exec.command[2].endswith("127.0.0.1:8000/ready', timeout=2)")
    assert _h.livenessProbe.exec.command[2].endswith("127.0.0.1:8000/health', timeout=2)")
    assert _h.startupProbe.periodSeconds == 5 and _h.startupProbe.failureThreshold == 60
    assert _h.readinessProbe.periodSeconds == 10
    assert _h.livenessProbe.periodSeconds == 20 and _h.livenessProbe.failureThreshold == 3
}

# ---- I2: Envoy admin is off the pod network; probes use the health listener ----
test_proxy_probes_use_the_health_listener = lambda {
    _proxy = _pod(_run({})).initContainers[0]
    assert _proxy.ports == [{name = "health", containerPort = 9902, protocol = "TCP"}]
    assert _proxy.readinessProbe.httpGet == {path = "/ready", port = 9902}
    assert _proxy.livenessProbe.httpGet == {path = "/ready", port = 9902}

    # A native sidecar gates the next container only on its startupProbe: without
    # one the harness can POST its conversation before the proxy serves /mcp.
    assert _proxy.startupProbe.httpGet == {path = "/ready", port = 9902}
}

# ---- I3: hot restart's abstract socket/shared memory is a control channel
# into the token holder, reachable from the harness's shared netns/IPC ----
test_proxy_disables_hot_restart = lambda {
    _proxy = _pod(_run({})).initContainers[0]
    assert _proxy.args == ["-c", "/etc/envoy/envoy.yaml", "--log-level", "warn", "--disable-hot-restart", "--concurrency", "1"]
}

# ---- M2: a finished run is Suspended, stays Ready, and never runs twice ----
test_finished_run_suspends_its_sandbox = lambda {
    _live = _kind(_run({}), "Sandbox")[0]
    assert _live.spec.operatingMode == "Running"
    assert "agents.ogenki.io/finished-phase" not in _live.metadata.annotations
    _ok = _kind(_render(_xr({}, {}, {}, {}), _sandboxWith([{type = "Finished", status = "True", reason = "PodSucceeded"}]), _DXR), "Sandbox")[0]
    assert _ok.spec.operatingMode == "Suspended"
    assert _ok.metadata.annotations["agents.ogenki.io/finished-phase"] == "Succeeded"
    _ko = _kind(_render(_xr({}, {}, {}, {}), _sandboxWith([{type = "Finished", status = "True", reason = "PodFailed"}]), _DXR), "Sandbox")[0]
    assert _ko.spec.operatingMode == "Suspended"
    assert _ko.metadata.annotations["agents.ogenki.io/finished-phase"] == "Failed"
}

test_suspended_sandbox_stays_ready = lambda {
    _res = _render(_xr({}, {}, {}, {phase = "Succeeded"}), _suspendedSandbox("Succeeded"), _DXR)
    assert _status(_res).phase == "Succeeded"
    _sbx = _kind(_res, "Sandbox")[0]
    assert _sbx.metadata.annotations["krm.kcl.dev/ready"] == "True", "Ready=False (SandboxSuspended) must not flap the XR"
    assert _sbx.spec.operatingMode == "Suspended"
}

test_lost_status_write_does_not_rerun_the_task = lambda {
    # Crossplane applied the Suspended Sandbox, then lost the XR status write.
    _ok = _render(_xr({}, {}, {}, {}), _suspendedSandbox("Succeeded"), _DXR)
    assert _status(_ok).phase == "Succeeded"
    assert "reason" not in _status(_ok)
    assert [r.kind for r in _ok] == ["ConfigMap", "CiliumNetworkPolicy", "Usage", "Sandbox", "AgentRun"], "no fresh ServiceAccount"
    assert _kind(_ok, "Sandbox")[0].spec.operatingMode == "Suspended"
    _ko = _render(_xr({}, {}, {}, {}), _suspendedSandbox("Failed"), _DXR)
    assert _status(_ko).phase == "Failed" and _status(_ko).reason == "PodFailed"

    # Only a finished phase is honoured; anything else is ignored.
    assert _phaseFor({}, {}, _suspendedSandbox("Running")) == "Pending"
    assert _phaseFor({}, {}, _suspendedSandbox("Revoked")) == "Pending"
}

# ---- Controller ruling: the finished-phase annotation is only honoured on a
# Sandbox the composition actually suspended -- not a Running one. ----
test_stale_finished_annotation_on_a_running_sandbox_is_ignored = lambda {
    assert _phaseFor({}, {}, _runningSandboxWithStaleAnnotation("Succeeded")) == "Running"
    assert _phaseFor({}, {}, _runningSandboxWithStaleAnnotation("Failed")) == "Running"
}

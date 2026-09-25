# AgentRun Composition

One gVisor-sandboxed coding-agent run (cloud-native-ref Agent Factory, SP1). Renders, all named
`xplane-run-<runId>[-suffix]` in namespace `agents`:

| Resource | Rendered unless | Ready when |
|---|---|---|
| `ServiceAccount` (automount off, no RBAC) | the phase is terminal (any of the four) | observed |
| `ConfigMap -task` (`task.md`, `rules.md`, `run.json`) | — | always |
| `CiliumNetworkPolicy` (DNS L7 allowlist, the class's gateway port, octo-sts, FQDN profiles) | — | always |
| `Sandbox` (`agents.x-k8s.io/v1beta1`, RuntimeClass `gvisor`, identity-proxy native sidecar) | revoked | Sandbox `Ready`, or the phase is terminal |

A `Succeeded` or `Failed` run's Sandbox is rendered `operatingMode: Suspended`: agent-sandbox deletes
the finished pod and never recreates it. The Sandbox also carries
`agents.ogenki.io/finished-phase`, so a lost XR status write cannot turn a finished run back into
`Pending` and run it again.

## API

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: AgentRun
metadata:
  name: xplane-run-7f3cq2xz        # xplane-run-<runId>, runId = 8 chars of [a-z2-7]
  namespace: agents                # the only namespace a run may live in
spec:
  role: implementer                # implementer|reviewer|tester|triager
  repository: Smana/cloud-native-ref
  principal: "human:312345678901234567"  # human:<zitadel sub> or system:<component>
  dataClass: public                # public|internal, no default
  task:
    text: "Fix the broken relative link in docs/superpowers/README.md."  # or url:, exactly one
  budget:
    maxTokens: 2000000             # default; the only field an update may change
  egress:
    profiles: [pypi]               # on top of github; pypi|npm|golang|crates
```

- **Immutable after creation**: everything in `spec` except `budget.maxTokens`, including adding or
  removing an optional field (`branch`, `roomRef`, `queueName`). To change a run, start another.
- `branch` defaults to `agent/<runId>`, `baseRef` to `main`, `model` to `agent-default`, `size` to
  `small`, `budget.maxMinutes` to 120.
- Every field: `examples/agentrun-complete.yaml`.

## Status has one writer

Controllers never patch status. They write annotations; this composition validates and projects them.

| Annotation | Projected to | Accepted value |
|---|---|---|
| `agents.ogenki.io/usage-tokens` | `status.usage.tokens` | `^[0-9]{1,12}$` |
| `agents.ogenki.io/pull-request` | `status.pullRequest` | `https://github.com/<spec.repository>/pull/<n>` |
| `agents.ogenki.io/revoked` | `status.phase` | `budget-run`, `budget-principal`, `budget-fleet` → `BudgetExhausted`; `manual` → `Revoked` |

A malformed value is ignored and the last valid one stays. Revocation and terminal phases latch.

## Test

    kcl test . -Y settings-example.yaml

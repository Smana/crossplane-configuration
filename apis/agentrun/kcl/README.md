# AgentRun Composition

One gVisor-sandboxed coding-agent run (cloud-native-ref Agent Factory, SP1). Renders, all named
`xplane-run-<runId>[-suffix]` in namespace `agents`:

| Resource | Rendered unless | Ready when |
|---|---|---|
| `ServiceAccount` (automount off, no RBAC) | revoked | observed |
| `ConfigMap -task` (`task.md`, `rules.md`, `run.json`) | — | always |
| `CiliumNetworkPolicy` (DNS L7 allowlist, the class's gateway port, octo-sts, FQDN profiles) | — | always |
| `Sandbox` (`agents.x-k8s.io/v1beta1`, RuntimeClass `gvisor`, identity-proxy native sidecar) | revoked | Sandbox `Ready` or `Finished` |

## API

See `examples/agentrun-basic.yaml` and `examples/agentrun-complete.yaml`.

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

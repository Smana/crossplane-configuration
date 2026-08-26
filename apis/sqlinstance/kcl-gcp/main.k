# SQLInstance has no GCP implementation yet (workstream 9 brings CNPG with
# barman backups to GCS). This Composition exists so that an App claiming
# sqlInstance on gcp-0 FAILS with a reason, in the resource the developer asked
# for, instead of sitting Ready=Unknown forever with nothing naming the cause.
#
# Composing zero resources (`items = []`) does NOT achieve that. Verified via
# crossplane render, with and without a trailing function-auto-ready step:
# Crossplane computes Ready from composed-resource observation, so a
# Composition producing zero resources is vacuously Ready=True/Available --
# an ACTIVE false positive, worse than the silent hang this file exists to
# prevent. A custom status Conditions object (meta.krm.kcl.dev/v1alpha1
# Conditions, target: CompositeAndClaim) can add a second condition, but
# "Ready" itself is a reserved Crossplane condition type no function may set
# ("cannot set ClaimCondition type: Ready is a reserved Crossplane
# Condition") -- so `kubectl get sqlinstance` still prints READY=True either
# way, with the real signal buried in a condition nobody's default view shows.
#
# Failing the KCL evaluation itself is the loud option: a fatal pipeline
# result surfaces as Synced=False on the SQLInstance itself -- the resource
# the developer asked for -- visible on every plain `kubectl get sqlinstance`
# via the SYNCED column, carrying this message.
#
# It does NOT propagate usefully to the parent App, though -- confirmed
# against a real Crossplane on an ephemeral kind cluster, not just
# `crossplane render`. An App composing this stub shows SYNCED=True,
# READY=False, Reason=Creating, "Unready resources: ...", indefinitely --
# ordinary-looking provisioning, not "this can never succeed". Root cause is
# in apis/app/kcl/main.k: the SQLInstance block doesn't read the child's own
# status via `ocds` the way the Deployment/Service blocks do, so the App
# never learns the child is Synced=False, only that it isn't Ready yet. Fixing
# that is out of this stub's scope. The loud signal lives on the SQLInstance
# itself; check it directly, don't infer from the App's status alone.
#
# Delete this file and its Composition when the real one lands.
assert False, "SQLInstance has no GCP implementation yet (workstream 9 brings CNPG with barman backups to GCS)."

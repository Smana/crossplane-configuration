## Backup archive layout

Each cluster generation writes to its own prefix, keyed by the XR uid:

```
s3://<bucket>/
  xplane-zitadel-cnpg-cluster-a1b2c3d4/   generation N
  xplane-zitadel-cnpg-cluster-9f8e7d6c/   generation N+1, empty on create
  zitadel-20260902/                       frozen seed, read-only
```

Recovery is unaffected: it reads `spec.objectStoreRecovery.path` explicitly and
never touches a live archive.

### Upgrading a RUNNING cluster

Bumping to this version under a running cluster changes its `serverName`
mid-life. Archiving moves to a new empty prefix and its existing base backups
are orphaned from every subsequent WAL, so **PITR breaks across that boundary**.

Bump the pin while rebuilding, or take a fresh base backup immediately after.

# speedscale-namespaced

Speedscale capture and replay confined to a **single Kubernetes namespace**.

This chart exists for clusters where the classic `speedscale-operator` chart
cannot be installed: environments that forbid cluster-scoped grants, CRDs, or
admission webhooks. It renders the same forwarder and inspector, plus a replay
coordinator that drives replays from labeled ConfigMaps instead of a
`TrafficReplay` custom resource.

> This is a **separate, hand-written chart**. It does not supersede, and shares
> no templates with, the published `speedscale-operator` charts under
> `charts/`. Per the S-12913 spike decision the templates are written by hand
> and kept honest by a parity harness
> (`operator/controlplane/parity` in the Speedscale monorepo), not generated.

---

## What it will never render

| | |
|---|---|
| `Namespace` | installing one needs cluster-scoped write |
| `CustomResourceDefinition` | cluster-scoped, and shared with every other install |
| `MutatingWebhookConfiguration` / `ValidatingWebhookConfiguration` | intercepts every API call in the cluster |
| `ClusterRole` / cluster role bindings | the exact grant this chart exists to avoid |
| `DaemonSet` | schedules a pod on every node |
| `SecurityContextConstraints`, `PriorityClass` | cluster-scoped policy |
| `hostPID`, `hostNetwork` | node-level escape |
| third-party custom resources | makes the chart depend on an operator you may not have |

This is not a promise, it is a test. `tests/denylist.sh` renders the chart across
a matrix of values permutations and two release namespaces and fails on any of
the above, on any object whose `metadata.namespace` is not the release
namespace, and on any `apiVersion` outside `v1`, `apps/v1`, `batch/v1`,
`rbac.authorization.k8s.io/v1`, `networking.k8s.io/v1`, `policy/v1`. It runs in
CI on every push (`.github/workflows/namespaced-chart.yml`).

---

## Prerequisites

### The namespace must already exist

The chart renders **no `Namespace` object**, so the target namespace has to be
created before install:

```bash
kubectl create namespace speedscale
```

> **Do not use `helm install --create-namespace`.**
>
> It works, and that is the problem: it makes the install look like it needs
> namespace-create rights, which is exactly the permission a namespaced install
> is meant to prove it does not need. Somebody reviewing the install command
> will reasonably conclude the chart creates cluster-scoped objects. Create the
> namespace out of band, with whatever process already governs namespaces in
> your cluster, and install into it.

### The API key Secret must already exist

The chart **never creates** the API key Secret; it references one by name.

```bash
kubectl -n speedscale create secret generic speedscale-apikey \
  --from-literal=SPEEDSCALE_API_KEY=<your-key> \
  --from-literal=SPEEDSCALE_APP_URL=app.speedscale.com
```

Point `apiKeySecret` at a different name if your platform provisions it
elsewhere (sealed-secrets, external-secrets, vault agent).

### Kubernetes 1.21+, Helm 3+

---

## Install

```bash
helm install speedscale ./speedscale-namespaced \
  --namespace speedscale \
  --set clusterName=my-cluster
```

---

## Values

Full annotated defaults in [`values.yaml`](./values.yaml), validated by
[`values.schema.json`](./values.schema.json). The ones that matter most:

| Value | Default | Notes |
|---|---|---|
| `clusterName` | `my-cluster` | as it appears in the Speedscale dashboard |
| `apiKeySecret` | `speedscale-apikey` | referenced, **never created** |
| `instanceID` | `""` | one shared id: `PROCESS_ID` for forwarder + inspector, `INSTANCE_ID` for the replay coordinator; derived when empty |
| `image.registry` / `image.tag` | `gcr.io/speedscale` / `v2.5.878` | |
| `image.pullSecrets` | `[]` | referenced, never created |
| `forwarder.enabled` | `true` | |
| `forwarder.telemetryInterval` | `1m0s` | Go `time.Duration` **String() form** — `60s` and `1m0s` are the same duration but not the same string, and the value is copied verbatim into the ConfigMap |
| `inspector.enabled` | `true` | |
| `inspector.metricsEnabled` | `false` | namespaced `metrics.k8s.io` read — opt-in, see below |
| `inspector.jobsEnabled` | `true` | namespaced `batch/jobs` read |
| `replayCoordinator.enabled` | `true` | |
| `replayCoordinator.leaseEnabled` | `false` | `coordination.k8s.io` Lease |
| `replayRuntime.enabled` | `true` | static SA + Role for generator/responder/collector |
| `replayRuntime.metricsEnabled` | `false` | namespaced `metrics.k8s.io` read — opt-in, see below |
| `secretAccessList` | `[]` | empty means **no Secret rule at all** |
| `capture.forwarderServiceName` | `speedscale-forwarder` | not yet wired to the operator — see values.yaml |
| `capture.enableDiagnostics` | `false` | not yet wired to the operator — see values.yaml. Once it is, turning it (or `reinitializeIptables`) on adds `NET_ADMIN` to the long-running sidecar |
| `capture.reinitializeIptables` | `false` | wired — becomes `SIDECAR_REINITIALIZE_IPTABLES`, read by `operator/settings` |
| `tls.create` | `true` | renders `speedscale-certs` |
| `tls.certsSecret` | `""` | required when `tls.create: false` |
| `tls.createJKS` | `false` | renders the keystore Secret + a root-running hook Job |
| `uninstall.enabled` | `true` | `pre-delete` cleanup Job |
| `uninstall.cleanupTimeout` | `5m` | whole `h`/`m`/`s`; also the Job's `activeDeadlineSeconds` |
| `uninstall.forceCleanupOnUninstall` | `false` | let uninstall proceed when cleanup fails |
| `networkPolicy.enabled` | `false` | |
| `pdb.enabled` | `false` | at `replicas: 1` a PDB blocks node drains rather than protecting anything |
| `tenant.*` | `""` | cloud-issued identity — see below |

### Pod metrics are opt-in, in both places

`inspector.metricsEnabled` and `replayRuntime.metricsEnabled` are the only two
values that add a `metrics.k8s.io` rule, and both default to **off**. That is not
caution for its own sake — it is what makes the chart installable by the person
it is written for:

* **RBAC escalation prevention.** Kubernetes refuses to let a subject create a
  `Role` granting a permission the subject does not itself hold. A namespace
  admin who has never been granted `metrics.k8s.io/pods` therefore cannot
  `helm install` a chart that unconditionally renders that rule — the install
  fails at Role creation, not at runtime.
* **Clusters without metrics-server have no such API group at all**, so on those
  clusters *nobody* can create the rule, escalation check or not.

Turn either on only if your installing identity already holds
`metrics.k8s.io/pods` read in the namespace. Leaving them off costs per-pod
CPU/memory enrichment in reports and nothing else: the consumer degrades on a
403 or a missing API rather than failing the replay.

### Tenant identity is not yet resolved

`tenant.id`, `.name`, `.bucket`, `.region`, `.stream` are issued by the
Speedscale cloud in exchange for the API key at startup. No value for them
exists when `helm template` runs, so the chart renders them empty and neither
the forwarder nor the replay coordinator will become ready until they are
supplied. **S-12914** owns how a namespaced install obtains them. Until it
lands, pass them explicitly — and pass **all five**:

```bash
helm upgrade speedscale ./speedscale-namespaced -n speedscale \
  --set tenant.id=... --set tenant.name=... --set tenant.bucket=... \
  --set tenant.region=... --set tenant.stream=...
```

A partial set is the same as none. The components consider their identity
resolved only when the stream *and* all four root-tenant fields (id, name,
region, bucket) are non-empty, so setting just `tenant.id` and `tenant.name`
leaves them exactly as unready as setting nothing.

---

## Uninstall

```bash
helm -n speedscale uninstall speedscale
```

A `pre-delete` Job returns instrumented workloads to their original state
first, within `uninstall.cleanupTimeout`. It runs the operator image's
`namespaced-cleanup` subcommand (**S-12933**). If it fails, the uninstall fails
and the release stays — set `uninstall.forceCleanupOnUninstall=true` to proceed
anyway, at the cost of leaving Speedscale sidecars behind, or
`uninstall.enabled=false` to skip the hook entirely.

An image older than that subcommand exits non-zero and blocks the uninstall the
same way.

### Cleaning up after a failed uninstall hook

The Job carries `ttlSecondsAfterFinished: 60`, which the TTL controller applies
to a **successful** Job. A Job that fails is left in place on purpose — its pod
logs are the only record of why the uninstall refused — and Helm will not remove
it, because the release it belonged to was never deleted. Read the logs, fix the
cause, then delete the Job before retrying:

```bash
kubectl -n speedscale logs job/speedscale-uninstall
kubectl -n speedscale delete job speedscale-uninstall
helm -n speedscale uninstall speedscale
```

The Job's `helm.sh/hook-delete-policy` includes `before-hook-creation`, so a
retry would replace it anyway; deleting it by hand just makes the next attempt's
logs unambiguous.

---

## Security review pack

[`evidence/`](./evidence/) is the M0 customer deliverable, regenerated from the
templates by `evidence/generate.sh`:

* `rendered-default.yaml` — full `helm template` output with default values
* `rendered-all-features.yaml` — every optional feature on at once
* [`RBAC-SUMMARY.md`](./evidence/RBAC-SUMMARY.md) — every Role rule, by identity, with justification
* [`CAPABILITIES.md`](./evidence/CAPABILITIES.md) — `NET_ADMIN`/`NET_RAW`, Pod Security exemptions, images, Secrets, network flows

---

## Development

```bash
helm lint speedscale-namespaced
helm template speedscale ./speedscale-namespaced -n speedscale

./speedscale-namespaced/tests/denylist.sh                     # check the chart
DENYLIST_SELFTEST=1 ./speedscale-namespaced/tests/denylist.sh # check the checks

./speedscale-namespaced/evidence/generate.sh                  # refresh the pack
```

Add a values permutation by dropping a file in `tests/values/`; the denylist
picks it up automatically. Add a check by adding a fixture to `tests/selftest/`
named for the check id it must trip — a check with no fixture, or a fixture that
trips nothing, fails the self-test.

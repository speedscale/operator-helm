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
| `instanceID` | `""` | shared `PROCESS_ID` for forwarder + inspector; derived when empty |
| `image.registry` / `image.tag` | `gcr.io/speedscale` / `v2.5.878` | |
| `image.pullSecrets` | `[]` | referenced, never created |
| `forwarder.enabled` | `true` | |
| `forwarder.telemetryInterval` | `1m0s` | Go `time.Duration` **String() form** — `60s` and `1m0s` are the same duration but not the same string, and the value is copied verbatim into the ConfigMap |
| `inspector.enabled` | `true` | |
| `inspector.metricsEnabled` | `false` | namespaced `metrics.k8s.io` read |
| `inspector.jobsEnabled` | `true` | namespaced `batch/jobs` read |
| `replayCoordinator.enabled` | `true` | |
| `replayCoordinator.leaseEnabled` | `false` | `coordination.k8s.io` Lease |
| `replayRuntime.enabled` | `true` | static SA + Role for generator/responder/collector |
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

### Tenant identity is not yet resolved

`tenant.id`, `.name`, `.bucket`, `.region`, `.stream` are issued by the
Speedscale cloud in exchange for the API key at startup. No value for them
exists when `helm template` runs, so the chart renders them empty and the
forwarder will not become ready until they are supplied. **S-12914** owns how a
namespaced install obtains them. Until it lands, pass them explicitly.

---

## Uninstall

```bash
helm -n speedscale uninstall speedscale
```

A `pre-delete` Job returns instrumented workloads to their original state
first, within `uninstall.cleanupTimeout`. If it fails, the uninstall fails and
the release stays — set `uninstall.forceCleanupOnUninstall=true` to proceed
anyway, at the cost of leaving Speedscale sidecars behind.

> The cleanup entrypoint itself ships under **S-12933**. Until then the Job
> invokes a documented placeholder command that does not exist, so an uninstall
> will block unless you set `uninstall.forceCleanupOnUninstall=true` or
> `uninstall.enabled=false`.

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

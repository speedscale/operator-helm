# RBAC summary — `speedscale-namespaced`

Every permission this chart grants, by identity, with the reason it exists.

**Scope claim.** The chart renders no `ClusterRole`, no cluster role binding, and
no cluster-scoped object of any kind. Every `Role` and `RoleBinding` below is
namespaced to the release namespace, and every `RoleBinding` has
`roleRef.kind: Role`. `tests/denylist.sh` fails the build on any exception, and
its self-test mode (`DENYLIST_SELFTEST=1`) proves that check is live rather than
vacuous.

Generated against the templates that produced `rendered-default.yaml` and
`rendered-all-features.yaml` in this directory. Regenerate both with
`evidence/generate.sh` after any template change.

---

## Identities

| ServiceAccount | Role | Lifetime | Installed by default |
|---|---|---|---|
| `speedscale-forwarder` | `speedscale-forwarder` | release | yes |
| `speedscale-inspector` | `speedscale-inspector` | release | yes |
| `speedscale-replay-coordinator` | `speedscale-replay-coordinator` | release | yes |
| `speedscale` (replay runtime) | `speedscale` | release | yes |
| `speedscale-uninstall` | `speedscale-uninstall` | `pre-delete` hook only | yes |
| `speedscale-jks` | `speedscale-jks` | `post-install`/`post-upgrade` hook only | no (`tls.createJKS`) |

The inspector and replay-runtime account names are configurable
(`inspector.serviceAccountName`, `replayRuntime.serviceAccountName`); the rest
are fixed because other components look them up by name.

---

## 1. Forwarder — `speedscale-forwarder`

Receives captured traffic from sidecars and ships it to the Speedscale cloud.

| API group | Resources | Verbs | resourceNames | Why |
|---|---|---|---|---|
| core | `pods`, `services` | get, list, watch | — | Attribute a captured connection to a workload instead of an IP. Without it every recorded call is labelled by pod IP, which is meaningless once the pod is replaced. |
| core | `configmaps` | get, list, watch | `speedscale-forwarder`, `speedscale-forwarder-dlp`, `speedscale-forwarder-filter` | Its own configuration only. The DLP and filter ConfigMaps are optional mounts it re-reads without restarting; the chart lets it see them if they appear (S-12539 writes the DLP one). |

**No Secret access.** The API key reaches the forwarder as `envFrom.secretRef`,
which the kubelet resolves — the pod's own identity never reads a Secret through
the API.

**No write verbs at all.**

---

## 2. Inspector — `speedscale-inspector`

Answers "what is in this namespace" for the Speedscale dashboard and proxymock.
Read-only in its entirety.

| API group | Resources | Verbs | Gated by | Why |
|---|---|---|---|---|
| core | `pods`, `pods/log`, `events`, `services`, `configmaps` | get, list, watch | always | Workload inventory, container logs for triage, and the events that explain a pod that will not start. |
| apps | `deployments`, `statefulsets`, `replicasets` | get, list, watch | always | The workloads a user can select as a replay target, and the ReplicaSets needed to tell a rollout from a restart. |
| batch | `jobs` | get, list, watch | `inspector.jobsEnabled` (default on) | Jobs appear in the namespace inventory. Turn off in a namespace where Job metadata is itself sensitive. |
| metrics.k8s.io | `pods` | get, list, watch | `inspector.metricsEnabled` (default **off**) | Per-pod CPU/memory for report enrichment. Off by default: a cluster without metrics-server has no such API, and the resulting 403 must degrade enrichment rather than fail anything. |
| core | `secrets` | get, list, watch | non-empty `secretAccessList` (default **empty**) | Test-variable substitution. **There is no blanket `secrets` rule anywhere in this chart** — each name in `secretAccessList` is granted individually via `resourceNames`, so this table is the complete list of Secrets Speedscale can read. |

**Deviation from the classic install.** At runtime the operator gives the
inspector *its own* ServiceAccount, because the operator already holds the
cluster-scoped rights the inspector needs and minting a second cluster role was
the worse trade. A namespaced install has no operator account to borrow, so the
inspector gets a dedicated account and this Role. Recorded as a reviewed parity
exemption (S-12915) in `operator/controlplane/parity/parity_exemptions.yaml`.

---

## 3. Replay coordinator — `speedscale-replay-coordinator`

The widest identity the chart installs, and still confined to one namespace. It
drives replays from labeled ConfigMaps rather than a `TrafficReplay` custom
resource, because a namespaced install may not install a CRD.

| API group | Resources | Verbs | Why |
|---|---|---|---|
| core | `configmaps` | get, list, watch, create, update, patch, delete | Replay requests, the mutation inventory recording what was changed on a workload, and the snapshot payload are all ConfigMaps. With no CRD available, labeled ConfigMaps **are** the replay API. |
| core | `services` | get, list, watch, create, update, patch, delete | The responder Service each replay stands up, whose cluster IP the sidecar injection needs. |
| core | `pods`, `pods/log`, `events` | get, list, watch | Report replay progress from the generator/responder/collector pods. |
| core | `pods` | delete | Tear down a replay's pods. **No pod `create`** — pods only ever arrive via the Deployment and Job rules below, so nothing can start an arbitrary pod. |
| core | `secrets` | get, list, watch | Mount configured credentials into replay components. `resourceNames` only: the API key Secret, the TLS Secret, the JKS Secret when enabled, plus every name in `secretAccessList`. Never a blanket rule. |
| apps | `deployments` | get, list, watch, create, update, patch, delete | Create and remove the responder Deployment, and patch the workload under test to add/remove the Speedscale sidecar. |
| batch | `jobs` | get, list, watch, create, update, patch, delete | The generator runs as a Job, created and removed per replay. |
| apps | `statefulsets` | get, list, watch, update, patch | Patch a StatefulSet target and restore it afterwards. **No create, no delete** — the coordinator must never be able to destroy a customer workload. |
| apps | `replicasets` | get, list, watch | Tell whether a patched rollout actually converged. Read-only; a ReplicaSet is owned by its Deployment. |
| coordination.k8s.io | `leases` | get, list, watch, create, update, patch | Only when `replayCoordinator.leaseEnabled` (default **off**). The single-replica deployment holds its workload lease in memory; a Lease is needed only once the coordinator elects a leader across replicas. |

### Verbs deliberately withheld

* **No RBAC management.** No verb on `roles`, `rolebindings`, `serviceaccounts`,
  or anything in `rbac.authorization.k8s.io`. A replay that could mint its own
  permissions is a privilege-escalation primitive. This is possible only because
  the chart pre-creates the one Role a replay needs (identity 4 below); the
  classic operator provisions that Role per replay and therefore *must* hold
  RBAC-write.
* **No `statefulsets` create/delete**, per the table.
* **No namespace, node, CRD, or webhook access of any kind.**

### Known coarseness, stated plainly

The `apps/deployments` rule carries `delete` and applies to *every* Deployment in
the namespace, not only the responder Deployments the coordinator created.
Kubernetes RBAC can only narrow this with `resourceNames`, and the names of
replay-created Deployments are not knowable when the chart renders. An operator
who wants a hard boundary should install this chart in a namespace that contains
only Speedscale and the workloads under test — which is the intended deployment
model anyway.

---

## 4. Replay runtime — `speedscale`

The identity the replay's own pods run as: generator, responder, collector.

| API group | Resources | Verbs |
|---|---|---|
| metrics.k8s.io | `pods` | get, list, watch |
| core | `pods` | get, list, watch |
| core | `events` | get, list, watch |
| core | `pods/log` | get, list |

These four rules are a transcription of `build.StaticReplayRuntimeRules()` in
`lib/kube/build/rbac.go`. `lib/kube/build/rbac_test.go` pins them against
`ReplayRole`'s actual output — not a hand-copied literal — so the chart-owned
static Role and the Role the operator still provisions at runtime cannot drift
apart, and collector/report enrichment behaves identically under either path.

Rendering this Role once per namespace, instead of provisioning it per
ephemeral replay, is what lets the coordinator hold no RBAC-write verbs at all.

`metrics.k8s.io` access is best-effort: a cluster without the metrics API simply
does not authorize it, and the consumer degrades rather than failing the replay.

**No Secret access. No write verbs. No wildcard API groups.**

---

## 5. Uninstall hook — `speedscale-uninstall`

Runs as a `pre-delete` Job, then the ServiceAccount, Role and RoleBinding are
deleted with it.

| API group | Resources | Verbs | Why |
|---|---|---|---|
| core | `configmaps` | get, list, watch, create, update, patch | Signal in-flight replays to wind down through the same labeled ConfigMaps that are the replay API, and leave a record of anything that could not be cleaned up. |
| core | `pods`, `services` | get, list, watch | Decide whether cleanup finished. |
| apps | `deployments`, `statefulsets` | get, list, watch | Same — read-only. |
| batch | `jobs` | get, list, watch | Same — read-only. |

Deliberately **narrower than the coordinator's**, because an uninstall runs
unattended at the least convenient moment:

* **No workload patch.** It cannot touch a Deployment or StatefulSet spec, so a
  half-finished uninstall cannot leave a customer workload mid-mutation.
* **No delete on anything.** Helm removes the release's own objects; this hook
  signals and reports, it does not garbage-collect.
* **No Secret access.**

The cleanup entrypoint itself ships under **S-12933**. The Job renders today
against a documented placeholder command (`operator namespaced-cleanup`), marked
as such in `templates/uninstall.yaml`, so the hook wiring, the RBAC and the
timeout are reviewable before the logic lands.

---

## 6. JKS hook — `speedscale-jks`

Only rendered when `tls.createJKS` is set (default off). Runs as a
`post-install`/`post-upgrade` Job.

| API group | Resources | Verbs | resourceNames |
|---|---|---|---|
| core | `secrets` | get, update, patch | `speedscale-jks` (or `tls.jksSecret`) |

Exactly one Secret, by name, and **no `create`, no `delete`**. The keystore
Secret is rendered by the chart itself, so this identity only ever fills one in
place. It cannot mint new Secrets, and it cannot destroy the API key or the TLS
certificates.

This is also the only pod in the chart that runs as root — `keytool` writes into
the JVM's root-owned trust store — which is why the whole feature is opt-in.

---

## What no identity in this chart can do

* Read, create or modify anything outside the release namespace.
* Read a Secret that is not named in this document.
* Create, modify or delete any `Role`, `RoleBinding` or `ServiceAccount`.
* Create, modify or delete a `Namespace`, `CustomResourceDefinition`, webhook
  configuration, `ClusterRole`, cluster role binding, `DaemonSet`,
  `SecurityContextConstraints` or `PriorityClass`.
* Read `nodes`, `namespaces`, or any cluster-scoped resource.
* Delete a customer StatefulSet, or delete any Secret.

# Capabilities, images, secrets and network — `speedscale-namespaced`

The non-RBAC half of the security review: what runs privileged and why, which
images are pulled, which Secrets are touched, and what has to be reachable.
RBAC is in [RBAC-SUMMARY.md](./RBAC-SUMMARY.md).

---

## 1. Linux capabilities

### The control plane needs none

Every pod this chart renders — forwarder, inspector, replay coordinator, and the
uninstall hook — runs under `globalPodSecurityContext`, which by default is:

```yaml
runAsNonRoot: true
allowPrivilegeEscalation: false
privileged: false
readOnlyRootFilesystem: true
runAsUser: 2100
runAsGroup: 2100
seccompProfile:
  type: RuntimeDefault
capabilities:
  drop: [ALL]
```

`capabilities.add` is empty. No control-plane pod uses `hostNetwork`, `hostPID`,
`hostIPC`, a host path mount, or a privileged container. `tests/denylist.sh`
fails the build if `hostNetwork` or `hostPID` ever appears set to true.

The one exception is the **JKS hook** (`tls.createJKS`, default off): `keytool`
writes into the JVM's root-owned trust store, so that Job's pod runs
`runAsNonRoot: false`, `runAsUser: 0`. It still drops `ALL` capabilities, keeps
`allowPrivilegeEscalation: false` and `privileged: false`, and exists only for
the seconds the hook runs.

### Capture DOES need NET_ADMIN and NET_RAW — on the workload, not here

This is the part that matters for a Pod Security review, and it is worth being
precise about *where* it applies: **the chart itself renders nothing with these
capabilities.** They are requested on the *instrumented application's* pod, at
the moment a replay or a capture instruments it, by the sidecar injection the
replay coordinator performs.

| Container | Image | Capabilities added | When |
|---|---|---|---|
| `speedscale-init-iptables` (init) | `goproxy` | `NET_RAW`, `NET_ADMIN` | Transparent proxy modes — the ones that rewrite the pod's `nat` table |
| `speedscale-init-smartdns` (init) | `goproxy` | `NET_RAW`, `NET_ADMIN` | Unless smart DNS is disabled |
| `speedscale-goproxy` (sidecar) | `goproxy` | `NET_RAW` | Always |
| `speedscale-goproxy` (sidecar) | `goproxy` | `NET_RAW` **and** `NET_ADMIN` | Only when `capture.reinitializeIptables` is on |

Why each is needed:

* **`NET_ADMIN`** — the init container programs `iptables` rules inside the
  pod's own network namespace to redirect the application's traffic through the
  proxy. This is the same mechanism Istio's `istio-init` uses. It is confined to
  the pod's network namespace; it does not touch the node's.
* **`NET_RAW`** — the proxy opens raw sockets to observe and re-emit packets it
  did not originate.

Both init containers run `runAsUser: 0` with `allowPrivilegeEscalation` and
`privileged` following `privilegedSidecars` (false by default). The long-running
sidecar runs as the unprivileged `goproxy` user, and holds only `NET_RAW` unless
`capture.reinitializeIptables` is turned on.

`capture.enableDiagnostics` is NOT in this table: as of the S-12919 config-key
sync follow-up it is confirmed not wired to the operator at all (no field on
`build.SidecarConfigOverride` exists to carry an install-wide default for it),
so today it cannot affect a running sidecar's capabilities regardless of its
value. See `capture.enableDiagnostics` in values.yaml.

**The narrowest configuration:** leave `capture.reinitializeIptables` at its
default (`false`) and the sidecar that runs for the whole life of the
instrumented pod holds `NET_RAW` alone — `NET_ADMIN` is then held only by an
init container that exits before the application starts.

### Pod Security Admission exemption required

The control-plane namespace is compatible with the **`restricted`** Pod Security
Standard, with one caveat: `tls.createJKS` renders a root-running Job, so a
namespace enforcing `restricted` must either leave `createJKS` off or exempt
that one Job.

Namespaces containing **instrumented workloads** cannot run under `restricted`
or `baseline`, because both forbid adding `NET_ADMIN`. Those namespaces need:

```yaml
pod-security.kubernetes.io/enforce: privileged
```

or, preferably, a narrower exemption in your admission policy engine
(Kyverno/Gatekeeper) scoped to pods carrying the Speedscale sidecar. On
OpenShift the equivalent is a `SecurityContextConstraints` allowing
`NET_ADMIN`/`NET_RAW` — **this chart deliberately does not render one**, because
an SCC is cluster-scoped; a cluster administrator must apply it separately.

---

## 2. Images

All pulled from `.Values.image.registry` (default `gcr.io/speedscale`) at
`.Values.image.tag`, with `.Values.image.pullSecrets` if set.

### Rendered by the chart

| Image | Used by | Runs |
|---|---|---|
| `<registry>/forwarder:<tag>` | forwarder Deployment | continuously |
| `<registry>/inspector:<tag>` | inspector Deployment | continuously |
| `<registry>/operator:<tag>` | replay coordinator Deployment | continuously |
| `<registry>/operator:<tag>` | uninstall `pre-delete` Job | seconds, at uninstall |
| `<registry>/amazoncorretto:23` | JKS `post-install` Job | seconds, only when `tls.createJKS` |

The JKS image is `.Values.tls.jks.image`, prefixed with the same registry, so an
air-gapped mirror needs no separate setting.

### Pulled at replay time, not by the chart

The coordinator creates these when a replay runs. They are listed because an
air-gapped or allowlisted registry needs all of them mirrored:

| Image | Role |
|---|---|
| `<registry>/generator:<tag>` | drives the replay |
| `<registry>/responder:<tag>` | mocks the backends |
| `<registry>/collector:<tag>` | gathers results |
| `<registry>/goproxy:<tag>` | init containers + sidecar injected into the workload |
| `<registry>/redis:<tag>` | replay-local state |

**Not used by this chart:** `nettap` (eBPF capture) requires a DaemonSet and
node-level access, which a namespaced install cannot have.

---

## 3. Secrets

### Referenced, never created

| Secret | Default name | Contents | Who reads it |
|---|---|---|---|
| API key | `apiKeySecret`, default `speedscale-apikey` | `SPEEDSCALE_API_KEY`, `SPEEDSCALE_APP_URL` | forwarder, inspector, coordinator — via `envFrom.secretRef`, resolved by the kubelet |

**The chart never renders the API key Secret.** It must exist in the namespace
before install. This is deliberate: a namespaced install is expected in an
environment where credentials come from sealed-secrets, external-secrets, a
vault agent, or a deliberate `kubectl create secret` — not from a value that
ends up in a Helm release, in shell history and in CI logs.

```bash
kubectl -n <ns> create secret generic speedscale-apikey \
  --from-literal=SPEEDSCALE_API_KEY=<key> \
  --from-literal=SPEEDSCALE_APP_URL=app.speedscale.com
```

### Rendered by the chart

| Secret | Rendered when | Contents |
|---|---|---|
| `speedscale-certs` | `tls.create` (default on) | `tls.crt`, `tls.key`, `ca.crt` — a self-signed CA and a leaf covering the in-namespace forwarder/inspector Service DNS names |
| `tls.jksSecret` (default `speedscale-jks`) | `tls.createJKS` (default off) | `cacerts.jks` — a Java trust store containing the CA above, written by the hook Job |

Certificate material is generated once and reused: the template looks the Secret
up before generating, so `helm upgrade` does **not** rotate the CA out from under
workloads already trusting it. Set `tls.create: false` and `tls.certsSecret:
<name>` to supply your own PKI from cert-manager or vault instead.

The rendered evidence in this directory has all three certificate values
redacted by `generate.sh` — a private key does not belong in a repository even
when it is a throwaway.

### Secrets read through the Kubernetes API

Only what `RBAC-SUMMARY.md` enumerates by `resourceNames`. `secretAccessList` is
empty by default, which means the inspector gets **no** `secrets` rule at all.

---

## 4. Network

### Egress to the Speedscale cloud

| From | To | Port | Purpose |
|---|---|---|---|
| forwarder | `app.speedscale.com` (`.Values.appUrl`) | 443/TCP | ships captured traffic and telemetry |
| inspector | `app.speedscale.com` | 443/TCP | registration, cluster inventory reporting |
| replay coordinator | `app.speedscale.com` | 443/TCP | snapshot retrieval, report upload |

This is the only traffic that leaves the cluster. Resolution goes through
cluster DNS (53/TCP+UDP).

### In-cluster

| From | To | Port | Purpose |
|---|---|---|---|
| `goproxy` sidecar in an instrumented pod | `speedscale-forwarder` Service | 8888/TCP (Service port 80) | captured traffic, gRPC |
| OTLP producers (nettap, OTel collectors) | `speedscale-forwarder` Service | 4317/TCP | OTLP ingest |
| inspector | instrumented **pod IP** directly | 4144/TCP | sidecar readiness probe (`GET http://<podIP>:4144/ready`) |
| Speedscale dashboard, via port-forward | `speedscale-inspector` Service | 8080/TCP (Service port 80) | HTTP inventory API |
| generator | responder Service | replay-dependent | mocked backends during replay |
| all components | kube-apiserver | 443/TCP | the RBAC in `RBAC-SUMMARY.md` |

The **inspector → pod-IP:4144** hop is the one that surprises people: it is a
direct dial to the pod IP, not through a Service. A CNI or NetworkPolicy that
permits only Service-mediated traffic will break sidecar readiness detection
while everything else appears to work.

### NetworkPolicies

`networkPolicy.enabled` (default **off**) renders namespaced policies for the
forwarder and inspector covering exactly the flows above: pod-selector ingress
in-namespace, DNS egress, pod-IP:4144 egress for the inspector, and 443 egress
to the cloud with RFC1918 ranges excluded so the cloud rule cannot quietly
become an east-west wildcard.

They are off by default on purpose. A policy that is wrong for your CNI silently
breaks capture, and a namespace with no policies is not made less safe by this
chart declining to add one. Instrumented workloads in **other** namespaces need
an entry in `networkPolicy.extraForwarderIngressFrom` — the default in-namespace
pod selector will not reach them.

---

## 5. What this chart cannot do, by construction

* Install a `Namespace`, `CustomResourceDefinition`, `MutatingWebhookConfiguration`,
  `ValidatingWebhookConfiguration`, `ClusterRole`, cluster role binding,
  `DaemonSet`, `SecurityContextConstraints` or `PriorityClass`.
* Render any object with an `apiVersion` outside `v1`, `apps/v1`, `batch/v1`,
  `rbac.authorization.k8s.io/v1`, `networking.k8s.io/v1`, `policy/v1` — which
  rules out every third-party custom resource.
* Render an object into a namespace other than the release namespace.
* Run anything with `hostNetwork` or `hostPID`.
* Capture traffic with eBPF: `nettap` needs a DaemonSet and node access.
* Intercept pod creation cluster-wide: there is no admission webhook, so
  instrumentation happens only when a replay explicitly patches a workload.

All six are enforced by `tests/denylist.sh` on every push, across a matrix of
values permutations and release namespaces, and the script's `DENYLIST_SELFTEST=1`
mode proves each check fires against a deliberately broken fixture.

---

## 6. Open items a reviewer should know about

* **Tenant identity.** `tenant.*` is issued by the Speedscale cloud in exchange
  for the API key at startup, so no value exists when `helm template` runs. It
  renders empty and the forwarder will not become ready until supplied.
  **S-12914** owns how a namespaced install resolves it.
* **Namespaced-mode switch.** The coordinator Deployment sets
  `SPEEDSCALE_NAMESPACED_MODE=true`. That name is this chart's proposal and must
  be confirmed against the startup path landing under **S-12919**.
* **Uninstall entrypoint.** The `pre-delete` Job invokes `operator
  namespaced-cleanup`, which does not exist yet — it ships under **S-12933**.
  Until then the Job fails, which blocks `helm uninstall` unless
  `uninstall.forceCleanupOnUninstall=true` or `uninstall.enabled=false`.

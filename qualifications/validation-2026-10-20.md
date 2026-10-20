# Released operator upgrade validation, 2026-10-20

Minikube passed a real v2.5.1206 to v2.5.1207 upgrade using genuine released container images pinned to retrievable OCI/Docker v2 manifest digests. v2.5.1206 is the currently promoted production version. v2.5.1207 is a genuine release-tagged candidate; this PR does not advertise it in the production upgrade catalog.

The executor was compiled from exact v2.5.1206 source (`79134d7c5`) with only the qualification test overlaid. Its mutations used the actual upgrader service account. Independent recovery Jobs ran the actual released v2.5.1206 operator image and the chart's existing upgrader permissions. The target package was generated from exact v2.5.1207 source (`08b149759`). No invented release versions or fixture workloads were substituted for the operator and managed components.

The production source package retains its existing SHA-256 `b42f640774e348573738a470b3927ee2a93e4d5649b18c582de886601352e0cd`. The exact tested candidate package has SHA-256 `91f050157ffdf7ab547fe3b4c11a5ab73762c338b9d28203ba9d8dec99bdd920`. The candidate report binds its image bundle and tested source in [candidate-v2.5.1207.json](candidate-v2.5.1207.json). Requalification is required if the final package bytes differ.

| Scenario | Verified result | Operation |
| --- | --- | --- |
| Bad target while registry access was disabled | OP_UPGRADE_ROLLED_BACK | `5de90178-6a60-49a5-99c2-285cffcc7c5c` |
| Executor process killed after Helm mutation | OP_UPGRADE_ROLLED_BACK | `92338822-8aea-4dab-b27d-486bf1ea73e2` |
| Inspector removed after the actual newer target became healthy | OP_UPGRADE_ROLLED_BACK | `a24397e7-5e9c-47ba-9ae7-ebf0c54832f3` |
| Clean upgrade and promotion of the new last known good version | OP_UPGRADE_SUCCEEDED | `bd8614f2-fdcf-4649-99af-a824d4bf2118` |

Each rollback verified the exact v2.5.1206 runtime image bundle, deployed Helm state, managed component readiness, and functional webhook health. The clean upgrade verified v2.5.1207 and promoted it to last known good only after the stability interval. Source and target admission tests verified injection of the approved goproxy digest. An independent canary retained the same pod UID with zero restarts throughout these upgrade and rollback tests.

A separate inspector-only failure during a same-version reapply verified the corrected recovery worker restores the saved inspector specification without changing the operator image: `OP_UPGRADE_ROLLED_BACK`, operation `6b513bd6-1fe8-4ea2-a7bb-505494b23045`. This regression used a locally built corrected recovery worker with genuine v2.5.1206 components. The fix is in https://gitlab.com/speedscale/speedscale/-/merge_requests/7228. The customer planning API continues to reject same-version targets.

Qualification used an ephemeral signed candidate catalog inside the driver before public promotion. The production signing key was not copied into the cluster, changed, or rotated. The runner restored the existing production trust policy and removed its test key, driver, temporary RBAC, and node files. The registry firewall fault, local regression registry, and independent canary were removed after verification. Minikube finished healthy on the genuine v2.5.1207 target with `OP_UPGRADE_SUCCEEDED`.

The signed production catalog remains the v2.5.1206 baseline with no incoming paths. Kraken adds a newer target when the release manifest promotes that version and exact-package qualification is supplied. https://gitlab.com/speedscale/kraken/-/merge_requests/805 preserves prepared package bytes, supports resuming publication from the retained CI artifact, and verifies the public catalog, signature, key, and chart after publication. This validation does not confirm a public Pages deployment; that is checked after this PR merges.

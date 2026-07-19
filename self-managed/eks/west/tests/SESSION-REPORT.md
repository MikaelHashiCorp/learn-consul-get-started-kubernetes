# EKS consul-eks Upgrade — Session Post-Mortem

**Date:** 2026-07-19  
**Cluster:** `consul-eks-7d` (us-west-2)  
**Objective:** Upgrade from Kubernetes 1.33 → 1.36; rebuild stack; achieve 57/57 e2e tests passing.  
**Outcome:** ✅ 57/57 tests passed (`./tests/run_e2e.zsh` exit 0)

---

## Executive Summary

A full rebuild of the `consul-eks` EKS workspace was required after upgrading the Terraform module
stack to EKS module v21 / AWS provider v6. Seven discrete root causes were encountered in sequence:
(1) EKS node groups could not join because EKS module v21 no longer installs core networking addons
by default; (2) the EBS CSI driver controller pod had no IAM credentials because OIDC provider
creation was blocked by missing `iam:CreateOpenIDConnectProvider` permission; (3) kubectl/API
authentication was absent because the developer IAM role had no access entry; (4) the initial Consul
Helm chart install used chart v2.0.2, which contains a missing `routeextprocs` CRD that caused
connect-injector crashes; (5) a Consul server image version mismatch triggered endpoint reconciler
panics; (6) the API Gateway HTTPRoute could not resolve its upstream because the required
`ReferenceGrant` was applied after the route was created; and (7) app pods injected by the old
controller carried a stale multi-port annotation that triggered an `index out of range [-1]` panic
loop in consul-k8s 1.9.10. All issues were resolved sequentially; the full test suite passed clean.

---

## Timeline

| UTC | Event |
|---|---|
| 05:57 | Old cluster `consul-eks-c7` destroyed; new cluster `consul-eks-7d` created (K8s 1.36 ACTIVE) |
| 06:33 | Node group `consul-eks-server-9cf6baf4d5f287413bee9514e4` created — immediately `CREATE_FAILED` |
| 17:01 | Failed node group deleted from AWS |
| 17:04 | Node group removed from Terraform state; `bootstrap_self_managed_addons` fix attempted (wrong param name) |
| 17:06 | Root cause confirmed: zero EKS addons; `addons {}` block added to `module "eks"` |
| 17:08 | `terraform apply` — node group `consul-eks-server-2aa6cd635b8aaadec01b882ff1` created ACTIVE in 108s |
| 17:12 | EBS CSI addon created; controller enters `CrashLoopBackOff` (no IAM credentials) |
| 17:54 | Root cause: `no EC2 IMDS role found` — no OIDC provider; Pod Identity path chosen |
| 18:00 | Pod Identity agent deployed; IAM role + association created; EBS CSI addon deleted and recreated |
| 18:05 | EBS CSI `ACTIVE` in 35s; `gp2` StorageClass annotated default |
| 18:06 | Consul Helm chart 2.0.2 installed; connect-injector enters CrashLoop (`routeextprocs` CRD missing) |
| 18:23 | Consul chart downgraded to 1.9.10 (consul image 1.22.7) |
| 18:37 | App pods rollout restarted; `product-api` causes injector panic loop |
| 19:31 | `product-api` scaled to 0; injector stabilises (12 restarts, no new crash) |
| 19:38 | `product-api` scaled back to 1; all app pods re-injected by consul-k8s 1.9.10 |
| 19:40 | `ReferenceGrant` applied; HTTPRoute deleted and recreated; API Gateway serving HTTP 200 |
| 19:40 | `./tests/run_e2e.zsh --no-doormat` → **57 passed / 0 failed** |

---

## Issues and Resolutions

### Issue 1 — Node Group CREATE_FAILED (EKS module v21: no networking addons)

**Severity:** Blocker  
**Confidence:** Confirmed

#### Symptoms

```
"code": "NodeCreationFailure",
"message": "Unhealthy nodes in the kubernetes cluster"
```

EC2 instances were `running` and EC2 health checks passed. EKS access entry for the node IAM
role existed with `type=EC2_LINUX` and `system:nodes` group. Cluster showed zero addons:

```json
{ "addons": [] }
```

#### Root Cause

EKS module v21 changed the default for `bootstrap_self_managed_addons` from `true` to `false`.
When this flag is false, `vpc-cni`, `kube-proxy`, and `coredns` are **not** installed automatically.
Without `vpc-cni`, nodes have no pod networking and cannot register with the Kubernetes API server.

The parameter was also renamed — the module v21 uses an `addons {}` map block rather than a
`bootstrap_self_managed_addons` boolean input.

#### Fix

Added to `module "eks"` in [`aws.tf`](aws.tf):

```hcl
addons = {
  vpc-cni = {
    before_compute = true   # installs before node group creation
    most_recent    = true
  }
  kube-proxy = {
    most_recent = true
  }
  coredns = {
    most_recent = true
  }
}
```

`before_compute = true` on `vpc-cni` is critical — it ensures CNI is active before nodes
attempt to join, preventing the networking race condition.

**Validation:** Node group reached `ACTIVE` status in 108 seconds on next `terraform apply`.

---

### Issue 2 — EBS CSI Driver CrashLoopBackOff (no IAM credentials)

**Severity:** Blocker  
**Confidence:** Confirmed

#### Symptoms

```
E  GRPC error: rpc error: code = FailedPrecondition desc = Failed health check
   (verify network connection and IAM credentials): dry-run EC2 API call failed:
   operation error EC2: DescribeAvailabilityZones, get identity: get credentials:
   failed to refresh cached credentials, no EC2 IMDS role found,
   operation error ec2imds: GetMetadata, canceled, context deadline exceeded
```

#### Root Cause

The Terraform workspace originally used IRSA (IAM Roles for Service Accounts via OIDC) for the
EBS CSI driver. IRSA requires `iam:CreateOpenIDConnectProvider`, which the
`aws_mikael.sikora_test-developer` role does not have.

The EBS CSI controller Deployment runs on the control plane (not on a node), so it cannot use EC2
instance metadata (IMDS) for credentials. Without IRSA or Pod Identity, it has no credential chain.

#### Fix — Phase 1: Node-level policy (attempted, insufficient)

Added `aws_iam_role_policy_attachment.ebs_csi_node` attaching `AmazonEBSCSIDriverPolicy` to the
managed node group IAM role. This grants node-level access but does not help the **controller**
Deployment which runs on the EKS control plane (not on a node).

#### Fix — Phase 2: EKS Pod Identity (successful)

1. Installed `eks-pod-identity-agent` addon manually (reached `ACTIVE` immediately).
2. Created IAM role with `pods.eks.amazonaws.com` trust policy:

```json
{
  "Effect": "Allow",
  "Principal": { "Service": "pods.eks.amazonaws.com" },
  "Action": ["sts:AssumeRole", "sts:TagSession"]
}
```

3. Attached `arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy`.
4. Created pod identity association for `kube-system/ebs-csi-controller-sa`.
5. Deleted the stuck EBS CSI addon and recreated it via `terraform apply`.

**Result:** EBS CSI controller reached `Running 6/6` in 35 seconds. Addon status `ACTIVE`.

Also added `enable_irsa = false` to the EKS module to prevent Terraform from attempting to
create an OIDC provider on future applies:

```hcl
enable_irsa = false
```

**Validation:** `kubectl get pods -n kube-system | grep ebs-csi-controller` → `6/6 Running`.

---

### Issue 3 — kubectl Authentication Failure (developer role not in access entries)

**Severity:** Blocker  
**Confidence:** Confirmed

#### Symptoms

```
error: You must be logged in to the server
(the server has asked for the client to provide credentials)
```

#### Root Cause

EKS module v21 defaults to `authentication_mode = "API_AND_CONFIG_MAP"` but does **not**
add the session caller (`aws_mikael.sikora_test-developer`) to the access entries list
automatically. Access entries present:

```
arn:aws:iam::189504808923:role/WizAccess-Role
arn:aws:iam::189504808923:role/aws-service-role/eks.amazonaws.com/AWSServiceRoleForAmazonEKS
arn:aws:iam::189504808923:role/consul-eks-server-eks-node-group-22de510000cb4d048bb2a0bda4
```

The developer role was absent.

#### Fix

```bash
aws eks create-access-entry \
  --cluster-name consul-eks-7d \
  --principal-arn arn:aws:iam::189504808923:role/aws_mikael.sikora_test-developer \
  --type STANDARD

aws eks associate-access-policy \
  --cluster-name consul-eks-7d \
  --principal-arn arn:aws:iam::189504808923:role/aws_mikael.sikora_test-developer \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

**Validation:** `kubectl get nodes` returned 3 `Ready` nodes immediately after.

---

### Issue 4 — Consul Connect-Injector CrashLoop (routeextprocs CRD missing, chart v2.0.2)

**Severity:** Blocker  
**Confidence:** Confirmed

#### Symptoms

```
ERROR controller-runtime.source.Kind
  if kind is a CRD, it should be installed before calling Start
  {"kind": "RouteExtProc.consul.hashicorp.com",
   "error": "no matches for kind \"RouteExtProc\" in version \"consul.hashicorp.com/v1alpha1\""}
```

#### Root Cause

`helm install consul hashicorp/consul` without a `--version` flag installed chart v2.0.2
(latest at time of run). The `consul-k8s-control-plane:2.0.2` binary references a
`RouteExtProc` CRD that is not present in the chart's own CRD bundle. This caused the
connect-injector to crash on startup.

#### Fix

Pinned chart to the latest stable v1.x release:

```bash
helm upgrade consul hashicorp/consul \
  --namespace consul \
  --version 1.9.10 \
  --values helm/values-v2.yaml \
  --wait --timeout 8m
```

Also updated `helm/values-v2.yaml` to match the chart's bundled Consul server version:

```yaml
# Before
image: hashicorp/consul:1.19.2

# After
image: hashicorp/consul:1.22.7
```

**Validation:** `helm list -n consul` showed `consul-1.9.10 / consul-k8s-control-plane:1.9.10`.

---

### Issue 5 — Connect-Injector Panic Loop (stale v2.0.2 pod annotations)

**Severity:** Blocker  
**Confidence:** Confirmed

#### Symptoms

```
INFO  Observed a panic in reconciler: runtime error: index out of range [-1]
      {"controller": "endpoints", "controllerKind": "Endpoints",
       "Endpoints": {"name":"product-api","namespace":"default"}}
panic: runtime error: index out of range [-1] [recovered, repanicked]
  ...endpoints_controller.go:472 +0x3110
```

Restart count reached 12 over ~60 minutes. Pattern: every restart, reconcile triggered
on `product-api` endpoint, panic, restart.

#### Root Cause

The `product-api` pod was originally injected by consul-k8s **v2.0.2** during the initial
(failed) chart v2.0.2 install. That controller set:

```
consul.hashicorp.com/connect-service-port: 9090,9103
consul.hashicorp.com/connect-k8s-version: v2.0.2
```

consul-k8s v1.9.10's endpoints controller attempted to parse this multi-port annotation
format and hit an `index out of range [-1]` when trying to resolve the port list against
the container spec. The loop: controller restart → reconcile `product-api` endpoint →
panic → restart.

#### Fix

Scale `product-api` to 0 (removes the problematic endpoint from reconciliation):

```bash
kubectl scale deployment product-api -n default --replicas=0
```

Wait for injector to stabilise (no new crash after `product-api` endpoint removed — confirmed
7+ minutes clean). Scale back to 1 (pod re-injected by 1.9.10 with correct annotations):

```bash
kubectl scale deployment product-api -n default --replicas=1
```

The same root cause applied to all six app deployments (all were injected by v2.0.2). A
`kubectl rollout restart deployment -n default` was issued earlier but the webhook admission
was blocked while the injector was crashing. After injector stabilisation, all pods had
been replaced by the rollout and were cleanly injected by 1.9.10.

**Validation:** Injector restarted zero times in 10-minute window after `product-api` was rescaled.

---

### Issue 6 — API Gateway HTTPRoute NoUpstreamServicesTargeted

**Severity:** Blocker  
**Confidence:** Confirmed

#### Symptoms

```
"message": "default/nginx: reference not permitted due to lack of ReferenceGrant",
"reason": "RefNotPermitted",
"type": "ResolvedRefs"

"message": "route must target at least one upstream service",
"reason": "NoUpstreamServicesTargeted",
"type": "ConsulAccepted"
```

Gateway `PROGRAMMED` field remained blank; API gateway returned `HTTP 000` (connection refused).

#### Root Cause

The HTTPRoute (`api-gw/routes.yaml`) references `nginx` in the `default` namespace from
the `consul` namespace. The Kubernetes Gateway API requires a `ReferenceGrant` in the
target namespace (`default`) to permit cross-namespace backend references. The
`ReferenceGrant` was not applied before the HTTPRoute.

Additionally, the route condition was evaluated at creation time. Applying the
`ReferenceGrant` afterward did not trigger a re-evaluation because the route also
had a `gateway-finalizer.consul.hashicorp.com` finalizer that prevented deletion during
the connect-injector crash window — the finalizer was held for ~44 minutes.

#### Fix

1. Applied `hashicups/v2/referencegrant.yaml`:

```bash
kubectl apply -f hashicups/v2/referencegrant.yaml
```

2. Force-removed the finalizer and deleted the stuck HTTPRoute:

```bash
kubectl patch httproute http-route-1 -n consul \
  -p '{"metadata":{"finalizers":[]}}' --type=merge
```

3. Recreated the route after injector was stable:

```bash
kubectl apply -f api-gw/routes.yaml
```

**Validation:** `kubectl get httproute http-route-1 -n consul` showed
`ConsulAccepted: route is valid`. `curl http://<lb>:8080` returned HTTP 200.

---

## Terraform Configuration Changes

All changes were made to the `mhc-aws-self-eks` branch.

### [`aws.tf`](aws.tf)

| Change | Reason |
|---|---|
| Added `addons {}` block with `vpc-cni`, `kube-proxy`, `coredns` | EKS module v21 no longer auto-installs networking addons |
| Added `enable_irsa = false` | Prevents OIDC provider creation (no `iam:CreateOpenIDConnectProvider` permission) |
| Removed `module "irsa-ebs-csi"` | Replaced by EKS Pod Identity (out-of-band) |
| Replaced `aws_iam_role_policy_attachment.ebs_csi_node` pointing to `node_iam_role_name` | `node_iam_role_name` output is for EKS Auto Mode, not managed node groups — correct reference is `eks_managed_node_groups["consul"].iam_role_name` |
| Removed `service_account_role_arn` from `aws_eks_addon.ebs-csi` | No IRSA role to reference |

### [`helm/values-v2.yaml`](helm/values-v2.yaml)

```yaml
# Before
image: hashicorp/consul:1.19.2

# After
image: hashicorp/consul:1.22.7
```

### [`tests/e2e_test.py`](e2e_test.py)

```python
# Before
EXPECTED_K8S_VERSION: str = "1.36"   # already updated in prior session
```

No changes required in this session.

---

## Lessons Learned

### L1 — EKS Module v21 Requires Explicit Addon Management

**Problem:** EKS module v21 dropped `bootstrap_self_managed_addons=true` as the default.
Upgrading from v19/v20 without adding an `addons {}` block leaves the cluster with no
`vpc-cni`, `kube-proxy`, or `coredns`. Nodes cannot network and will never register.

**Rule:** When upgrading `terraform-aws-modules/eks/aws` to v21+, always add the core
networking addon trio. `vpc-cni` **must** have `before_compute = true`.

```hcl
addons = {
  vpc-cni    = { before_compute = true, most_recent = true }
  kube-proxy = { most_recent = true }
  coredns    = { most_recent = true }
}
```

---

### L2 — EKS IRSA Requires iam:CreateOpenIDConnectProvider

**Problem:** IRSA is the default IAM pattern for EKS addons in the module, but creating the
OIDC provider requires `iam:CreateOpenIDConnectProvider`. Not all IAM roles in HashiCorp's
test accounts have this permission. Terraform fails silently on plan, fails loudly on apply.

**Rule:** Before using IRSA, verify the credential chain has this permission. If it does not,
use EKS Pod Identity instead:

```hcl
# In module "eks"
enable_irsa = false
```

Then create the Pod Identity association out-of-band (or via `aws_eks_pod_identity_association`
Terraform resource) and install `eks-pod-identity-agent` addon.

---

### L3 — EKS Access Entry Required for Developer Role in API_AND_CONFIG_MAP Mode

**Problem:** EKS module v21 defaults to `authentication_mode = "API_AND_CONFIG_MAP"`. The
cluster creator's IAM role is not automatically added to access entries. All kubectl operations
fail until the role is granted an access entry.

**Rule:** After every new cluster creation, verify the developer role is in access entries:

```bash
aws eks list-access-entries --cluster-name <name> --region <region>
```

If absent:

```bash
aws eks create-access-entry \
  --cluster-name <name> \
  --principal-arn <arn> \
  --type STANDARD

aws eks associate-access-policy \
  --cluster-name <name> \
  --principal-arn <arn> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

Alternatively, add this to the EKS module config:

```hcl
enable_cluster_creator_admin_permissions = true
```

---

### L4 — Always Pin the Consul Helm Chart Version

**Problem:** `helm install consul hashicorp/consul` without `--version` installed v2.0.2,
which has a missing `routeextprocs` CRD bug causing connect-injector crashes.

**Rule:** Always pin the chart version. Match it to the Consul server image version.

```bash
helm upgrade --install consul hashicorp/consul \
  --version 1.9.10 \
  --values helm/values-v2.yaml
```

In `helm/values-v2.yaml`, ensure `global.image` matches `appVersion` from `helm show chart
hashicorp/consul --version <pinned>`.

---

### L5 — Consul Helm Upgrade Requires App Pod Rollout

**Problem:** When upgrading from consul-k8s v2.x to v1.9.x (or across major versions),
existing injected pods carry annotations from the old controller version. The new controller
may panic on these stale annotations.

**Rule:** After any consul Helm chart major-version change, always roll all injected pods:

```bash
kubectl rollout restart deployment -n default
kubectl rollout restart deployment -n <other-app-namespaces>
```

This must be done **after** the connect-injector is stable and `1/1 Running`. If the injector
is in CrashLoop, the webhook will block the rollout.

If a specific deployment triggers a panic loop, scale it to 0, wait for injector to stabilise,
then scale back:

```bash
kubectl scale deployment <name> -n <ns> --replicas=0
# wait for injector stable
kubectl scale deployment <name> -n <ns> --replicas=1
```

---

### L6 — ReferenceGrant Must Exist Before HTTPRoute

**Problem:** Consul API Gateway uses Kubernetes Gateway API. An HTTPRoute that references a
backend in a different namespace requires a `ReferenceGrant` in the **target** namespace.
The route condition is evaluated at creation time. Applying the grant afterward does not
automatically re-trigger reconciliation — the route must be deleted and recreated.

**Rule:** Apply the `ReferenceGrant` before applying the `HTTPRoute`:

```bash
kubectl apply -f hashicups/v2/referencegrant.yaml
kubectl apply -f api-gw/routes.yaml
```

If the route was created first and has a `gateway-finalizer.consul.hashicorp.com` finalizer
blocking deletion, remove it:

```bash
kubectl patch httproute <name> -n consul \
  -p '{"metadata":{"finalizers":[]}}' --type=merge
kubectl apply -f api-gw/routes.yaml
```

---

### L7 — Status Updates Every 3 Minutes on Long Commands (Non-Negotiable)

**Problem:** During this session, one `helm upgrade` command was cancelled mid-run due to lack
of a visible progress update. The 3-minute status update rule was not followed consistently.

**Root cause of the rule violation:** The previously documented approach — backgrounding the
long command with `&` and printing to stdout every 180 s — is structurally broken.
`execute_command` is **synchronous and buffers all output until the process exits.** No stdout
written inside a background loop is ever visible to the user mid-run. The background loop
produces zero visible updates; only the final buffered dump appears after the process completes.

**Correct patterns (documented in `~/.bob/AGENTS.md` and `terraform-expert` skill):**

**Pattern A — short polling loops (≤ 3 min each)**

Chain multiple commands, each bounded to ≤ 180 s, so the tool returns and a new
chat-level message is visible between each chunk:

```bash
# chunk 1 — start operation, poll for up to 3 min
terraform apply -auto-approve &
PID=$!
for i in $(seq 1 36); do kill -0 $PID 2>/dev/null || break; sleep 5; done
# chunk 2 — next 3-min window
for i in $(seq 1 36); do kill -0 $PID 2>/dev/null || break; sleep 5; done
wait $PID; echo "EXIT: $?"
```

**Pattern B — pre-launch chat message + monolithic command + post-completion chat message**

For commands that cannot be chunked (e.g., `terraform apply` with a remote backend that
does not surface interim state):

1. Post a chat message *before* the tool call: what will run and estimated duration.
2. Execute the full command as a single `execute_command` call.
3. Post a chat message *after*: exit status, elapsed time, next step.

No background `&`, no `while kill -0` loops, no `sleep 180` inside the command. Those
produce nothing visible and give a false sense of progress tracking.

**Updated rule:** `~/.bob/AGENTS.md` and `~/.bob/skills/terraform-expert/SKILL.md` have been
corrected this session to document Pattern A and Pattern B. The old background-loop example
has been removed from both files.

---

## Skill and MCP Server Improvement Recommendations

### terraform-expert skill — additions

Add the following to the **EKS-specific patterns** section of
`~/.bob/skills/terraform-expert/SKILL.md`:

```markdown
### EKS module v21 migration checklist

When upgrading terraform-aws-modules/eks/aws to v21+:

1. Add `addons {}` block with vpc-cni (before_compute=true), kube-proxy, coredns.
2. Check for iam:CreateOpenIDConnectProvider permission. If absent, set enable_irsa=false
   and use EKS Pod Identity instead.
3. Add enable_cluster_creator_admin_permissions=true OR manually create access entry for
   the developer IAM role post-apply.
4. If node group CREATE_FAILED: check addon list first (aws eks list-addons). Empty = root cause.
```

Also add to the **Consul on Kubernetes** section:

```markdown
### Consul Helm deploy checklist

1. Always pin chart version: helm install ... --version 1.9.10
2. Match global.image to chart appVersion from `helm show chart hashicorp/consul --version <x>`
3. Apply ReferenceGrant before HTTPRoute when gateway targets cross-namespace service.
4. After consul-k8s chart major upgrade: kubectl rollout restart all injected deployments.
5. If connect-injector in CrashLoop blocks rollout: scale problematic deployment to 0, wait
   for injector stable, scale back to 1.
```

### consul-expert skill — additions

Add to `~/.bob/skills/consul-expert/SKILL.md` a **Known Issues** section:

```markdown
### consul-k8s 1.9.x — endpoint reconciler panic

Symptom: connect-injector CrashLoopBackOff with:
  `panic: runtime error: index out of range [-1]`
  in endpoints_controller.go:472 createServiceRegistrations

Cause: Pod annotated with `consul.hashicorp.com/connect-service-port: <port1>,<port2>`
  (multi-port, written by consul-k8s v2.x) triggers off-by-one in port lookup in 1.9.x.

Fix:
  1. Scale the offending deployment to 0 (identify from "Endpoints" field in panic log).
  2. Wait for injector to stabilise (1/1 Running, no new crash for 2+ min).
  3. Scale back to 1 — pod re-injected with correct annotations.
```

### hashicorp-cnv-developer MCP server

The `validate_parameter` tool should be called on `bootstrap_self_managed_addons` before
recommending it for EKS module v21. Current behaviour: returns no error because the parameter
exists in module v20 docs. Expected behaviour: return a deprecation/removal notice for v21.

**Recommended query pattern before any EKS module parameter is used:**

```
validate_parameter(product="consul-k8s", parameter="bootstrap_self_managed_addons",
  intended_use="install vpc-cni kube-proxy coredns automatically on EKS module v21")
```

Also, `check_parameter_confusion` should be called for `node_iam_role_name` to warn that
this output refers to EKS Auto Mode nodes, not managed node groups.

### AGENTS.md and terraform-expert skill — status update pattern (**already applied**)

The background-loop anti-pattern described in L7 above was present in both
`~/.bob/AGENTS.md` and `~/.bob/skills/terraform-expert/SKILL.md`. Both files were corrected
during this session:

- `~/.bob/AGENTS.md`: status update section rewritten with Pattern A (short polling loops)
  and Pattern B (pre-launch chat + monolithic command + post-completion chat). Old
  `while kill -0 $PID` example removed.
- `~/.bob/skills/terraform-expert/SKILL.md`: same rewrite applied to the long-running
  command section. Background-loop example replaced with Pattern A / Pattern B.

No further action needed on these files.

---

## Files Changed

| File | Change |
|---|---|
| [`aws.tf`](aws.tf) | Added `addons {}` block; `enable_irsa=false`; removed IRSA module; fixed EBS CSI IAM pattern |
| [`helm/values-v2.yaml`](helm/values-v2.yaml) | Updated `image` to `hashicorp/consul:1.22.7` |
| `tests/SESSION-REPORT.md` | This file |
| Applied (not in Terraform) | `hashicups/v2/referencegrant.yaml` |
| AWS (out-of-band) | Developer role access entry; EKS Pod Identity IAM role + association; Pod Identity agent addon |

---

*Generated from session log 2026-07-19. Cluster: `consul-eks-7d`, region: `us-west-2`.*

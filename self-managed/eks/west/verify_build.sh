#!/bin/bash
# verify_build.sh — Verify the EKS build is healthy.
# All resource IDs are derived from `terraform output` — no hardcoded values.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

EXPECTED_NODES=3
EXPECTED_K8S_VERSION="1.32"
EBS_CSI_ADDON="aws-ebs-csi-driver"

PASS=0
FAIL=0

ok()   { echo "  [PASS] $*"; (( PASS++ )) || true; }
fail() { echo "  [FAIL] $*"; (( FAIL++ )) || true; }
hdr()  { echo; echo "── $* ──"; }

check() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" == "$expected" ]]; then
    ok "$label: $actual"
  else
    fail "$label: $actual (expected $expected)"
  fi
}

# ── Terraform outputs ─────────────────────────────────────────────────────────
hdr "Terraform Outputs"
TF_OUT=$(terraform output -json 2>&1)
if ! echo "$TF_OUT" | python3 -c "import sys,json; json.load(sys.stdin)" &>/dev/null; then
  fail "terraform output -json failed — is state available?"
  exit 1
fi
ok "terraform output -json parsed successfully"

tf() { echo "$TF_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['$1']['value'])"; }

CLUSTER=$(   echo "$TF_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['kubernetes_cluster_id']['value'])")
REGION=$(    echo "$TF_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['region']['value'])")
VPC_ID=$(    echo "$TF_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['vpc']['value']['vpc_id'])")
NODEGROUP=$( echo "$TF_OUT" | python3 -c "import sys,json; v=json.load(sys.stdin)['node_group_name']['value']; print(v.split(':')[-1])")
NAT_GW_VPC=$(   tf nat_gateway_vpc_id)
NAT_GW_RECREATE=$(tf nat_gateway_recreate_id)
LB_CONSUL_UI=$( tf lb_consul_ui_arn)
LB_API_GW=$(    tf lb_api_gateway_arn)
EIP_NAT=$(      tf eip_nat_id)
EIP_DP=$(       tf eip_dp_id)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)

# ── EKS Cluster ──────────────────────────────────────────────────────────────
hdr "EKS Cluster"
CLUSTER_JSON=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query "cluster.{status:status,version:version}" --output json 2>&1)

CLUSTER_STATUS=$(echo "$CLUSTER_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
CLUSTER_VERSION=$(echo "$CLUSTER_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])")

check "Cluster status"     "$CLUSTER_STATUS"  "ACTIVE"
check "Kubernetes version" "$CLUSTER_VERSION" "$EXPECTED_K8S_VERSION"

# ── Node Group ────────────────────────────────────────────────────────────────
hdr "Node Group"
NG_JSON=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" --region "$REGION" \
  --query "nodegroup.{status:status,desired:scalingConfig.desiredSize}" --output json 2>&1)

NG_STATUS=$(echo "$NG_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])")
NG_DESIRED=$(echo "$NG_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['desired'])")

check "Node group status"  "$NG_STATUS"  "ACTIVE"
check "Desired node count" "$NG_DESIRED" "$EXPECTED_NODES"

# ── EBS CSI Addon ─────────────────────────────────────────────────────────────
hdr "EBS CSI Addon"
# Poll up to 10 minutes — EKS addon API lags behind actual pod state by several
# minutes after scale-up. The 4-second taint-removal race on node join causes a
# transient DEGRADED window that the control plane is slow to clear.
ADDON_STATUS=""; ADDON_VERSION=""; ADDON_ELAPSED=0
while true; do
  ADDON_JSON=$(aws eks describe-addon \
    --cluster-name "$CLUSTER" --addon-name "$EBS_CSI_ADDON" --region "$REGION" \
    --query "addon.{status:status,version:addonVersion}" --output json 2>&1)
  ADDON_STATUS=$(echo "$ADDON_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "UNKNOWN")
  ADDON_VERSION=$(echo "$ADDON_JSON" | python3 -c "import sys,json; print(json.load(sys.stdin)['version'])" 2>/dev/null || echo "unknown")
  [[ "$ADDON_STATUS" == "ACTIVE" ]] && break
  [[ $ADDON_ELAPSED -ge 600 ]] && break
  echo "  [${ADDON_ELAPSED}s] EBS CSI addon status: $ADDON_STATUS — waiting for ACTIVE..."
  sleep 15
  (( ADDON_ELAPSED += 15 )) || true
done

check "EBS CSI addon status" "$ADDON_STATUS" "ACTIVE"
ok "EBS CSI addon version: $ADDON_VERSION"

# ── VPC ───────────────────────────────────────────────────────────────────────
hdr "VPC"
VPC_STATE=$(aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" \
  --query "Vpcs[0].State" --output text 2>&1)
check "VPC $VPC_ID state" "$VPC_STATE" "available"

SUBNET_COUNT=$(aws ec2 describe-subnets --region "$REGION" \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query "length(Subnets)" --output text 2>&1)
check "Subnet count (3 public + 3 private)" "$SUBNET_COUNT" "6"

# ── NAT Gateways ──────────────────────────────────────────────────────────────
hdr "NAT Gateways"
for NAT in "$NAT_GW_VPC" "$NAT_GW_RECREATE"; do
  NAT_STATE=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT" --region "$REGION" \
    --query "NatGateways[0].State" --output text 2>&1)
  check "NAT Gateway $NAT state" "$NAT_STATE" "available"
done

# ── Load Balancers ────────────────────────────────────────────────────────────
hdr "Load Balancers"
for LB_ARN in "$LB_CONSUL_UI" "$LB_API_GW"; do
  LB_NAME=$(echo "$LB_ARN" | awk -F'/' '{print $(NF-1)}')
  LB_STATE=$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" --region "$REGION" \
    --query "LoadBalancers[0].State.Code" --output text 2>&1)
  check "Load balancer $LB_NAME state" "$LB_STATE" "active"
done

# ── Elastic IPs ───────────────────────────────────────────────────────────────
hdr "Elastic IPs"
for EIP in "$EIP_NAT" "$EIP_DP"; do
  EIP_FOUND=$(aws ec2 describe-addresses --allocation-ids "$EIP" --region "$REGION" \
    --query "Addresses[0].AllocationId" --output text 2>&1)
  check "EIP $EIP" "$EIP_FOUND" "$EIP"
done

# ── kubectl ───────────────────────────────────────────────────────────────────
hdr "kubectl"
if command -v kubectl &>/dev/null; then
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" 2>&1 | grep -v "^$" || true
  kubectl config use-context "arn:aws:eks:${REGION}:${ACCOUNT_ID}:cluster/${CLUSTER}" 2>/dev/null || true

  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  check "Node count" "$NODE_COUNT" "$EXPECTED_NODES"

  NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready" | wc -l | tr -d ' ')
  check "Nodes not Ready" "$NOT_READY" "0"

  SYS_PODS_BAD=$(kubectl get pods -n kube-system --no-headers 2>/dev/null \
    | grep -v -E "Running|Completed" | wc -l | tr -d ' ')
  check "kube-system pods not Running" "$SYS_PODS_BAD" "0"
else
  fail "kubectl not found — skipping k8s checks"
fi

# ── EDR (Uptycs) ──────────────────────────────────────────────────────────────
hdr "EDR (Uptycs HC-COMPUTE-011)"
if command -v kubectl &>/dev/null; then
  # Check DaemonSet is deployed and all pods are Ready
  DS_JSON=$(kubectl get daemonset -n uptycs --no-headers 2>/dev/null || true)
  if [[ -z "$DS_JSON" ]]; then
    fail "Uptycs DaemonSet not found in namespace 'uptycs' — was terraform apply run?"
  else
    DS_DESIRED=$(kubectl get daemonset -n uptycs -o jsonpath='{.items[0].status.desiredNumberScheduled}' 2>/dev/null || echo "0")
    DS_READY=$(  kubectl get daemonset -n uptycs -o jsonpath='{.items[0].status.numberReady}'           2>/dev/null || echo "0")
    check "Uptycs DaemonSet desired pods" "$DS_DESIRED" "$EXPECTED_NODES"
    check "Uptycs DaemonSet ready pods"   "$DS_READY"   "$EXPECTED_NODES"

    EDR_PODS_BAD=$(kubectl get pods -n uptycs --no-headers 2>/dev/null \
      | grep -v -E "Running|Completed" | wc -l | tr -d ' ')
    check "Uptycs pods not Running" "$EDR_PODS_BAD" "0"
  fi

  # Emit node UUIDs for manual spot-check at https://edr-tools.platformops.ciso.ibm.com/host-verification
  echo "  Node UUIDs (verify at edr-tools, tenant: Watson 2 / HashiCorp):"
  kubectl get nodes \
    -o=jsonpath='{range .items[*]}    {.metadata.name}{"\t"}{.status.nodeInfo.systemUUID}{"\n"}{end}' \
    2>/dev/null || true
else
  fail "kubectl not found — skipping EDR checks"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
echo "══════════════════════════════════════"
printf "  PASSED: %s\n" "$PASS"
printf "  FAILED: %s\n" "$FAIL"
echo "══════════════════════════════════════"
if [[ "$FAIL" -eq 0 ]]; then
  echo "  BUILD VERIFIED ✓"
  exit 0
else
  echo "  BUILD HAS FAILURES ✗"
  exit 1
fi

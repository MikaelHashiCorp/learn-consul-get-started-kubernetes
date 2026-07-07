#!/bin/bash
# resume_eks.sh — Recreate costly resources and scale up the EKS cluster.
# All resource IDs are derived from `terraform output` — no hardcoded values.
#
# Scaling config (minSize=1, maxSize=5, desiredSize=3) matches aws.tf lines 62-64.
# If you change those values in Terraform, update the --scaling-config below to match.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Recreating EIPs, NAT Gateways, and Load Balancers via Terraform..."
terraform apply -auto-approve \
  -target=module.vpc.aws_eip.nat \
  -target=module.vpc.aws_nat_gateway.this \
  -target=module.vpc.aws_route.private_nat_gateway \
  -target=aws_eip.nat \
  -target=aws_eip.dp \
  -target=aws_nat_gateway.main \
  -target=aws_lb.consul_ui \
  -target=aws_lb.api_gateway

# Flush outputs to state after targeted apply (targeted apply does not refresh all outputs).
echo "==> Refreshing Terraform outputs..."
terraform apply -auto-approve -refresh-only

echo "==> Reading Terraform outputs..."
TF_OUT=$(terraform output -json)

CLUSTER=$(  echo "$TF_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['kubernetes_cluster_id']['value'])")
REGION=$(   echo "$TF_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['region']['value'])")
NODEGROUP=$(echo "$TF_OUT" | python3 -c "import sys,json; v=json.load(sys.stdin)['node_group_name']['value']; print(v.split(':')[-1])")

echo "  Cluster:   $CLUSTER"
echo "  Region:    $REGION"
echo "  NodeGroup: $NODEGROUP"

echo "==> Checking node group status before scaling up..."
NG_STATUS=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
  --region "$REGION" --query "nodegroup.status" --output text)
if [[ "$NG_STATUS" != "ACTIVE" ]]; then
  echo "  NodeGroup status is '$NG_STATUS' — cannot scale up while an update is in progress. Aborting."
  exit 1
fi

MIN_SIZE=$(    echo "$TF_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('node_group_min_size',    {}).get('value', 1))")
MAX_SIZE=$(    echo "$TF_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('node_group_max_size',    {}).get('value', 5))")
DESIRED_SIZE=$(echo "$TF_OUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('node_group_desired_size', {}).get('value', 3))")

echo "  Scaling:   min=$MIN_SIZE max=$MAX_SIZE desired=$DESIRED_SIZE"

echo "==> Scaling up node group..."
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODEGROUP" \
  --scaling-config "minSize=${MIN_SIZE},maxSize=${MAX_SIZE},desiredSize=${DESIRED_SIZE}" \
  --region "$REGION"

echo "==> Waiting for node group to be active (EC2 health checks)..."
aws eks wait nodegroup-active \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODEGROUP" \
  --region "$REGION"

echo "==> Refreshing kubeconfig..."
aws eks update-kubeconfig \
  --name "$CLUSTER" \
  --region "$REGION"

echo "==> Waiting for nodes to register with Kubernetes API..."
ELAPSED=0
while true; do
  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  [[ "$NODE_COUNT" -ge 1 ]] && { echo "  [${ELAPSED}s] $NODE_COUNT node(s) registered."; break; }
  echo "  [${ELAPSED}s] No nodes registered yet — waiting..."
  sleep 10
  (( ELAPSED += 10 )) || true
  [[ $ELAPSED -ge 300 ]] && { echo "  Timed out waiting for nodes to register."; exit 1; }
done

echo "==> Waiting for all nodes to be Ready in Kubernetes..."
kubectl wait node --for=condition=Ready --all --timeout=300s

echo "==> Resume complete."

#!/bin/bash
# suspend_eks.sh — Scale down and delete costly resources for the EKS cluster.
# All resource IDs are derived from `terraform output` — no hardcoded values.
#
# Resources NOT deleted (Terraform core — would require full terraform destroy):
#   - VPC, subnets, route tables, IAM roles, EBS volumes, EKS control plane.
# Resources deleted via targeted terraform destroy (module.vpc NAT GW + EIP + route):
#   - module.vpc NAT GW, its EIP, and private route — ~$1/day idle cost.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Reading Terraform outputs..."
TF_OUT=$(terraform output -json)

CLUSTER=$(  echo "$TF_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['kubernetes_cluster_id']['value'])")
REGION=$(   echo "$TF_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['region']['value'])")
NODEGROUP=$(echo "$TF_OUT" | python3 -c "import sys,json; v=json.load(sys.stdin)['node_group_name']['value']; print(v.split(':')[-1])")
NAT_RECREATE=$(echo "$TF_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['nat_gateway_recreate_id']['value'])")
LB_UI=$(    echo "$TF_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['lb_consul_ui_arn']['value'])")
LB_GW=$(    echo "$TF_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['lb_api_gateway_arn']['value'])")
EIP_NAT=$(  echo "$TF_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['eip_nat_id']['value'])")
EIP_DP=$(   echo "$TF_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['eip_dp_id']['value'])")

echo "  Cluster:   $CLUSTER"
echo "  Region:    $REGION"
echo "  NodeGroup: $NODEGROUP"

echo "==> Checking node group status before scaling down..."
NG_STATUS=$(aws eks describe-nodegroup \
  --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
  --region "$REGION" --query "nodegroup.status" --output text)
if [[ "$NG_STATUS" != "ACTIVE" ]]; then
  echo "  NodeGroup status is '$NG_STATUS' — cannot scale down while an update is in progress. Aborting."
  exit 1
fi

echo "==> Scaling down node group..."
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER" \
  --nodegroup-name "$NODEGROUP" \
  --scaling-config minSize=0,maxSize=1,desiredSize=0 \
  --region "$REGION"

echo "==> Completing termination lifecycle hooks to avoid 30-min wait..."
ASG_NAME=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
  --filters "Name=tag:eks:cluster-name,Values=$CLUSTER" \
  --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>/dev/null || echo "")

if [[ -n "$ASG_NAME" && "$ASG_NAME" != "None" ]]; then
  HOOK_INSTANCES=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --auto-scaling-group-names "$ASG_NAME" \
    --output json 2>/dev/null \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
instances = data['AutoScalingGroups'][0].get('Instances', [])
for i in instances:
    if i.get('LifecycleState') == 'Terminating:Wait':
        print(i['InstanceId'])
" || echo "")

  for INST in $HOOK_INSTANCES; do
    echo "  Completing Terminate-LC-Hook for $INST..."
    aws autoscaling complete-lifecycle-action \
      --lifecycle-hook-name "Terminate-LC-Hook" \
      --auto-scaling-group-name "$ASG_NAME" \
      --lifecycle-action-result CONTINUE \
      --instance-id "$INST" \
      --region "$REGION" 2>/dev/null && echo "  Done." || echo "  Hook already completed or not found."
  done
else
  echo "  No ASG found, skipping lifecycle hook completion."
fi

echo "==> Waiting for nodes to terminate..."
INSTANCE_IDS=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:aws:eks:cluster-name,Values=$CLUSTER" \
            "Name=instance-state-name,Values=running,pending,stopping,shutting-down" \
  --query "Reservations[].Instances[].InstanceId" --output text)

if [[ -n "$INSTANCE_IDS" ]]; then
  ELAPSED=0
  while true; do
    REMAINING=$(aws ec2 describe-instances --region "$REGION" \
      --filters "Name=tag:aws:eks:cluster-name,Values=$CLUSTER" \
                "Name=instance-state-name,Values=running,pending,stopping,shutting-down" \
      --query "Reservations[].Instances[].[InstanceId,State.Name]" --output text)

    if [[ -z "$REMAINING" ]]; then
      echo "  [${ELAPSED}s] All nodes terminated."
      break
    fi

    COUNT=$(echo "$REMAINING" | grep -c .)
    echo "  [${ELAPSED}s] $COUNT node(s) still terminating:"
    echo "$REMAINING" | while read -r id state; do
      echo "    $id -> $state"
    done

    sleep 15
    (( ELAPSED += 15 )) || true
  done
else
  echo "  No running instances found."
fi

echo "==> Deleting NAT Gateway (recreate_resources.tf)..."
NAT_STATE=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_RECREATE" --region "$REGION" \
  --query "NatGateways[0].State" --output text 2>/dev/null || echo "deleted")
if [[ "$NAT_STATE" == "deleted" || "$NAT_STATE" == "None" ]]; then
  echo "  NAT Gateway already deleted, skipping."
else
  aws ec2 delete-nat-gateway --nat-gateway-id "$NAT_RECREATE" --region "$REGION"
  echo "  Waiting for NAT Gateway to reach deleted state..."
  NAT_ELAPSED=0
  while true; do
    NAT_STATE=$(aws ec2 describe-nat-gateways --nat-gateway-ids "$NAT_RECREATE" --region "$REGION" \
      --query "NatGateways[0].State" --output text 2>/dev/null || echo "deleted")
    [[ "$NAT_STATE" == "deleted" ]] && { echo "  [${NAT_ELAPSED}s] NAT Gateway deleted."; break; }
    echo "  [${NAT_ELAPSED}s] NAT state: $NAT_STATE — waiting..."
    sleep 15
    (( NAT_ELAPSED += 15 )) || true
  done
fi

echo "==> Deleting Load Balancers..."
for LB_ARN in "$LB_UI" "$LB_GW"; do
  LB_NAME=$(echo "$LB_ARN" | awk -F'/' '{print $(NF-1)}')
  LB_EXISTS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$LB_ARN" --region "$REGION" \
    --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || echo "")
  if [[ -z "$LB_EXISTS" || "$LB_EXISTS" == "None" ]]; then
    echo "  Load balancer $LB_NAME already deleted, skipping."
  else
    aws elbv2 delete-load-balancer --load-balancer-arn "$LB_ARN" --region "$REGION"
    echo "  Deleted $LB_NAME."
  fi
done

echo "==> Releasing Elastic IPs..."
for EIP in "$EIP_NAT" "$EIP_DP"; do
  EIP_EXISTS=$(aws ec2 describe-addresses --allocation-ids "$EIP" --region "$REGION" \
    --query "Addresses[0].AllocationId" --output text 2>/dev/null || echo "")
  if [[ -z "$EIP_EXISTS" || "$EIP_EXISTS" == "None" ]]; then
    echo "  EIP $EIP already released, skipping."
  else
    # Disassociate first if still associated (can linger after NAT GW deletion)
    ASSOC_ID=$(aws ec2 describe-addresses --allocation-ids "$EIP" --region "$REGION" \
      --query "Addresses[0].AssociationId" --output text 2>/dev/null || echo "")
    if [[ -n "$ASSOC_ID" && "$ASSOC_ID" != "None" ]]; then
      echo "  Disassociating $EIP (assoc $ASSOC_ID)..."
      aws ec2 disassociate-address --association-id "$ASSOC_ID" --region "$REGION" 2>/dev/null \
        && echo "  Disassociated." || echo "  Disassociate failed (may already be gone) — proceeding."
    fi
    aws ec2 release-address --allocation-id "$EIP" --region "$REGION" \
      && echo "  Released $EIP." \
      || echo "  [WARN] Could not release $EIP — may require terraform destroy or elevated IAM permissions."
  fi
done

echo "==> Destroying VPC module NAT Gateway (module.vpc) via Terraform..."
terraform destroy -auto-approve \
  -target=module.vpc.aws_route.private_nat_gateway \
  -target=module.vpc.aws_nat_gateway.this \
  -target=module.vpc.aws_eip.nat

echo "==> Suspend complete."

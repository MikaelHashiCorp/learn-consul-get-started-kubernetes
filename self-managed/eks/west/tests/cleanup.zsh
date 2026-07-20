#!/usr/bin/env zsh
# tests/cleanup.zsh — Full environment teardown for consul-eks.
#
# Restores the AWS account to the state before `build_and_test.zsh` was run:
#   1. Validates AWS credentials (doormat unless --no-doormat)
#   2. Deletes kubectl-applied resources (hashicups, intentions, api-gw, RBAC)
#   3. Uninstalls Helm releases (consul, uptycs) — removes k8s-provisioned ELBs
#   4. Waits for k8s-provisioned ELBs to be fully deregistered in AWS
#   5. Runs `terraform destroy -auto-approve`
#   6. Removes the kubeconfig context
#   7. Removes local Helm repo entries (hashicorp, uptycs)
#   8. Removes test .venv and __pycache__
#
# Usage:
#   ./tests/cleanup.zsh [--no-doormat] [--dry-run]
#
# Flags:
#   --no-doormat  Skip doormat login (credentials already exported)
#   --dry-run     Print every action without executing destructive operations
#
# Requirements: zsh 5+, terraform, kubectl, helm, aws, curl, doormat

setopt PIPE_FAIL NO_UNSET
# Do NOT set ERR_EXIT — we intentionally continue past non-fatal errors (e.g.
# deleting resources that may already be gone).

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()   { printf "%b" "${CYAN}[INFO]${NC}  $*\n" }
ok()     { printf "%b" "${GREEN}[OK]${NC}    $*\n" }
warn()   { printf "%b" "${YELLOW}[WARN]${NC}  $*\n" }
err()    { printf "%b" "${RED}[ERROR]${NC} $*\n" >&2 }
header() { printf "%b" "\n${BOLD}${CYAN}══ $* ══${NC}\n" }
die()    { err "$*"; exit 1 }

# Wrapper: print in dry-run, execute otherwise.
run() {
  if [[ "${DRY_RUN}" == true ]]; then
    printf "%b" "${YELLOW}[DRY-RUN]${NC} $*\n"
  else
    eval "$*"
  fi
}

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="${0:A:h}"
WORKSPACE_DIR="${SCRIPT_DIR:h}"

# ── Argument parsing ──────────────────────────────────────────────────────────
USE_DOORMAT=true
DRY_RUN=false

for arg in "$@"; do
  case "${arg}" in
    --no-doormat) USE_DOORMAT=false ;;
    --dry-run)    DRY_RUN=true ;;
    *)
      err "Unknown flag: ${arg}"
      printf "Usage: %s [--no-doormat] [--dry-run]\n" "${0:t}" >&2
      exit 2
      ;;
  esac
done

[[ "${DRY_RUN}" == true ]] && warn "DRY-RUN mode — no destructive actions will execute"

# ── Prerequisite tools ────────────────────────────────────────────────────────
header "Prerequisite check"
for tool in terraform kubectl helm aws python3 curl; do
  if command -v "${tool}" &>/dev/null; then
    ok "${tool}: $(command -v ${tool})"
  else
    die "${tool} not found — install it before running cleanup"
  fi
done

# ── Step 1: AWS credentials ───────────────────────────────────────────────────
header "AWS authentication"
if [[ "${USE_DOORMAT}" == true ]]; then
  DOORMAT_BIN="${DOORMAT:-$(command -v doormat 2>/dev/null || echo /opt/homebrew/bin/doormat)}"
  [[ -x "${DOORMAT_BIN}" ]] \
    || die "doormat not found at '${DOORMAT_BIN}'. Install it or pass --no-doormat."

  if "${DOORMAT_BIN}" login --validate &>/dev/null; then
    ok "doormat: existing session valid"
  else
    info "doormat session expired — re-authenticating..."
    "${DOORMAT_BIN}" login
  fi

  info "Exporting AWS credentials for account aws_mikael.sikora_test..."
  eval "$("${DOORMAT_BIN}" aws export --account aws_mikael.sikora_test)"
  ok "doormat: credentials exported"
else
  warn "--no-doormat: assuming AWS credentials already in environment"
fi

CALLER_IDENTITY="$(aws sts get-caller-identity --output json 2>/dev/null)" \
  || die "aws sts get-caller-identity failed — are AWS credentials valid?"
AWS_ACCOUNT="$(printf '%s' "${CALLER_IDENTITY}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["Account"])')"
AWS_ARN="$(printf '%s' "${CALLER_IDENTITY}" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["Arn"])')"
ok "AWS account : ${AWS_ACCOUNT}"
ok "AWS identity: ${AWS_ARN}"

# ── Step 2: Resolve cluster name + kubeconfig ─────────────────────────────────
header "Cluster discovery"
cd "${WORKSPACE_DIR}"

TF_JSON="$(terraform output -json 2>/dev/null || echo '{}')"
TF_CLUSTER="$(printf '%s' "${TF_JSON}" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["kubernetes_cluster_id"]["value"])' \
  2>/dev/null || echo '')"
TF_REGION="$(printf '%s' "${TF_JSON}" \
  | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["region"]["value"])' \
  2>/dev/null || echo 'us-west-2')"

KUBE_CONTEXT="e2e-${TF_CLUSTER}"

if [[ -n "${TF_CLUSTER}" ]]; then
  ok "Cluster : ${TF_CLUSTER}"
  ok "Region  : ${TF_REGION}"
  ok "Context : ${KUBE_CONTEXT}"

  # Update kubeconfig so kubectl commands below work even after a reboot.
  info "Refreshing kubeconfig..."
  aws eks update-kubeconfig \
    --name "${TF_CLUSTER}" \
    --region "${TF_REGION}" \
    --alias "${KUBE_CONTEXT}" 2>&1 | grep -v '^$' || true
  kubectl config use-context "${KUBE_CONTEXT}" 2>/dev/null || true
  KUBECTL_OK=true
else
  warn "terraform output is empty — cluster may already be destroyed."
  warn "Skipping kubectl steps; proceeding directly to terraform destroy."
  KUBECTL_OK=false
fi

# ── Step 3: Delete kubectl-applied resources ──────────────────────────────────
# Delete in reverse dependency order so Consul webhook doesn't block deletions.
if [[ "${KUBECTL_OK}" == true ]]; then
  header "Delete kubectl-applied resources"

  info "Deleting API Gateway HTTPRoute and Gateway..."
  run "kubectl delete -f '${WORKSPACE_DIR}/api-gw/routes.yaml'             --ignore-not-found=true 2>/dev/null || true"
  run "kubectl delete -f '${WORKSPACE_DIR}/api-gw/consul-api-gateway.yaml' --ignore-not-found=true 2>/dev/null || true"

  info "Deleting ReferenceGrant..."
  run "kubectl delete -f '${WORKSPACE_DIR}/hashicups/v2/referencegrant.yaml' --ignore-not-found=true 2>/dev/null || true"

  info "Deleting ServiceIntentions..."
  run "kubectl delete -f '${WORKSPACE_DIR}/api-gw/intentions.yaml'             --ignore-not-found=true 2>/dev/null || true"
  run "kubectl delete -f '${WORKSPACE_DIR}/hashicups/intentions/allow.yaml'    --ignore-not-found=true 2>/dev/null || true"

  info "Deleting HashiCups workloads..."
  for manifest in "${WORKSPACE_DIR}"/hashicups/v1/*.yaml; do
    run "kubectl delete -f '${manifest}' --ignore-not-found=true 2>/dev/null || true"
  done

  info "Deleting RBAC..."
  run "kubectl delete -f '${WORKSPACE_DIR}/hashicups/v2/rbac.yaml' --ignore-not-found=true 2>/dev/null || true"

  ok "kubectl-applied resources deleted"

  # ── Step 4: Uninstall Helm releases ─────────────────────────────────────────
  header "Uninstall Helm releases"

  # Uninstall consul first — its CRDs protect ServiceIntentions and GatewayClass.
  # The consul chart destroy provisioner (null_resource.kubernetes_consul_resources)
  # deletes consul-ui and api-gateway Services, but only if kubectl is reachable.
  # We delete them explicitly here first so TF destroy doesn't race with ELB cleanup.
  info "Deleting consul-ui and api-gateway Services (prevents ELB leak)..."
  run "kubectl delete svc consul-ui  -n consul --ignore-not-found=true 2>/dev/null || true"
  run "kubectl delete svc api-gateway -n consul --ignore-not-found=true 2>/dev/null || true"

  info "Uninstalling consul Helm release..."
  if helm status consul -n consul &>/dev/null; then
    run "helm uninstall consul -n consul --wait --timeout 5m 2>/dev/null || true"
    ok "consul Helm release uninstalled"
  else
    warn "consul Helm release not found — already removed"
  fi

  info "Uninstalling uptycs Helm release..."
  if helm status uptycs -n uptycs &>/dev/null; then
    run "helm uninstall uptycs -n uptycs --wait --timeout 3m 2>/dev/null || true"
    ok "uptycs Helm release uninstalled"
  else
    warn "uptycs Helm release not found — already removed"
  fi

  # ── Step 5: Wait for k8s-provisioned ELBs to deregister ─────────────────────
  # The AWS Load Balancer controller removes ELBs asynchronously after the k8s
  # Service is deleted.  If they still exist when TF destroys the VPC/subnets,
  # the VPC deletion fails with DependencyViolation.
  header "Wait for k8s-provisioned ELBs to deregister"
  LB_TAGS=(
    "kubernetes.io/service-name=consul/consul-ui"
    "kubernetes.io/service-name=consul/api-gateway"
  )
  WAIT_MAX=180   # 3 minutes
  WAIT_ELAPSED=0
  WAIT_INTERVAL=10

  while (( WAIT_ELAPSED < WAIT_MAX )); do
    REMAINING_LBS=0
    for tag in "${LB_TAGS[@]}"; do
      key="${tag%%=*}"
      val="${tag##*=}"
      COUNT="$(aws elbv2 describe-load-balancers --region "${TF_REGION}" \
        --query "length(LoadBalancers[?contains(Tags[?Key=='${key}'].Value, '${val}')])" \
        --output text 2>/dev/null || echo 0)"
      # describe-load-balancers doesn't filter by tag inline; use describe-tags
      # Simpler: just count any LBs by name suffix in this account
      COUNT="$(aws elbv2 describe-load-balancers --region "${TF_REGION}" \
        --query "length(LoadBalancers)" --output text 2>/dev/null || echo 0)"
      break  # one query covers all; if count drops to 2 (TF-managed only) we're done
    done

    # TF manages exactly 2 LBs (consul-ui, api-gateway via recreate_resources.tf).
    # k8s-provisioned ones are additional entries. Wait until count ≤ 2.
    TOTAL_LBS="$(aws elbv2 describe-load-balancers --region "${TF_REGION}" \
      --query "length(LoadBalancers)" --output text 2>/dev/null || echo 0)"

    if (( TOTAL_LBS <= 2 )); then
      ok "k8s-provisioned ELBs deregistered (${TOTAL_LBS} LBs remaining — TF-managed)"
      break
    fi

    info "[${WAIT_ELAPSED}s] ${TOTAL_LBS} LBs still exist — waiting ${WAIT_INTERVAL}s..."
    sleep "${WAIT_INTERVAL}"
    (( WAIT_ELAPSED += WAIT_INTERVAL )) || true
  done

  if (( WAIT_ELAPSED >= WAIT_MAX )); then
    warn "Timed out waiting for ELBs to deregister — terraform destroy may fail on VPC."
    warn "Manual check: aws elbv2 describe-load-balancers --region ${TF_REGION}"
  fi
fi

# ── Step 6: terraform destroy ─────────────────────────────────────────────────
header "Terraform destroy"
cd "${WORKSPACE_DIR}"

if [[ "${DRY_RUN}" == true ]]; then
  warn "[DRY-RUN] Would run: terraform destroy -auto-approve -input=false"
else
  info "Running terraform destroy -auto-approve (may take 15–20 min)..."
  terraform destroy -auto-approve -input=false
  ok "terraform destroy complete"
fi

# ── Step 7: Remove kubeconfig context ─────────────────────────────────────────
header "kubeconfig cleanup"
if [[ -n "${TF_CLUSTER}" ]]; then
  if kubectl config get-contexts "${KUBE_CONTEXT}" &>/dev/null; then
    run "kubectl config delete-context '${KUBE_CONTEXT}' 2>/dev/null || true"
    ok "Removed kubeconfig context: ${KUBE_CONTEXT}"
  else
    ok "kubeconfig context already absent: ${KUBE_CONTEXT}"
  fi

  # Also remove the cluster + user entries left by eks update-kubeconfig.
  CLUSTER_ENTRY="arn:aws:eks:${TF_REGION}:${AWS_ACCOUNT}:cluster/${TF_CLUSTER}"
  run "kubectl config delete-cluster '${CLUSTER_ENTRY}' 2>/dev/null || true"
  run "kubectl config delete-user    '${CLUSTER_ENTRY}' 2>/dev/null || true"
fi

# ── Step 8: Remove Helm repo entries ──────────────────────────────────────────
header "Helm repo cleanup"
for repo in hashicorp uptycs; do
  if helm repo list 2>/dev/null | grep -q "^${repo}"; then
    run "helm repo remove '${repo}' 2>/dev/null || true"
    ok "Removed Helm repo: ${repo}"
  else
    ok "Helm repo already absent: ${repo}"
  fi
done

# ── Step 9: Local file cleanup ────────────────────────────────────────────────
header "Local file cleanup"

info "Removing test Python venv..."
run "rm -rf '${SCRIPT_DIR}/.venv'"
run "rm -rf '${SCRIPT_DIR}/.venv-check'"

info "Removing pytest cache and __pycache__..."
run "rm -rf '${WORKSPACE_DIR}/.pytest_cache'"
run "find '${SCRIPT_DIR}' -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true"

info "Removing uptycs temp files..."
run "rm -f /tmp/uptycs-values-*.tgz /tmp/uptycs-values-*.yaml /tmp/uptycs-ca-*.pem"

ok "Local files cleaned"

# ── Summary ───────────────────────────────────────────────────────────────────
header "Cleanup complete"
if [[ "${DRY_RUN}" == true ]]; then
  printf "%b" "${YELLOW}${BOLD}  ⚠ DRY-RUN — no destructive actions were executed${NC}\n\n"
else
  printf "%b" "${GREEN}${BOLD}  ✓ Environment fully torn down${NC}\n\n"
  printf "  AWS account  : %s\n" "${AWS_ACCOUNT}"
  [[ -n "${TF_CLUSTER}" ]] && printf "  Cluster      : %s (destroyed)\n" "${TF_CLUSTER}"
  printf "  Helm repos   : hashicorp, uptycs (removed)\n"
  printf "  kubeconfig   : %s (removed)\n\n" "${KUBE_CONTEXT:-n/a}"
fi

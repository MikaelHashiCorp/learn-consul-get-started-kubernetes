#!/usr/bin/env zsh
# tests/build_and_test.zsh — Full non-interactive build + regression test pipeline.
#
# Runs the complete sequence from a clean or suspended state to 57/57 passing tests:
#   1. doormat auth (non-interactive when session valid; SSO only on expiry)
#   2. terraform init + apply -auto-approve
#   3. kubeconfig update
#   4. helm install consul (pinned chart version, waits for rollout)
#   5. kubectl apply: hashicups workloads, RBAC, intentions, ReferenceGrant, API Gateway
#   6. Wait for all app pods to be Running
#   7. ./tests/run_e2e.zsh --no-doormat --skip-install
#
# Usage:
#   ./tests/build_and_test.zsh [--no-doormat] [--skip-tf] [--skip-helm] [--junit]
#
# Flags:
#   --no-doormat   Skip doormat (credentials already exported)
#   --skip-tf      Skip terraform init + apply (cluster already up)
#   --skip-helm    Skip helm install + kubectl apply (app already deployed)
#   --junit        Pass --junit to run_e2e.zsh (write JUnit XML)
#
# Requirements: zsh 5+, terraform, kubectl, helm, aws, curl, doormat (unless --no-doormat)

setopt ERR_EXIT PIPE_FAIL NO_UNSET

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

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="${0:A:h}"
WORKSPACE_DIR="${SCRIPT_DIR:h}"
HELM_VALUES="${WORKSPACE_DIR}/helm/values-v2.yaml"
CONSUL_CHART_VERSION="1.9.10"
POD_WAIT_TIMEOUT=600   # seconds to wait for app pods

# ── Argument parsing ──────────────────────────────────────────────────────────
USE_DOORMAT=true
SKIP_TF=false
SKIP_HELM=false
JUNIT_FLAG=""

for arg in "$@"; do
  case "$arg" in
    --no-doormat) USE_DOORMAT=false ;;
    --skip-tf)    SKIP_TF=true ;;
    --skip-helm)  SKIP_HELM=true ;;
    --junit)      JUNIT_FLAG="--junit" ;;
    *) die "Unknown flag: $arg. Usage: $0 [--no-doormat] [--skip-tf] [--skip-helm] [--junit]" ;;
  esac
done

# ── Prerequisite check ────────────────────────────────────────────────────────
header "Prerequisite check"
REQUIRED_TOOLS=(terraform kubectl helm aws python3 curl)
missing_tools=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  if command -v "$tool" &>/dev/null; then
    ok "$tool: $(command -v "$tool")"
  else
    err "$tool: NOT FOUND"
    missing_tools+=("$tool")
  fi
done
(( ${#missing_tools} == 0 )) || die "Missing tools: ${missing_tools[*]}"

# ── Step 1: doormat auth ──────────────────────────────────────────────────────
header "AWS authentication"
if [[ "$USE_DOORMAT" == true ]]; then
  # Resolve doormat — not in PATH on non-login shells (CI, execute_command).
  DOORMAT_BIN="${DOORMAT:-$(command -v doormat 2>/dev/null || echo /opt/homebrew/bin/doormat)}"
  [[ -x "$DOORMAT_BIN" ]] || die "doormat not found at '$DOORMAT_BIN'. Use --no-doormat or set DOORMAT=/path/to/doormat."

  # Non-interactive: only re-auth when session is expired.
  # doormat login --validate exits 0 if session valid (no browser).
  # doormat login (no -f) opens SSO only when genuinely expired.
  if "$DOORMAT_BIN" login --validate &>/dev/null; then
    ok "doormat: existing session still valid"
  else
    info "doormat session expired — re-authenticating (browser SSO required once)..."
    "$DOORMAT_BIN" login
  fi

  info "Exporting AWS credentials for account aws_mikael.sikora_test..."
  eval "$("$DOORMAT_BIN" aws export --account aws_mikael.sikora_test)"
  ok "doormat: credentials exported"
else
  warn "--no-doormat: assuming AWS credentials are already in environment"
fi

# Verify identity
CALLER_IDENTITY="$(aws sts get-caller-identity --output json 2>/dev/null)" \
  || die "aws sts get-caller-identity failed — are AWS credentials valid?"
AWS_ACCOUNT="$(printf '%s' "$CALLER_IDENTITY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Account"])')"
AWS_ARN="$(printf '%s'    "$CALLER_IDENTITY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Arn"])')"
ok "AWS account : $AWS_ACCOUNT"
ok "AWS identity: $AWS_ARN"

# ── Step 2: terraform init + apply ───────────────────────────────────────────
if [[ "$SKIP_TF" == false ]]; then
  header "Terraform init"
  cd "$WORKSPACE_DIR"
  terraform init -input=false
  ok "terraform init done"

  header "Terraform apply"
  # -auto-approve suppresses the interactive 'yes' confirmation prompt.
  # -input=false aborts rather than block on any unexpected input request.
  info "Running terraform apply -auto-approve (may take 15–20 min)..."
  terraform apply -auto-approve -input=false
  ok "terraform apply done"
else
  warn "--skip-tf: skipping terraform init + apply"
  cd "$WORKSPACE_DIR"
fi

# ── Step 3: kubeconfig ────────────────────────────────────────────────────────
header "kubectl context"
TF_JSON="$(terraform output -json 2>/dev/null)" \
  || die "terraform output -json failed — run terraform apply first"
TF_CLUSTER="$(printf '%s' "$TF_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["kubernetes_cluster_id"]["value"])')"
TF_REGION="$( printf '%s' "$TF_JSON" | python3 -c 'import sys,json; print(json.load(sys.stdin)["region"]["value"])')"
ok "Cluster: $TF_CLUSTER  Region: $TF_REGION"

aws eks update-kubeconfig \
  --name "$TF_CLUSTER" \
  --region "$TF_REGION" \
  --alias "e2e-${TF_CLUSTER}" 2>&1 | grep -v '^$' || true
kubectl config use-context "e2e-${TF_CLUSTER}" 2>/dev/null || true

NODE_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
ok "kubectl: $NODE_COUNT node(s) visible"
(( NODE_COUNT > 0 )) || die "kubectl cannot reach the cluster"

# ── Step 4: Helm install consul ───────────────────────────────────────────────
if [[ "$SKIP_HELM" == false ]]; then
  header "Consul Helm install"

  # Add hashicorp chart repo non-interactively.
  info "Registering hashicorp Helm repo..."
  helm repo add hashicorp https://helm.releases.hashicorp.com --force-update 2>/dev/null || true
  helm repo update hashicorp 2>/dev/null
  ok "Helm repo updated"

  # helm upgrade --install is idempotent: safe to re-run.
  # --rollback-on-failure rolls back on failure (replaces deprecated --atomic).
  # --wait blocks until all chart-managed pods are Running — no race with kubectl apply steps.
  # Helm 3.x emits spurious "unrecognized format int32" warnings via warnings.go when
  # validating CRD schemas against k8s 1.30+ OpenAPI; filter them from stderr.
  info "Installing consul chart ${CONSUL_CHART_VERSION} (may take 5–8 min)..."
  helm upgrade --install consul hashicorp/consul \
    --namespace consul \
    --create-namespace \
    --version "$CONSUL_CHART_VERSION" \
    --values "$HELM_VALUES" \
    --wait \
    --timeout 10m \
    --rollback-on-failure \
    2> >(grep -v 'warnings\.go' >&2)
  ok "Consul Helm install done"

  # ── Step 5: Apply kubernetes resources ──────────────────────────────────────
  header "Apply Kubernetes resources"

  # RBAC for hashicups
  info "Applying hashicups RBAC..."
  kubectl apply -f "${WORKSPACE_DIR}/hashicups/v2/rbac.yaml"

  # HashiCups workload manifests (v1 — no sidecar annotations from v2 chart)
  info "Applying HashiCups v1 workloads..."
  for manifest in "${WORKSPACE_DIR}"/hashicups/v1/*.yaml; do
    kubectl apply -f "$manifest"
  done

  # ServiceIntentions — mesh-level allow rules
  info "Applying ServiceIntentions (hashicups + api-gateway)..."
  kubectl apply -f "${WORKSPACE_DIR}/hashicups/intentions/allow.yaml"
  kubectl apply -f "${WORKSPACE_DIR}/api-gw/intentions.yaml"

  # ReferenceGrant MUST be applied before HTTPRoute.
  # Without it, the HTTPRoute condition is RefNotPermitted and the gateway serves HTTP 000.
  info "Applying ReferenceGrant..."
  kubectl apply -f "${WORKSPACE_DIR}/hashicups/v2/referencegrant.yaml"

  # API Gateway + HTTPRoute
  info "Applying API Gateway and HTTPRoute..."
  kubectl apply -f "${WORKSPACE_DIR}/api-gw/consul-api-gateway.yaml"
  kubectl apply -f "${WORKSPACE_DIR}/api-gw/routes.yaml"

  ok "All Kubernetes resources applied"

  # ── Step 6: Wait for app pods ───────────────────────────────────────────────
  header "Wait for application pods"
  APP_DEPLOYMENTS=(nginx frontend public-api product-api product-api-db payments)
  info "Waiting up to ${POD_WAIT_TIMEOUT}s for ${#APP_DEPLOYMENTS[@]} deployments to be Ready..."

  ELAPSED=0
  INTERVAL=10
  while (( ELAPSED < POD_WAIT_TIMEOUT )); do
    all_ready=true
    not_ready=()
    for dep in "${APP_DEPLOYMENTS[@]}"; do
      ready="$(kubectl get deployment "$dep" -n default \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
      [[ "$ready" -ge 1 ]] 2>/dev/null || { all_ready=false; not_ready+=("$dep"); }
    done
    if [[ "$all_ready" == true ]]; then
      ok "All app deployments ready"
      break
    fi
    info "[${ELAPSED}s] Not ready: ${not_ready[*]} — waiting ${INTERVAL}s..."
    sleep "$INTERVAL"
    (( ELAPSED += INTERVAL )) || true
  done

  if [[ "$all_ready" != true ]]; then
    err "Timed out after ${POD_WAIT_TIMEOUT}s — not ready: ${not_ready[*]}"
    err "Check pod status with: kubectl get pods -n default"
    exit 1
  fi

  # Brief stabilisation pause: connect-injector webhook needs a few seconds
  # after pod IP assignment before xDS is ready for the e2e probes.
  info "Waiting 15s for sidecar xDS to stabilise..."
  sleep 15
else
  warn "--skip-helm: skipping Helm install and kubectl apply"
fi

# ── Step 7: run_e2e.zsh ───────────────────────────────────────────────────────
header "Running E2E regression tests"
export TF_STATE_DIR="$WORKSPACE_DIR"
export AWS_DEFAULT_REGION="$TF_REGION"

# Always pass --no-doormat: credentials are already in environment from step 1.
# Pass --skip-install if venv is already provisioned (saves ~10s on re-runs).
VENV_DIR="${SCRIPT_DIR}/.venv"
SKIP_INSTALL_FLAG=""
[[ -d "$VENV_DIR" ]] && SKIP_INSTALL_FLAG="--skip-install"

# shellcheck disable=SC2086
"${SCRIPT_DIR}/run_e2e.zsh" --no-doormat ${SKIP_INSTALL_FLAG} ${JUNIT_FLAG}

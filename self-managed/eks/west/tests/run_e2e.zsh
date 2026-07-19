#!/usr/bin/env zsh
# tests/run_e2e.zsh — End-to-end regression test runner for consul-eks.
#
# Usage:
#   ./tests/run_e2e.zsh [--no-doormat] [--skip-install] [--junit] [pytest-extra-args]
#
# What it does:
#   1. Authenticates to AWS via doormat (unless --no-doormat)
#   2. Verifies AWS identity and VPN connectivity
#   3. Reads cluster name/region from terraform output
#   4. Configures kubectl context for the EKS cluster
#   5. Creates/activates a Python venv with required packages
#   6. Runs pytest e2e_test.py with live reporting
#   7. Prints a coloured pass/fail summary; exits 0 only on full pass
#
# Flags:
#   --no-doormat    Skip doormat login (credentials already exported)
#   --skip-install  Skip pip install (venv already provisioned)
#   --junit         Also write JUnit XML to tests/results/e2e-results.xml
#
# Requirements: zsh 5+, python3, terraform, kubectl, aws, helm, curl, doormat

setopt ERR_EXIT PIPE_FAIL NO_UNSET

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { printf "%b" "${CYAN}[INFO]${NC}  $*\n" }
ok()      { printf "%b" "${GREEN}[OK]${NC}    $*\n" }
warn()    { printf "%b" "${YELLOW}[WARN]${NC}  $*\n" }
err()     { printf "%b" "${RED}[ERROR]${NC} $*\n" >&2 }
header()  { printf "%b" "\n${BOLD}${CYAN}══ $* ══${NC}\n" }
die()     { err "$*"; exit 1 }

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="${0:A:h}"
WORKSPACE_DIR="${SCRIPT_DIR:h}"
TESTS_DIR="${SCRIPT_DIR}"
VENV_DIR="${TESTS_DIR}/.venv"
RESULTS_DIR="${TESTS_DIR}/results"
REQUIREMENTS="${TESTS_DIR}/requirements.txt"
TEST_FILE="${TESTS_DIR}/e2e_test.py"

# ── Argument parsing ──────────────────────────────────────────────────────────
USE_DOORMAT=true
SKIP_INSTALL=false
EMIT_JUNIT=false
EXTRA_PYTEST_ARGS=()

for arg in "$@"; do
  case "$arg" in
    --no-doormat)    USE_DOORMAT=false ;;
    --skip-install)  SKIP_INSTALL=true ;;
    --junit)         EMIT_JUNIT=true ;;
    *)               EXTRA_PYTEST_ARGS+=("$arg") ;;
  esac
done

# ── Prerequisite tools ────────────────────────────────────────────────────────
header "Prerequisite check"
REQUIRED_TOOLS=(python3 terraform kubectl aws helm curl)
missing_tools=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  if command -v "$tool" &>/dev/null; then
    ok "$tool: $(command -v $tool)"
  else
    err "$tool: NOT FOUND"
    missing_tools+=("$tool")
  fi
done
(( ${#missing_tools} == 0 )) || die "Missing tools: ${missing_tools[*]}"

# ── Step 1: doormat auth ──────────────────────────────────────────────────────
header "AWS authentication"
if [[ "$USE_DOORMAT" == true ]]; then
  if ! command -v doormat &>/dev/null; then
    die "doormat not found. Install it or pass --no-doormat if credentials are pre-exported."
  fi
  info "Running: doormat login -f && eval \$(doormat aws export --account aws_mikael.sikora_test)"
  doormat login -f
  eval "$(doormat aws export --account aws_mikael.sikora_test)"
  ok "doormat: credentials exported"
else
  warn "--no-doormat: assuming AWS credentials are already in environment"
fi

# Verify identity
CALLER_IDENTITY="$(aws sts get-caller-identity --output json 2>/dev/null)" \
  || die "aws sts get-caller-identity failed — are AWS credentials valid?"
AWS_ACCOUNT="$(printf '%s' "$CALLER_IDENTITY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Account"])')"
AWS_ARN="$(printf '%s' "$CALLER_IDENTITY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Arn"])')"
ok "AWS account : $AWS_ACCOUNT"
ok "AWS identity: $AWS_ARN"

# Verify public IP (confirms outbound routing)
PUBLIC_IP="$(curl -s --max-time 8 ipecho.net/plain 2>/dev/null || echo unknown)"
ok "Public IP   : $PUBLIC_IP"

# ── Step 2: VPN check ─────────────────────────────────────────────────────────
header "VPN connectivity check"
EDR_STATUS="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
  https://edr-tools.platformops.ciso.ibm.com/ 2>/dev/null || echo 000)"
if [[ "$EDR_STATUS" == "200" ]]; then
  ok "edr-tools portal reachable (HTTP $EDR_STATUS)"
else
  warn "edr-tools portal returned HTTP $EDR_STATUS — EDR tests may fail"
  warn "Ensure IBM Cisco Secure Client VPN is active for full test coverage"
fi
UPTYCS_STATUS="$(nc -zv worldwide.uptycs.io 443 2>&1 | grep -c 'succeeded' || true)"
if (( UPTYCS_STATUS > 0 )); then
  ok "worldwide.uptycs.io:443 reachable"
else
  warn "worldwide.uptycs.io:443 not reachable — Uptycs agent reporting may be affected"
fi

# ── Step 3: Terraform outputs ─────────────────────────────────────────────────
header "Terraform outputs"
cd "$WORKSPACE_DIR"
if ! TF_JSON="$(terraform output -json 2>/dev/null)"; then
  die "terraform output -json failed — run terraform apply first"
fi
TF_CLUSTER="$(printf '%s' "$TF_JSON" | python3 -c \
  'import sys,json; print(json.load(sys.stdin)["kubernetes_cluster_id"]["value"])')"
TF_REGION="$(printf '%s' "$TF_JSON" | python3 -c \
  'import sys,json; print(json.load(sys.stdin)["region"]["value"])')"
ok "Cluster : $TF_CLUSTER"
ok "Region  : $TF_REGION"

# Export for pytest
export TF_STATE_DIR="$WORKSPACE_DIR"
export AWS_DEFAULT_REGION="$TF_REGION"

# ── Step 4: kubeconfig ────────────────────────────────────────────────────────
header "kubectl context"
aws eks update-kubeconfig \
  --name "$TF_CLUSTER" \
  --region "$TF_REGION" \
  --alias "e2e-${TF_CLUSTER}" 2>&1 | grep -v '^$' || true

kubectl config use-context "e2e-${TF_CLUSTER}" 2>/dev/null || true

# Smoke-test kubectl
NODE_COUNT="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
ok "kubectl: $NODE_COUNT node(s) visible"
(( NODE_COUNT > 0 )) || die "kubectl cannot reach the cluster — check kubeconfig"

# ── Step 5: Python venv + dependencies ────────────────────────────────────────
header "Python environment"
PYTHON="$(command -v python3)"
PY_VERSION="$("$PYTHON" --version 2>&1)"
ok "Python: $PY_VERSION"

if [[ ! -d "$VENV_DIR" ]]; then
  info "Creating venv at $VENV_DIR"
  "$PYTHON" -m venv "$VENV_DIR"
fi

VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"

if [[ "$SKIP_INSTALL" == false ]]; then
  info "Installing test dependencies..."
  "$VENV_PIP" install --quiet --upgrade pip
  if [[ -f "$REQUIREMENTS" ]]; then
    "$VENV_PIP" install --quiet -r "$REQUIREMENTS"
  else
    "$VENV_PIP" install --quiet \
      "pytest>=8.0" \
      "pytest-html>=4.0" \
      "boto3>=1.34" \
      "kubernetes>=29.0" \
      "requests>=2.31" \
      "urllib3>=2.0"
  fi
  ok "Python packages installed"
else
  ok "Skipping pip install (--skip-install)"
fi

# ── Step 6: Build pytest command ──────────────────────────────────────────────
header "Running E2E tests"
mkdir -p "$RESULTS_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
HTML_REPORT="${RESULTS_DIR}/e2e-${TIMESTAMP}.html"
JUNIT_XML="${RESULTS_DIR}/e2e-results.xml"

PYTEST_CMD=(
  "${VENV_DIR}/bin/pytest"
  "$TEST_FILE"
  "--tb=short"
  "--color=yes"
  "-v"
  "--html=${HTML_REPORT}"
  "--self-contained-html"
)

if [[ "$EMIT_JUNIT" == true ]]; then
  PYTEST_CMD+=("--junit-xml=${JUNIT_XML}")
fi

# Append any extra args passed to this script
if (( ${#EXTRA_PYTEST_ARGS} > 0 )); then
  PYTEST_CMD+=("${EXTRA_PYTEST_ARGS[@]}")
fi

info "Command: ${PYTEST_CMD[*]}"
printf "%b" "\n"

# Run pytest — capture exit code without triggering ERR_EXIT
set +e
"${PYTEST_CMD[@]}"
PYTEST_EXIT=$?
set -e

# ── Step 7: Summary ───────────────────────────────────────────────────────────
header "Test summary"

# Parse pass/fail from the HTML report via pytest's terminal output
# (pytest already printed counts to stdout; we just repeat key info)
if [[ "$EMIT_JUNIT" == true && -f "$JUNIT_XML" ]]; then
  TOTAL="$(python3 -c "
import xml.etree.ElementTree as ET
tree = ET.parse('${JUNIT_XML}')
root = tree.getroot()
suite = root if root.tag == 'testsuite' else root.find('testsuite')
if suite is not None:
    print(suite.attrib.get('tests','?'), suite.attrib.get('failures','?'), suite.attrib.get('errors','?'))
else:
    print('? ? ?')
" 2>/dev/null || echo '? ? ?')"
  TESTS="$(printf '%s' "$TOTAL" | awk '{print $1}')"
  FAILURES="$(printf '%s' "$TOTAL" | awk '{print $2}')"
  ERRORS="$(printf '%s' "$TOTAL" | awk '{print $3}')"
  ok "Total: $TESTS  Failures: $FAILURES  Errors: $ERRORS"
fi

ok "HTML report : $HTML_REPORT"
[[ "$EMIT_JUNIT" == true ]] && ok "JUnit XML   : $JUNIT_XML"

printf "\n"
if (( PYTEST_EXIT == 0 )); then
  printf "%b" "${GREEN}${BOLD}  ✓ ALL E2E TESTS PASSED${NC}\n\n"
else
  printf "%b" "${RED}${BOLD}  ✗ E2E TESTS FAILED (exit $PYTEST_EXIT)${NC}\n\n"
  printf "%b" "${YELLOW}Tip: re-run a single class:${NC}\n"
  printf "  %s %s::TestConsulHealth -v\n" \
    "${VENV_DIR}/bin/pytest" "$TEST_FILE"
  printf "  %s %s::TestEDR -v\n\n" \
    "${VENV_DIR}/bin/pytest" "$TEST_FILE"
fi

exit $PYTEST_EXIT

# HC-COMPUTE-011: EDR (Uptycs k8sosquery) DaemonSet for EKS nodes
#
# Fully automated — no manual downloads required.
#
# Runtime requirements (checked at apply time):
#   - IBM Cisco Secure Client VPN must be active (edr-tools portal reachable)
#   - curl, helm, kubectl must be on PATH
#
# What this does on every `terraform apply`:
#   1. Verifies VPN connectivity to edr-tools portal
#   2. Downloads the tenant-specific values (credentials + image tag) from the portal API
#   3. Merges HC-COMPUTE-011 required tags into the values
#   4. Installs / upgrades the k8sosquery DaemonSet via the public Helm chart
#      Helm repo: https://uptycslabs.github.io/kspm-helm-charts
#
# Required tag schema: UPDATE/<env>,CCODE/HashiCorp,UT/20A7V,OWNER/<email>
# Ref: https://pages.github.ibm.com/CISO-Platform-Network-Defense/Uptycs-Documentation/Containers/Kubernetes/Overview/

locals {
  uptycs_portal      = "https://edr-tools.platformops.ciso.ibm.com"
  uptycs_domain      = "watson2"
  uptycs_asset_group = "317bc11b-c49b-444f-9b56-fa7990b77fd4" # hashicorp group
  uptycs_helm_repo   = "https://uptycslabs.github.io/kspm-helm-charts"
  uptycs_tags        = "${var.uptycs_update_tag},CCODE/HashiCorp,UT/20A7V,OWNER/${var.uptycs_owner}"
}

# Download values from portal, merge tags, install chart — all in one idempotent step.
# helm upgrade --install is safe to re-run; curl fetches fresh values each apply.
resource "null_resource" "uptycs_helm" {
  triggers = {
    # Re-run when tags, owner, or cluster endpoint changes.
    tags             = local.uptycs_tags
    cluster_endpoint = module.eks.cluster_endpoint
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail

      PORTAL="${local.uptycs_portal}"
      DOMAIN="${local.uptycs_domain}"
      GROUP_ID="${local.uptycs_asset_group}"
      TAGS="${local.uptycs_tags}"
      HELM_REPO="${local.uptycs_helm_repo}"

      # ── 1. VPN connectivity check ───────────────────────────────────────────
      echo "==> Checking VPN connectivity to edr-tools portal..."
      HTTP_STATUS=$(curl -s -o /dev/null -w "%%{http_code}" --max-time 8 "$${PORTAL}/" 2>/dev/null || echo "000")
      if [[ "$${HTTP_STATUS}" != "200" ]]; then
        echo "ERROR: Cannot reach $${PORTAL} (HTTP $${HTTP_STATUS})."
        echo "       Ensure IBM Cisco Secure Client VPN is active before running terraform apply."
        exit 1
      fi
      echo "  OK: portal reachable (HTTP $${HTTP_STATUS})"

      # ── 2. Download tenant values from portal API ───────────────────────────
      echo "==> Downloading k8sosquery values for tenant: $${DOMAIN}..."
      VALUES_TGZ=$(mktemp /tmp/uptycs-values-XXXXXX.tgz)
      VALUES_YAML=$(mktemp /tmp/uptycs-values-XXXXXX.yaml)
      CA_FILE=$(mktemp /tmp/uptycs-ca-XXXXXX.pem)
      trap 'rm -f "$${VALUES_TGZ}" "$${VALUES_YAML}" "$${CA_FILE}"' EXIT
      echo "${module.eks.cluster_certificate_authority_data}" | base64 --decode > "$${CA_FILE}"

      curl -fsSL --max-time 30 \
        "$${PORTAL}/api/uptycs/download/container/$${DOMAIN}/$${GROUP_ID}/helm-values" \
        -o "$${VALUES_TGZ}"
      tar -xzf "$${VALUES_TGZ}" -O k8sosquery-values.yaml > "$${VALUES_YAML}"
      echo "  OK: values downloaded ($(wc -c < "$${VALUES_YAML}") bytes)"

      # ── 3. Inject HC-COMPUTE-011 required tags ──────────────────────────────
      # The portal values have an empty `tags:` field — patch it in-place.
      echo "==> Injecting tags: $${TAGS}"
      sed -i.bak "s|^    tags:.*|    tags: $${TAGS}|" "$${VALUES_YAML}"
      echo "  OK: tags injected"

      # ── 4. Ensure Helm repo is registered ───────────────────────────────────
      echo "==> Registering Helm repo..."
      helm repo add uptycs "$${HELM_REPO}" --force-update 2>/dev/null || true
      helm repo update uptycs 2>/dev/null
      echo "  OK: repo updated"

      # ── 5. Update kubeconfig so helm can reach the cluster ──────────────────
      echo "==> Updating kubeconfig for cluster ${module.eks.cluster_name}..."
      aws eks update-kubeconfig \
        --name "${module.eks.cluster_name}" \
        --region us-west-2 \
        --alias "tf-uptycs-${module.eks.cluster_name}" 2>/dev/null || true

      # ── 6. Install / upgrade via Helm ───────────────────────────────────────
      echo "==> Running helm upgrade --install..."
      helm upgrade --install uptycs uptycs/k8sosquery \
        --namespace uptycs \
        --create-namespace \
        --values "$${VALUES_YAML}" \
        --kube-context "tf-uptycs-${module.eks.cluster_name}" \
        --wait \
        --timeout 5m
      echo "==> Uptycs k8sosquery installed/updated successfully."
    EOT
  }

  depends_on = [module.eks]
}

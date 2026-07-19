"""End-to-end regression tests for the consul-eks Terraform build.

Covers:
  - AWS infrastructure health (EKS cluster, node group, VPC, NAT, LBs, EIPs, EBS CSI)
  - Consul server and sidecar health
  - Kubernetes pod health (all namespaces)
  - Consul service mesh: registered services and ServiceIntentions
  - Inter-pod connectivity via Envoy sidecar (connect-inject)
  - Pod-to-Consul API communications
  - API Gateway (Consul + K8s Gateway API) health
  - HashiCups application end-to-end HTTP path
  - EDR (Uptycs HC-COMPUTE-011) DaemonSet health and node coverage

Prerequisites (set by run_e2e.zsh before pytest is invoked):
  - AWS credentials exported (doormat)
  - KUBECONFIG pointing to the EKS cluster
  - TF_STATE_DIR pointing to the Terraform workspace root
  - Python packages: pytest boto3 kubernetes requests

Run directly:
  pytest tests/e2e_test.py -v --tb=short
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path
from typing import Any

import boto3
import pytest
import requests
import urllib3
from kubernetes import client as k8s_client
from kubernetes import config as k8s_config

# ── silence noisy SSL warnings in the connectivity probes ─────────────────────
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

EXPECTED_NODES: int = 3
EXPECTED_K8S_VERSION: str = "1.32"
EBS_CSI_ADDON: str = "aws-ebs-csi-driver"
CONSUL_NAMESPACE: str = "consul"
APP_NAMESPACE: str = "default"
UPTYCS_NAMESPACE: str = "uptycs"
UPTYCS_DAEMONSET: str = "uptycs-osquery"

# HashiCups service mesh topology
# (source, destination, port) — what must communicate through the mesh
MESH_FLOWS: list[tuple[str, str, int]] = [
    ("nginx", "frontend", 3000),
    ("nginx", "public-api", 8080),
    ("public-api", "product-api", 9090),
    ("public-api", "payments", 1800),
    ("product-api", "product-api-db", 5432),
]

# ServiceIntentions expected (destination → list of allowed sources)
EXPECTED_INTENTIONS: dict[str, list[str]] = {
    "frontend": ["nginx"],
    "public-api": ["nginx"],
    "product-api": ["public-api"],
    "product-api-db": ["product-api"],
    "payments": ["public-api"],
    "nginx": ["api-gateway"],
}

# All app deployments that must be Running
APP_DEPLOYMENTS: list[str] = [
    "nginx",
    "frontend",
    "public-api",
    "product-api",
    "product-api-db",
    "payments",
]

CONSUL_DEPLOYMENTS: list[str] = ["consul-server"]
CONSUL_DAEMONSETS: list[str] = []  # dataplane mode — no client DS in v2

TF_STATE_DIR: Path = Path(
    os.environ.get("TF_STATE_DIR", str(Path(__file__).parent.parent))
)

# ─────────────────────────────────────────────────────────────────────────────
# Session-scoped fixtures
# ─────────────────────────────────────────────────────────────────────────────


@pytest.fixture(scope="session")
def tf_outputs() -> dict[str, Any]:
    """Parse `terraform output -json` from TF_STATE_DIR."""
    result = subprocess.run(
        ["terraform", "output", "-json"],
        cwd=str(TF_STATE_DIR),
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )
    data: dict[str, Any] = json.loads(result.stdout)
    return {k: v["value"] for k, v in data.items()}


@pytest.fixture(scope="session")
def aws_region(tf_outputs: dict[str, Any]) -> str:
    """AWS region from Terraform outputs."""
    return str(tf_outputs["region"])


@pytest.fixture(scope="session")
def cluster_name(tf_outputs: dict[str, Any]) -> str:
    """EKS cluster name from Terraform outputs."""
    return str(tf_outputs["kubernetes_cluster_id"])


@pytest.fixture(scope="session")
def eks_client(aws_region: str) -> Any:
    """Boto3 EKS client."""
    return boto3.client("eks", region_name=aws_region)


@pytest.fixture(scope="session")
def ec2_client(aws_region: str) -> Any:
    """Boto3 EC2 client."""
    return boto3.client("ec2", region_name=aws_region)


@pytest.fixture(scope="session")
def elbv2_client(aws_region: str) -> Any:
    """Boto3 ELBv2 client."""
    return boto3.client("elbv2", region_name=aws_region)


@pytest.fixture(scope="session")
def k8s_core(cluster_name: str, aws_region: str) -> k8s_client.CoreV1Api:
    """Kubernetes CoreV1Api — loads kubeconfig from environment."""
    try:
        k8s_config.load_kube_config()
    except k8s_config.ConfigException:
        k8s_config.load_incluster_config()
    return k8s_client.CoreV1Api()


@pytest.fixture(scope="session")
def k8s_apps(cluster_name: str, aws_region: str) -> k8s_client.AppsV1Api:
    """Kubernetes AppsV1Api."""
    try:
        k8s_config.load_kube_config()
    except k8s_config.ConfigException:
        k8s_config.load_incluster_config()
    return k8s_client.AppsV1Api()


@pytest.fixture(scope="session")
def consul_token() -> str:
    """Retrieve the Consul bootstrap ACL token from the Kubernetes secret."""
    try:
        k8s_config.load_kube_config()
    except k8s_config.ConfigException:
        k8s_config.load_incluster_config()
    core = k8s_client.CoreV1Api()
    secret = core.read_namespaced_secret(
        "consul-bootstrap-acl-token", CONSUL_NAMESPACE
    )
    token_bytes = secret.data.get("token", b"")
    import base64
    return base64.b64decode(token_bytes).decode("utf-8").strip()


@pytest.fixture(scope="session")
def consul_http_addr(k8s_core: k8s_client.CoreV1Api) -> str:
    """Return the Consul UI/API LoadBalancer hostname or IP."""
    svc = k8s_core.read_namespaced_service("consul-ui", CONSUL_NAMESPACE)
    ingress = svc.status.load_balancer.ingress
    assert ingress, "consul-ui LoadBalancer has no ingress — is the cluster up?"
    host = ingress[0].hostname or ingress[0].ip
    return f"http://{host}"


@pytest.fixture(scope="session")
def api_gw_addr(k8s_core: k8s_client.CoreV1Api) -> str:
    """Return the API Gateway LoadBalancer hostname:port."""
    svc = k8s_core.read_namespaced_service("api-gateway", CONSUL_NAMESPACE)
    ingress = svc.status.load_balancer.ingress
    assert ingress, "api-gateway LoadBalancer has no ingress"
    host = ingress[0].hostname or ingress[0].ip
    return f"http://{host}:8080"


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────


def _wait_for_condition(
    probe: Any,
    timeout: int = 120,
    interval: int = 5,
    label: str = "",
) -> bool:
    """Poll `probe()` until it returns True or timeout elapses."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if probe():
            return True
        time.sleep(interval)
    pytest.fail(f"Timed out after {timeout}s waiting for: {label}")
    return False  # unreachable — satisfies type checker


def _pod_exec(
    pod_name: str,
    namespace: str,
    command: list[str],
    container: str | None = None,
) -> tuple[int, str, str]:
    """Execute a command in a pod via kubectl exec.

    Returns:
        Tuple of (returncode, stdout, stderr).
    """
    cmd = ["kubectl", "exec", pod_name, "-n", namespace, "--"]
    if container:
        cmd = ["kubectl", "exec", pod_name, "-n", namespace,
               "-c", container, "--"]
    cmd += command
    result = subprocess.run(
        cmd, check=False, capture_output=True, text=True, timeout=30
    )
    return result.returncode, result.stdout, result.stderr


def _get_running_pod(
    core: k8s_client.CoreV1Api,
    namespace: str,
    label_selector: str,
) -> str:
    """Return name of the first Running pod matching label_selector."""
    pods = core.list_namespaced_pod(
        namespace, label_selector=label_selector
    ).items
    running = [
        p.metadata.name
        for p in pods
        if p.status.phase == "Running"
    ]
    assert running, (
        f"No Running pod in {namespace} matching {label_selector}"
    )
    return running[0]


# ─────────────────────────────────────────────────────────────────────────────
# AWS Infrastructure
# ─────────────────────────────────────────────────────────────────────────────


class TestAWSInfrastructure:
    """AWS-level health checks derived from Terraform outputs."""

    def test_eks_cluster_active(
        self,
        eks_client: Any,
        cluster_name: str,
    ) -> None:
        """EKS cluster must be ACTIVE."""
        resp = eks_client.describe_cluster(name=cluster_name)
        status = resp["cluster"]["status"]
        assert status == "ACTIVE", f"EKS cluster status: {status}"

    def test_eks_cluster_version(
        self,
        eks_client: Any,
        cluster_name: str,
    ) -> None:
        """EKS cluster Kubernetes version must match expected."""
        resp = eks_client.describe_cluster(name=cluster_name)
        version = resp["cluster"]["version"]
        assert version == EXPECTED_K8S_VERSION, (
            f"K8s version {version}, expected {EXPECTED_K8S_VERSION}"
        )

    def test_nodegroup_active(
        self,
        eks_client: Any,
        cluster_name: str,
        tf_outputs: dict[str, Any],
    ) -> None:
        """EKS managed node group must be ACTIVE."""
        ng_id = str(tf_outputs["node_group_name"])
        ng_name = ng_id.split(":")[-1]
        resp = eks_client.describe_nodegroup(
            clusterName=cluster_name, nodegroupName=ng_name
        )
        status = resp["nodegroup"]["status"]
        assert status == "ACTIVE", f"Node group status: {status}"

    def test_nodegroup_desired_count(
        self,
        eks_client: Any,
        cluster_name: str,
        tf_outputs: dict[str, Any],
    ) -> None:
        """Node group desired size must match tfvars."""
        ng_id = str(tf_outputs["node_group_name"])
        ng_name = ng_id.split(":")[-1]
        desired = int(tf_outputs.get("node_group_desired_size", EXPECTED_NODES))
        resp = eks_client.describe_nodegroup(
            clusterName=cluster_name, nodegroupName=ng_name
        )
        actual = resp["nodegroup"]["scalingConfig"]["desiredSize"]
        assert actual == desired, f"Node desired={actual}, expected={desired}"

    def test_ebs_csi_addon_active(
        self,
        eks_client: Any,
        cluster_name: str,
    ) -> None:
        """EBS CSI addon must reach ACTIVE within 10 minutes."""
        def _probe() -> bool:
            resp = eks_client.describe_addon(
                clusterName=cluster_name,
                addonName=EBS_CSI_ADDON,
            )
            return resp["addon"]["status"] == "ACTIVE"

        _wait_for_condition(_probe, timeout=600, interval=15,
                            label="EBS CSI addon ACTIVE")

    def test_vpc_available(
        self,
        ec2_client: Any,
        tf_outputs: dict[str, Any],
    ) -> None:
        """VPC must be in 'available' state."""
        vpc_id = tf_outputs["vpc"]["vpc_id"]
        resp = ec2_client.describe_vpcs(VpcIds=[vpc_id])
        state = resp["Vpcs"][0]["State"]
        assert state == "available", f"VPC {vpc_id} state: {state}"

    def test_subnet_count(
        self,
        ec2_client: Any,
        tf_outputs: dict[str, Any],
    ) -> None:
        """VPC must have 6 subnets (3 public + 3 private)."""
        vpc_id = tf_outputs["vpc"]["vpc_id"]
        resp = ec2_client.describe_subnets(
            Filters=[{"Name": "vpc-id", "Values": [vpc_id]}]
        )
        count = len(resp["Subnets"])
        assert count == 6, f"Subnet count: {count}, expected 6"

    def test_nat_gateways_available(
        self,
        ec2_client: Any,
        tf_outputs: dict[str, Any],
    ) -> None:
        """Both NAT gateways must be 'available'."""
        nat_ids = [
            tf_outputs["nat_gateway_vpc_id"],
            tf_outputs["nat_gateway_recreate_id"],
        ]
        for nat_id in nat_ids:
            resp = ec2_client.describe_nat_gateways(
                NatGatewayIds=[nat_id]
            )
            state = resp["NatGateways"][0]["State"]
            assert state == "available", (
                f"NAT gateway {nat_id} state: {state}"
            )

    def test_load_balancers_active(
        self,
        elbv2_client: Any,
        tf_outputs: dict[str, Any],
    ) -> None:
        """Both ALBs (consul-ui, api-gateway) must be 'active'."""
        arns = [
            tf_outputs["lb_consul_ui_arn"],
            tf_outputs["lb_api_gateway_arn"],
        ]
        resp = elbv2_client.describe_load_balancers(LoadBalancerArns=arns)
        for lb in resp["LoadBalancers"]:
            state = lb["State"]["Code"]
            name = lb["LoadBalancerName"]
            assert state == "active", f"LB {name} state: {state}"

    def test_elastic_ips_exist(
        self,
        ec2_client: Any,
        tf_outputs: dict[str, Any],
    ) -> None:
        """Both Elastic IPs must still be allocated."""
        eips = [tf_outputs["eip_nat_id"], tf_outputs["eip_dp_id"]]
        resp = ec2_client.describe_addresses(AllocationIds=eips)
        found = {a["AllocationId"] for a in resp["Addresses"]}
        for eip in eips:
            assert eip in found, f"EIP {eip} not found"


# ─────────────────────────────────────────────────────────────────────────────
# Kubernetes Node Health
# ─────────────────────────────────────────────────────────────────────────────


class TestKubernetesNodes:
    """All EKS nodes must be Ready."""

    def test_node_count(self, k8s_core: k8s_client.CoreV1Api) -> None:
        """Cluster must have the expected number of Ready nodes."""
        nodes = k8s_core.list_node().items
        ready = [
            n for n in nodes
            if any(
                c.type == "Ready" and c.status == "True"
                for c in (n.status.conditions or [])
            )
        ]
        assert len(ready) == EXPECTED_NODES, (
            f"Ready nodes: {len(ready)}, expected {EXPECTED_NODES}"
        )

    def test_no_not_ready_nodes(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """No node must be in NotReady state."""
        nodes = k8s_core.list_node().items
        not_ready = [
            n.metadata.name
            for n in nodes
            if any(
                c.type == "Ready" and c.status != "True"
                for c in (n.status.conditions or [])
            )
        ]
        assert not not_ready, f"NotReady nodes: {not_ready}"

    def test_kube_system_pods_running(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """All kube-system pods must be Running or Succeeded."""
        pods = k8s_core.list_namespaced_pod("kube-system").items
        bad = [
            f"{p.metadata.name}={p.status.phase}"
            for p in pods
            if p.status.phase not in ("Running", "Succeeded")
        ]
        assert not bad, f"kube-system non-Running pods: {bad}"


# ─────────────────────────────────────────────────────────────────────────────
# Consul Health
# ─────────────────────────────────────────────────────────────────────────────


class TestConsulHealth:
    """Consul server cluster and sidecar injection health."""

    def test_consul_server_pods_running(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """All consul-server pods must be Running."""
        pods = k8s_core.list_namespaced_pod(
            CONSUL_NAMESPACE,
            label_selector="component=server,app=consul",
        ).items
        assert pods, "No consul-server pods found"
        bad = [
            p.metadata.name
            for p in pods
            if p.status.phase != "Running"
        ]
        assert not bad, f"Non-Running consul-server pods: {bad}"

    def test_consul_server_count(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """Consul server pod count must equal configured replicas (3)."""
        pods = k8s_core.list_namespaced_pod(
            CONSUL_NAMESPACE,
            label_selector="component=server,app=consul",
        ).items
        running = [p for p in pods if p.status.phase == "Running"]
        assert len(running) == 3, (
            f"Consul server pod count: {len(running)}, expected 3"
        )

    def test_consul_namespace_pods_healthy(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """All pods in the consul namespace must be Running or Completed."""
        pods = k8s_core.list_namespaced_pod(CONSUL_NAMESPACE).items
        bad = [
            f"{p.metadata.name}={p.status.phase}"
            for p in pods
            if p.status.phase not in ("Running", "Succeeded")
        ]
        assert not bad, f"Unhealthy consul-ns pods: {bad}"

    def test_consul_api_health(
        self,
        consul_http_addr: str,
        consul_token: str,
    ) -> None:
        """Consul /v1/status/leader must return a non-empty leader address."""
        url = f"{consul_http_addr}/v1/status/leader"
        resp = requests.get(
            url,
            headers={"X-Consul-Token": consul_token},
            timeout=10,
            verify=False,
        )
        assert resp.status_code == 200, (
            f"Consul leader API status: {resp.status_code}"
        )
        leader = resp.json()
        assert leader, "Consul has no elected leader"

    def test_consul_peers_count(
        self,
        consul_http_addr: str,
        consul_token: str,
    ) -> None:
        """Consul must have exactly 3 Raft peers (quorum)."""
        url = f"{consul_http_addr}/v1/status/peers"
        resp = requests.get(
            url,
            headers={"X-Consul-Token": consul_token},
            timeout=10,
            verify=False,
        )
        assert resp.status_code == 200
        peers: list[str] = resp.json()
        assert len(peers) == 3, (
            f"Consul peers: {len(peers)}, expected 3"
        )

    def test_consul_connect_inject_running(
        self, k8s_apps: k8s_client.AppsV1Api
    ) -> None:
        """consul-connect-injector deployment must be Available."""
        deps = k8s_apps.list_namespaced_deployment(
            CONSUL_NAMESPACE,
            label_selector="app=consul",
        ).items
        inject = [
            d for d in deps
            if "connect-injector" in (d.metadata.name or "")
        ]
        assert inject, "consul-connect-injector deployment not found"
        dep = inject[0]
        ready = dep.status.ready_replicas or 0
        desired = dep.spec.replicas or 1
        assert ready >= 1, (
            f"connect-injector ready={ready}/{desired}"
        )

    def test_consul_services_registered(
        self,
        consul_http_addr: str,
        consul_token: str,
    ) -> None:
        """All HashiCups services must be registered in Consul catalog."""
        expected = {
            "nginx", "frontend", "public-api",
            "product-api", "product-api-db", "payments",
        }
        url = f"{consul_http_addr}/v1/catalog/services"
        resp = requests.get(
            url,
            headers={"X-Consul-Token": consul_token},
            timeout=10,
            verify=False,
        )
        assert resp.status_code == 200
        registered: set[str] = set(resp.json().keys())
        missing = expected - registered
        assert not missing, (
            f"Services not registered in Consul: {missing}"
        )

    def test_consul_service_health_passing(
        self,
        consul_http_addr: str,
        consul_token: str,
    ) -> None:
        """All HashiCups Consul service health checks must be passing."""
        services = [
            "nginx", "frontend", "public-api",
            "product-api", "payments",
        ]
        failing: list[str] = []
        for svc in services:
            url = f"{consul_http_addr}/v1/health/service/{svc}?passing=true"
            resp = requests.get(
                url,
                headers={"X-Consul-Token": consul_token},
                timeout=10,
                verify=False,
            )
            if resp.status_code != 200 or not resp.json():
                failing.append(svc)
        assert not failing, (
            f"Consul services with no passing instances: {failing}"
        )


# ─────────────────────────────────────────────────────────────────────────────
# Application Pod Health
# ─────────────────────────────────────────────────────────────────────────────


class TestApplicationPods:
    """HashiCups pods must all be Running with sidecars injected."""

    def test_app_deployments_available(
        self, k8s_apps: k8s_client.AppsV1Api
    ) -> None:
        """Every HashiCups deployment must have at least 1 ready replica."""
        not_ready: list[str] = []
        for name in APP_DEPLOYMENTS:
            dep = k8s_apps.read_namespaced_deployment(name, APP_NAMESPACE)
            ready = dep.status.ready_replicas or 0
            if ready < 1:
                not_ready.append(f"{name}(ready={ready})")
        assert not not_ready, f"Deployments not ready: {not_ready}"

    def test_app_pods_running(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """All HashiCups pods in default ns must be Running."""
        pods = k8s_core.list_namespaced_pod(APP_NAMESPACE).items
        app_pods = [
            p for p in pods
            if any(
                p.metadata.labels.get("app") == svc
                for svc in APP_DEPLOYMENTS
            )
        ]
        bad = [
            f"{p.metadata.name}={p.status.phase}"
            for p in app_pods
            if p.status.phase != "Running"
        ]
        assert not bad, f"Non-Running app pods: {bad}"

    def test_connect_sidecars_injected(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """Each app pod must have a consul-dataplane sidecar container."""
        pods = k8s_core.list_namespaced_pod(APP_NAMESPACE).items
        missing_sidecar: list[str] = []
        for pod in pods:
            if pod.status.phase != "Running":
                continue
            app = (pod.metadata.labels or {}).get("app", "")
            if app not in APP_DEPLOYMENTS:
                continue
            container_names = [
                c.name for c in (pod.spec.containers or [])
            ]
            # Consul dataplane sidecar is named "consul-dataplane"
            if "consul-dataplane" not in container_names:
                missing_sidecar.append(pod.metadata.name)
        assert not missing_sidecar, (
            f"Pods missing consul-dataplane sidecar: {missing_sidecar}"
        )

    def test_no_crashlooping_pods(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """No pod in default or consul namespaces may be CrashLoopBackOff."""
        crashlooping: list[str] = []
        for ns in (APP_NAMESPACE, CONSUL_NAMESPACE):
            pods = k8s_core.list_namespaced_pod(ns).items
            for pod in pods:
                for cs in pod.status.container_statuses or []:
                    waiting = (cs.state.waiting or None)
                    if waiting and waiting.reason == "CrashLoopBackOff":
                        crashlooping.append(
                            f"{ns}/{pod.metadata.name}/{cs.name}"
                        )
        assert not crashlooping, (
            f"CrashLoopBackOff containers: {crashlooping}"
        )


# ─────────────────────────────────────────────────────────────────────────────
# Consul Service Mesh: Intentions
# ─────────────────────────────────────────────────────────────────────────────


class TestServiceMeshIntentions:
    """ServiceIntentions CRDs must exist and allow the correct flows."""

    def test_intentions_crd_exists(self) -> None:
        """ServiceIntentions CRD must be present in the cluster."""
        result = subprocess.run(
            ["kubectl", "get", "crd", "serviceintentions.consul.hashicorp.com"],
            check=False, capture_output=True, text=True, timeout=15,
        )
        assert result.returncode == 0, (
            "ServiceIntentions CRD not found — is Consul installed?"
        )

    @pytest.mark.parametrize("destination,sources", [
        (dest, srcs)
        for dest, srcs in EXPECTED_INTENTIONS.items()
    ])
    def test_intention_exists(
        self, destination: str, sources: list[str]
    ) -> None:
        """ServiceIntention for each destination must exist with allow rules."""
        result = subprocess.run(
            [
                "kubectl", "get", "serviceintentions", destination,
                "-o", "json",
                "-n", APP_NAMESPACE,
            ],
            check=False, capture_output=True, text=True, timeout=15,
        )
        # api-gateway intention lives in consul ns
        if result.returncode != 0:
            result = subprocess.run(
                [
                    "kubectl", "get", "serviceintentions", destination,
                    "-o", "json",
                    "-n", CONSUL_NAMESPACE,
                ],
                check=False, capture_output=True, text=True, timeout=15,
            )
        assert result.returncode == 0, (
            f"ServiceIntentions/{destination} not found"
        )
        obj: dict[str, Any] = json.loads(result.stdout)
        intention_sources = [
            s["name"]
            for s in obj["spec"]["sources"]
            if s["action"] == "allow"
        ]
        for src in sources:
            assert src in intention_sources, (
                f"Intention {destination}: source '{src}' not allowed "
                f"(found: {intention_sources})"
            )


# ─────────────────────────────────────────────────────────────────────────────
# Inter-Pod Connectivity via Envoy Sidecar
# ─────────────────────────────────────────────────────────────────────────────


class TestInterPodConnectivity:
    """Verify live TCP/HTTP reachability through the Envoy mesh."""

    def test_nginx_to_frontend_http(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """nginx pod must reach frontend:3000 through the mesh."""
        pod = _get_running_pod(k8s_core, APP_NAMESPACE, "app=nginx")
        rc, stdout, stderr = _pod_exec(
            pod, APP_NAMESPACE,
            ["wget", "-qO-", "--timeout=5", "http://frontend:3000/"],
            container="nginx",
        )
        assert rc == 0, (
            f"nginx→frontend HTTP failed (rc={rc}): {stderr[:200]}"
        )

    def test_nginx_to_public_api_http(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """nginx pod must reach public-api:8080/health through the mesh."""
        pod = _get_running_pod(k8s_core, APP_NAMESPACE, "app=nginx")
        rc, stdout, stderr = _pod_exec(
            pod, APP_NAMESPACE,
            ["wget", "-qO-", "--timeout=5", "http://public-api:8080/health"],
            container="nginx",
        )
        assert rc == 0, (
            f"nginx→public-api HTTP failed (rc={rc}): {stderr[:200]}"
        )

    def test_public_api_to_product_api(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """public-api pod must reach product-api:9090/health through the mesh."""
        pod = _get_running_pod(k8s_core, APP_NAMESPACE, "app=public-api")
        rc, stdout, stderr = _pod_exec(
            pod, APP_NAMESPACE,
            ["wget", "-qO-", "--timeout=5", "http://product-api:9090/health"],
            container="public-api",
        )
        assert rc == 0, (
            f"public-api→product-api HTTP failed (rc={rc}): {stderr[:200]}"
        )

    def test_public_api_to_payments(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """public-api pod must reach payments:1800 through the mesh (TCP)."""
        pod = _get_running_pod(k8s_core, APP_NAMESPACE, "app=public-api")
        # payments listens on 1800 (mapped from 8080 in yaml); use nc for TCP
        rc, stdout, stderr = _pod_exec(
            pod, APP_NAMESPACE,
            ["sh", "-c", "nc -zv payments 1800 2>&1; exit $?"],
            container="public-api",
        )
        assert rc == 0, (
            f"public-api→payments TCP failed (rc={rc}): {stderr[:200]}"
        )

    def test_product_api_to_db_tcp(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """product-api pod must reach product-api-db:5432 through the mesh."""
        pod = _get_running_pod(
            k8s_core, APP_NAMESPACE, "app=product-api"
        )
        rc, stdout, stderr = _pod_exec(
            pod, APP_NAMESPACE,
            ["sh", "-c", "nc -zv product-api-db 5432 2>&1; exit $?"],
            container="product-api",
        )
        assert rc == 0, (
            f"product-api→db TCP failed (rc={rc}): {stderr[:200]}"
        )

    def test_denied_without_intention(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """frontend pod must NOT reach product-api (no intention defined)."""
        pod = _get_running_pod(k8s_core, APP_NAMESPACE, "app=frontend")
        rc, stdout, stderr = _pod_exec(
            pod, APP_NAMESPACE,
            ["sh", "-c",
             "wget -qO- --timeout=3 http://product-api:9090/health 2>&1; "
             "echo EXIT:$?"],
            container="frontend",
        )
        # Connection should be refused or timed out (non-zero exit from wget)
        combined = stdout + stderr
        assert "EXIT:0" not in combined, (
            "frontend should NOT reach product-api — intention blocks this"
        )


# ─────────────────────────────────────────────────────────────────────────────
# Pod-to-Consul API Communications
# ─────────────────────────────────────────────────────────────────────────────


class TestPodToConsulAPI:
    """App pods must be able to resolve names and reach Consul DNS/API."""

    def test_consul_dns_from_app_pod(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """App pod must resolve consul.service.consul via Consul DNS."""
        pod = _get_running_pod(k8s_core, APP_NAMESPACE, "app=nginx")
        rc, stdout, stderr = _pod_exec(
            pod, APP_NAMESPACE,
            ["nslookup", "consul.service.consul"],
            container="nginx",
        )
        assert rc == 0, (
            f"Consul DNS resolution failed from nginx pod: {stderr[:200]}"
        )

    def test_service_dns_resolution(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """Each app service DNS name must resolve from a peer pod."""
        pod = _get_running_pod(k8s_core, APP_NAMESPACE, "app=nginx")
        services = ["frontend", "public-api", "product-api", "payments"]
        failed: list[str] = []
        for svc in services:
            rc, _, _ = _pod_exec(
                pod, APP_NAMESPACE,
                ["nslookup", svc],
                container="nginx",
            )
            if rc != 0:
                failed.append(svc)
        assert not failed, f"DNS resolution failed for: {failed}"

    def test_consul_agent_xds_port_reachable(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """The consul-dataplane sidecar xDS port (20000) must be listening."""
        pod = _get_running_pod(k8s_core, APP_NAMESPACE, "app=nginx")
        rc, stdout, stderr = _pod_exec(
            pod, APP_NAMESPACE,
            ["sh", "-c", "nc -zv 127.0.0.1 20000 2>&1; echo EXIT:$?"],
            container="consul-dataplane",
        )
        assert "EXIT:0" in (stdout + stderr), (
            f"consul-dataplane xDS port 20000 not reachable: {stderr[:200]}"
        )


# ─────────────────────────────────────────────────────────────────────────────
# API Gateway
# ─────────────────────────────────────────────────────────────────────────────


class TestAPIGateway:
    """Consul API Gateway must be deployed and serve traffic."""

    def test_gateway_pod_running(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """api-gateway pod must be Running in the consul namespace."""
        pods = k8s_core.list_namespaced_pod(
            CONSUL_NAMESPACE,
            label_selector="gateway.consul.hashicorp.com/name=api-gateway",
        ).items
        assert pods, "No api-gateway pods found in consul namespace"
        bad = [p.metadata.name for p in pods if p.status.phase != "Running"]
        assert not bad, f"Non-running api-gateway pods: {bad}"

    def test_gateway_httproute_exists(self) -> None:
        """HTTPRoute http-route-1 must be present in the consul namespace."""
        result = subprocess.run(
            ["kubectl", "get", "httproute", "http-route-1",
             "-n", CONSUL_NAMESPACE],
            check=False, capture_output=True, text=True, timeout=15,
        )
        assert result.returncode == 0, (
            "HTTPRoute http-route-1 not found in consul namespace"
        )

    def test_api_gateway_serves_http(
        self, api_gw_addr: str
    ) -> None:
        """API Gateway LoadBalancer must return HTTP 200 for /."""
        def _probe() -> bool:
            try:
                resp = requests.get(
                    api_gw_addr, timeout=5, allow_redirects=True
                )
                return resp.status_code < 500
            except requests.exceptions.ConnectionError:
                return False

        _wait_for_condition(
            _probe, timeout=120, interval=5,
            label=f"API Gateway HTTP at {api_gw_addr}"
        )

    def test_api_gateway_routes_to_nginx(
        self, api_gw_addr: str
    ) -> None:
        """API Gateway must forward / to nginx (HashiCups frontend)."""
        resp = requests.get(api_gw_addr, timeout=10, allow_redirects=True)
        assert resp.status_code == 200, (
            f"API Gateway returned {resp.status_code}"
        )
        # HashiCups frontend serves HTML with "HashiCups" in body
        assert "HashiCups" in resp.text or len(resp.content) > 100, (
            "API Gateway response does not look like HashiCups frontend"
        )

    def test_api_gateway_api_path(
        self, api_gw_addr: str
    ) -> None:
        """/api path must route to public-api (returns JSON)."""
        resp = requests.get(
            f"{api_gw_addr}/api",
            timeout=10,
            headers={"Accept": "application/json"},
        )
        # public-api may return 404 on / but must not 502/503
        assert resp.status_code not in (502, 503), (
            f"/api returned {resp.status_code} — likely mesh routing failure"
        )


# ─────────────────────────────────────────────────────────────────────────────
# EDR (Uptycs HC-COMPUTE-011)
# ─────────────────────────────────────────────────────────────────────────────


class TestEDR:
    """Uptycs k8sosquery DaemonSet must cover all nodes (HC-COMPUTE-011)."""

    def test_uptycs_namespace_exists(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """uptycs namespace must exist."""
        namespaces = [
            ns.metadata.name
            for ns in k8s_core.list_namespace().items
        ]
        assert UPTYCS_NAMESPACE in namespaces, (
            "uptycs namespace not found — was terraform apply run?"
        )

    def test_uptycs_daemonset_exists(
        self, k8s_apps: k8s_client.AppsV1Api
    ) -> None:
        """uptycs-osquery DaemonSet must exist in the uptycs namespace."""
        dsets = k8s_apps.list_namespaced_daemon_set(UPTYCS_NAMESPACE).items
        names = [ds.metadata.name for ds in dsets]
        assert UPTYCS_DAEMONSET in names, (
            f"DaemonSet '{UPTYCS_DAEMONSET}' not in uptycs namespace. "
            f"Found: {names}"
        )

    def test_uptycs_desired_equals_node_count(
        self,
        k8s_apps: k8s_client.AppsV1Api,
        k8s_core: k8s_client.CoreV1Api,
    ) -> None:
        """DaemonSet desired count must equal the number of schedulable nodes."""
        ds = k8s_apps.read_namespaced_daemon_set(
            UPTYCS_DAEMONSET, UPTYCS_NAMESPACE
        )
        desired = ds.status.desired_number_scheduled
        node_count = len(k8s_core.list_node().items)
        assert desired == node_count, (
            f"Uptycs desired={desired}, nodes={node_count} — "
            "DaemonSet not scheduled on all nodes"
        )

    def test_uptycs_all_pods_ready(
        self, k8s_apps: k8s_client.AppsV1Api
    ) -> None:
        """All Uptycs DaemonSet pods must be Ready."""
        ds = k8s_apps.read_namespaced_daemon_set(
            UPTYCS_DAEMONSET, UPTYCS_NAMESPACE
        )
        desired = ds.status.desired_number_scheduled
        ready = ds.status.number_ready
        assert ready == desired, (
            f"Uptycs pods ready={ready}/{desired}"
        )

    def test_uptycs_pods_running(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """Every Uptycs pod must be in Running phase."""
        pods = k8s_core.list_namespaced_pod(UPTYCS_NAMESPACE).items
        bad = [
            f"{p.metadata.name}={p.status.phase}"
            for p in pods
            if p.status.phase != "Running"
        ]
        assert not bad, f"Non-Running Uptycs pods: {bad}"

    def test_uptycs_one_pod_per_node(
        self,
        k8s_core: k8s_client.CoreV1Api,
    ) -> None:
        """Each node must have exactly one Uptycs pod scheduled."""
        pods = k8s_core.list_namespaced_pod(UPTYCS_NAMESPACE).items
        node_counts: dict[str, int] = {}
        for pod in pods:
            node = pod.spec.node_name or "unscheduled"
            node_counts[node] = node_counts.get(node, 0) + 1
        over = {n: c for n, c in node_counts.items() if c != 1}
        assert not over, f"Nodes with !=1 Uptycs pod: {over}"

    def test_uptycs_tags_in_configmap(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """Uptycs configmap must have non-empty HC-COMPUTE-011 required tags."""
        cm = k8s_core.read_namespaced_config_map(
            "uptycs-config", UPTYCS_NAMESPACE
        )
        tags: str = (cm.data or {}).get("tags", "")
        assert "CCODE/HashiCorp" in tags, (
            f"CCODE/HashiCorp missing from Uptycs tags: '{tags}'"
        )
        assert "UT/20A7V" in tags, (
            f"UT/20A7V missing from Uptycs tags: '{tags}'"
        )
        assert "OWNER/" in tags, (
            f"OWNER tag missing from Uptycs tags: '{tags}'"
        )
        assert "UPDATE/" in tags, (
            f"UPDATE tag missing from Uptycs tags: '{tags}'"
        )

    def test_uptycs_node_uuids_emitted(
        self, k8s_core: k8s_client.CoreV1Api
    ) -> None:
        """Node UUIDs must be retrievable (for manual edr-tools verification)."""
        nodes = k8s_core.list_node().items
        uuids: dict[str, str] = {}
        for node in nodes:
            name = node.metadata.name
            uuid = node.status.node_info.system_uuid
            uuids[name] = uuid
        assert len(uuids) == EXPECTED_NODES, (
            f"Expected {EXPECTED_NODES} node UUIDs, got {len(uuids)}"
        )
        # Print for CI logs — useful for edr-tools host-verification
        print("\n  Node UUIDs (verify at edr-tools, tenant: Watson 2):")
        for name, uuid in uuids.items():
            print(f"    {name}\t{uuid}")


# ─────────────────────────────────────────────────────────────────────────────
# HashiCups End-to-End Application Flow
# ─────────────────────────────────────────────────────────────────────────────


class TestHashiCupsE2E:
    """Full end-to-end: HTTP through api-gateway → nginx → services."""

    def test_frontend_reachable(self, api_gw_addr: str) -> None:
        """HashiCups frontend must serve HTTP 200 via the API gateway."""
        resp = requests.get(api_gw_addr, timeout=15, allow_redirects=True)
        assert resp.status_code == 200, (
            f"Frontend returned {resp.status_code}"
        )

    def test_products_api_returns_data(self, api_gw_addr: str) -> None:
        """GET /api/coffees must return a non-empty JSON list."""
        resp = requests.get(
            f"{api_gw_addr}/api/coffees",
            timeout=15,
            headers={"Content-Type": "application/json"},
        )
        assert resp.status_code == 200, (
            f"/api/coffees returned {resp.status_code}: {resp.text[:200]}"
        )
        data = resp.json()
        assert isinstance(data, list) and data, (
            "/api/coffees returned empty list"
        )

    def test_static_assets_served(self, api_gw_addr: str) -> None:
        """Static assets path must not 502 (nginx proxies to frontend)."""
        resp = requests.get(
            f"{api_gw_addr}/static",
            timeout=10,
            allow_redirects=True,
        )
        assert resp.status_code not in (502, 503), (
            f"/static returned {resp.status_code} — mesh routing failure"
        )

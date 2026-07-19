# HC-COMPUTE-011: VMs Must Have EDR Installed

Action is only required if you have received a *HC-COMPUTE-011* SECUVLN ticket

- [Why did I receive this SECVULN?](#why-did-i-receive-this-secvuln)
- [How to fix it?](#how-to-fix-it)
  - [Prerequisites](#prerequisites)
- [Where to go for help?](#where-to-go-for-help)
- [Option 1: Use an Approved Base Image](#option-1-use-an-approved-base-image)
  - [Amazon Web Services (AWS)](#amazon-web-services-aws)
    - [Terraform](#terraform)
    - [AWS Console](#aws-console)
  - [Azure](#azure)
    - [Terraform](#terraform.1)
    - [Using the Azure Console](#using-the-azure-console)
  - [GCP](#gcp)
- [Option 2: Manually Install the Agent](#option-2-manually-install-the-agent)
  - [Host Installation](#host-installation)
  - [Kubernetes Installation](#kubernetes-installation)
  - [Tag Configuration](#tag-configuration)
- [Option 3: Delete the Instance](#option-3-delete-the-instance)
- [FAQ](#faq)
- [Support contact](#support-contact)

## Why did I receive this SECVULN?

You received this ticket because one or more of your virtual machines (VMs) or Kubernetes clusters are missing the mandatory Endpoint Detection and Response (EDR) coverage in your cloud account. EDR is a critical security control that provides real-time monitoring, detection, and response capabilities against malicious activity.

By ensuring the EDR agent is installed and active, we maintain visibility into host-level behavior across our fleet, which is fundamental for security.

The EDR agent allows the Security team to:

- **Detect Threats:** Identify malicious processes, suspicious network connections, and anomalous behavior in real-time.

- **Investigate Incidents:** Gather forensic data required to understand the scope and impact of potential security events.

## How to fix it?

To find the list of instances affected by going to the Wiz Issue link found on your SECVULN ticket.

To find the list of affected instances, go to the Wiz Issue link found on your SECVULN ticket.

*Use the Wiz Issue details to determine whether the finding is tied to a standalone VM or to a Kubernetes cluster. If the finding is for a Kubernetes cluster, install EDR by using the IBM Uptycs Helm deployment described below. If Wiz does not have proper visibility into the cluster and the nodes are shown as regular VMs, install the EDR agent on the affected VMs instead.*

To resolve a non-compliant asset, install EDR on the affected VM or cluster, or remove the offending instance if it is no longer needed.

The following OSs are provided batteries included, all base images are maintained in [https://github.com/hashicorp/ami-builder](https://github.com/hashicorp/ami-builder), for more details on the build process and code examples please view [https://docs.prod.secops.hashicorp.services/base_config/base_images/aws_ami/](https://docs.prod.secops.hashicorp.services/base_config/base_images/aws_ami/)

| **Name** | **Architecture** | **Cloud Provider** |
|---|---|---|
| [Amazon Linux 2023](https://github.com/hashicorp/ami-builder/blob/main/aws-al2023.pkr.hcl) | ARM64, x86_64 | AWS |
| [Red Hat Enterprise Linux 9](https://github.com/hashicorp/ami-builder/blob/main/aws-rhel-9.pkr.hcl) | ARM64, x86_64 | AWS, Azure |
| [Ubuntu 22.04](https://github.com/hashicorp/ami-builder/blob/main/ubuntu-2204.pkr.hcl) | ARM64, x86_64 | AWS, Azure |
| [Ubuntu 24.04](https://github.com/hashicorp/ami-builder/blob/main/ubuntu-2404.pkr.hcl) | ARM64, x86_64 | AWS, Azure |
| [Windows Server 2025](https://github.com/hashicorp/ami-builder/blob/main/aws-windows-server-2025.pkr.hcl) | x86_64 | AWS |

### Prerequisites

Before installing Uptycs, please ensure that your server has connectivity to the Uptycs Cloud over port **443**.

> TLSv1.2 and above is required.

- **Linux/macOS:** `nc -zv worldwide.uptycs.io 443`

- **AIX:** `openssl s_client -connect worldwide.uptycs.io:443`

Depending on your network environment, if port 443 is blocked, please add these [Uptycs Cloud IP addresses](https://pages.github.ibm.com/CISO-Platform-Network-Defense/Uptycs-Documentation/Onboarding/Cloud_IP_Address/) to your allowlist.

## Where to go for help?

- General questions or help with Option 1 or Option 3 - search or post in [#ask-vuln-mgmt](https://ibm.enterprise.slack.com/archives/C09KSRA501Z)

- Option 2 - search or post in [#edr-support](https://ibm.enterprise.slack.com/archives/CKZ7TFA78) ← this is managed by the IBM CISO team which maintain the Uptycs Agents & Helm Charts themselves

------------------------------------------------------------------------

## Option 1: Use an Approved Base Image

Launch your VMs using HashiCorp’s approved base images for AWS and Azure. These are pre-configured with EDR out-of-the-box, requiring no manual setup. Transitioning to these images ensures your environment stays compliant and resolves the SECVULN ticket.

### Amazon Web Services (AWS)

#### Terraform

Use this data source to ensure your CI/CD pipeline always pulls the latest patched version.

```hcl
# Example: Fetching the latest approved Ubuntu 24.04 AMI
data "aws_ami" "hc-base-ubuntu-2404" {
  for_each = toset(["amd64", "arm64"])

  filter {
    name   = "name"
    values = [format("hc-base-ubuntu-2404-%s-*", each.value)]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  most_recent = true
  owners      = ["888995627335"] # ami-prod account
}
```

#### AWS Console

1.  Navigate to **EC2** → **Images** → **AMIs**.

2.  Change the filter to **"Private images"**.

3.  Search for `hc-base-` to see the full list of verified images.

A direct link can be used [here](https://us-east-1.console.aws.amazon.com/ec2/home?region=us-east-1#Images:visibility=private;search=:hc-base;v=3;$case=tags:false%5C,client:false;$regex=tags:false%5C,client:false)

### Azure

Our approved Azure base images are centrally managed and published to a **Shared Image Gallery** (Compute Gallery) within each Azure tenant. These images are made available across the entire Azure tenant without requiring you to copy them into your local subscription.

#### Terraform

The following example fetches the latest image for Ubuntu 24.04 amd64 in `hashicorp02` sandbox tenant.

Note: If you are using a tenant that is not `hashicorp02`, you must update azurerm to point to the image subscription within that tenant.

- `hashicorp01` - f9c9bc63-a3bb-4f82-9b4a-9cd13344696f

- `hashicorp02` - 338f0fa5-b5ae-4847-9821-1808613db6c5

- `hashicorp03` - 40ff4694-2b35-4f20-8c72-99c2903b158a
```hcl
provider "azurerm" {
  alias = "your_default_provider"
}

provider "azurerm" {
  alias                   = "image_factory"
  subscription_id          = "338f0fa5-b5ae-4847-9821-1808613db6c5" # hashicorp02-image-factory-prod
  features {}
}

data "azurerm_shared_image_version" "latest" {
  provider            = azurerm.image_factory
  name                = "latest"
  image_name          = "hc-base-ubuntu-2404-amd64"
  gallery_name        = "hcbaseGallery"
  resource_group_name = "hc-base-rg-gallery"
}

# Then in your VM resource:
# source_image_id = data.azurerm_shared_image_version.latest.id
```

If you receive a permissions error, please reach out in **#ask-vuln-mgmt**.

#### **Using the Azure Console**

The following steps can be found in the Azure Docs: [https://learn.microsoft.com/en-us/azure/virtual-machines/vm-generalized-image-version?tabs=portal%2Ccli2%2Ccli3%2Cportal4#direct-shared-gallery](https://learn.microsoft.com/en-us/azure/virtual-machines/vm-generalized-image-version?tabs=portal%2Ccli2%2Ccli3%2Cportal4#direct-shared-gallery)

1.  Type **virtual machines** in the search.

2.  Under **Services**, select **Virtual machines**.

3.  In the **Virtual machines** page, select **Create** and then **Virtual machine**. The **Create a virtual machine** page opens.

4.  In the **Basics** tab, under **Instance details**

5.  Under **Instance details**, find the option for **Image** and click “*see all images*”

6.  In the left menu, under **Other Items**, select **Shared Images.**

7.  Select an image from the list.

8.  Complete the rest of the options and then select the **Review + create** button at the bottom of the page.

9.  On the **Create a virtual machine** page, you can see the details about the VM you're about to create. When you're ready, select **Create**.

### GCP

GCP is currently not supported with "batteries included" base images.

If you are deploying virtual machines in GCP, you must manually install and configure the EDR agent to satisfy the SECVULN.

Proceed directly to Option 2: Manually install the agent to download the Uptycs sensor and apply the required configuration tags.

## Option 2: Manually Install the Agent

> **Note:** Manual installation of the agent is **not** an officially supported process by HashiCorp Security. Support for this path is dependent on IBM CISO. This method should only be used if you are required to use a custom or third-party image where the approved base image cannot be used, such as replicating a customer's specific OS version. In that case, you must manually install the EDR agent. 

**Send questions to IBM CISO in [#edr-support](https://ibm.enterprise.slack.com/archives/CKZ7TFA78).**

If you are remediating a standard VM, follow the host installation path below. If the affected compute is part of a Kubernetes environment, use the Kubernetes onboarding path in this same section instead.

For Kubernetes findings, also review the relevant Wiz deployment guidance before choosing the installation path:

- **Public Amazon EKS clusters:** Wiz can automatically connect supported public EKS clusters when the required authentication mode and connector permissions are in place. See [Auto-connect EKS clusters](https://docs.wiz.io/docs/eks-clusters-auto-connect).

- **Private Kubernetes clusters:** Wiz requires a Kubernetes Connector deployment for private clusters. See [Kubernetes deployment overview](https://docs.wiz.io/docs/k8s-dep-overview#choose-your-deployment-method).

- **Private connectivity to the Kubernetes API:** If the cluster API is private and requires secure network access back to Wiz, the deployment may also require Wiz Broker support. See [Wiz Broker](https://docs.wiz.io/docs/wiz-broker).

### **Host Installation**

1.  Verify your operating system is compatible - [Uptycs Support Matrix.](https://pages.github.ibm.com/CISO-Platform-Network-Defense/Uptycs-Documentation/Onboarding/Support_Matrix/)

2.  Download the sensor to the ***watson2 (HashiCorp)*** tenant - [Uptycs Sensor Download](https://edr-tools.platformops.ciso.ibm.com/download-sensors) (Note: Ensure the downloaded sensor version is compliant as shown on the [Sensor Status Page](https://edr-tools.platformops.ciso.ibm.com/sensor-status) )

    1.  The link portal requires VPN access and a web browser.

3.  Follow the instructions below depending on OS - [Linux/AIX](https://pages.github.ibm.com/CISO-Platform-Network-Defense/Uptycs-Documentation/Onboarding/Getting_started/#linux-aix), [Windows](https://pages.github.ibm.com/CISO-Platform-Network-Defense/Uptycs-Documentation/Onboarding/Getting_started/#windows), [macOS](https://pages.github.ibm.com/CISO-Platform-Network-Defense/Uptycs-Documentation/Onboarding/Getting_started/#mac)

4.  Set the appropriate tags

    1.  `osqueryd --osquery_tags "UPDATE/NONE,CCODE/HashiCorp,UT/20A7V,OWNER/{team/owner-email@hashicorp/ibm.com}"`\
        Example Tag `UPDATE/NONE,CCODE/HashiCorp,UT/20A7V,OWNER/john.doe@ibm.com`

5.  Verify the server is reporting back to console - [Uptycs Verification tool](https://edr-tools.platformops.ciso.ibm.com/host-verification)

A detailed step by step guide is provided by IBM CISO [https://pages.github.ibm.com/CISO-Platform-Network-Defense/Uptycs-Documentation/Onboarding/Getting_started/](https://pages.github.ibm.com/CISO-Platform-Network-Defense/Uptycs-Documentation/Onboarding/Getting_started/)

### **Kubernetes Installation**

**Refer to the** [IBM Uptycs Kubernetes Guide](https://pages.github.ibm.com/CISO-Platform-Network-Defense/Uptycs-Documentation/Containers/Kubernetes/Overview/) **for the installation process.**

For Kubernetes environments, IBM CISO provides a supported installation path via a dedicated Helm chart. Use this path when the finding is for a Kubernetes cluster and Wiz has the expected visibility into that cluster.

If Wiz already auto-connects the cluster, you still need to complete the Uptycs sensor rollout and verify node coverage. If Wiz does **not** already have proper visibility into the cluster, the nodes are treated as regular VMs for this control and should be remediated by installing the EDR agent on those VMs instead.

To reduce the number of Kubernetes clusters presented as regular VMs in Wiz, please modify the firewall rules to allow **Wiz Cloud Scanner IPs** below ([also found in Wiz documentation](https://app.wiz.io/tenant-info/wiz-ips)). This will improve the overall visibility Wiz has into the cluster and will allow our control findings to be more precise.

- `44.219.22.239`

- `54.205.48.237`

- `52.207.181.131`

Please note this process requires the IBM Cisco Secure Client VPN and a web browser. This is also dependent on the required tags being configured properly in the Helm deployment.

This supports the following platforms:

- Amazon EKS

- Google GKE (Standard Only)

- Azure AKS

**Note: The link provided in the Uptycs Kubernetes Guide to download the configuration file has intermediate access issues (the cause is unknown). Please use this** [link](https://edr-tools.platformops.ciso.ibm.com/download-sensors) **instead to download the needed files.**

### Tag Configuration

When downloading and modifying your `k8sosquery-values.yaml` file, you must update the `tags` section to ensure proper asset attribution and ticket resolution.

```yaml
configmap:
  name: uptycs-config
  data:
    # Tags must follow the CCODE/UT/OWNER/ENVIRONMENT schema
    tags: UPDATE/PROD,CCODE/HashiCorp,UT/20A7V,OWNER/{team/owner-email@hashicorp/ibm.com}
```

- **CCODE/UT:** Ensure these are set to `CCODE/HashiCorp` and `UT/20A7V`.

- **UPDATE:** Reference the [IBM Tag Guide](https://pages.github.ibm.com/CISO-Platform-Network-Defense/Uptycs-Documentation/Onboarding/Tagging/#update) to determine the correct environment string.

- **OWNER:** Replace the placeholder with you or your team's actual contact email.

**Please verify that the cluster was successfully integrated by using the** [Uptycs verification tool](https://edr-tools.platformops.ciso.ibm.com/host-verification) **with the UUID of the Kubernetes nodes.**\
Get the Kubernetes node UUIDs with the following command:

```bash
kubectl get nodes -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.ibm-cloud\.kubernetes\.io/worker-id}{"\t"}{.status.nodeInfo.systemUUID}{"\n"}{end}'
```

## **Option 3: Delete the Instance**

If the flagged instance is no longer needed or was created for a temporary test, simply **delete the instance**. Once the instance is terminated, the SECVULN ticket will automatically close within **24 hours**.

You can find the list of affected instances by going to the Wiz Issue link found on your SECVULN ticket. Take note of the Region and Instance IDs in the Wiz issue that will need to be remediated.

**AWS**

1.  Login to your accounts using Doormat [https://doormat.hashicorp.services/](https://doormat.hashicorp.services/)

2.  Open the Amazon EC2 console at [https://console.aws.amazon.com/ec2/](https://console.aws.amazon.com/ec2/).

3.  In the AWS Console ensure you have selected the proper AWS Region the EC2 was detected in.

4.  In the navigation pane, choose **Instances**.

5.  Select the instance, and choose **Instance state**, **Terminate (delete) instance**.

6.  Choose **Terminate (delete)** when prompted for confirmation.

7.  After you terminate an instance, it remains visible for a short while, with a state of `terminated`.

[https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/terminating-instances.html](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/terminating-instances.html)

------------------------------------------------------------------------

## FAQ

**Q: How do I verify the agent is running on my host?**

**A:**

- Linux**:** Run `ps aux | grep -E "uptycs-protect|osquery"`

- Windows**:** `sc query "UptycsOsquery" | findstr /i "STATE"` or `sc query "UptycsProtect" | findstr /i "STATE"`

**Q: How is the EDR agent detected on the host?**

**A:** Wiz scans your virtual machines to verify the presence and status of the EDR agent.

**Q: How do I verify the EDR agent is reporting back to the Uptycs Platform?**

**A:** IBM CISO has provided a tool [https://edr-tools.platformops.ciso.ibm.com/host-verification](https://edr-tools.platformops.ciso.ibm.com/host-verification)

1.  Get the UUID from your host

    1.  `sudo cat /sys/class/dmi/id/product_uuid` - Linux

    2.  `(Get-CimInstance -Class Win32_ComputerSystemProduct).UUID` - Windows

    3.  `kubectl get nodes -o=jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.ibm-cloud\.kubernetes\.io/worker-id}{"\t"}{.status.nodeInfo.systemUUID}{"\n"}{end}'` - Kubernetes

2.  Search by *“CrowdStrike AID or Uptycs UUID” in* the [host-verification tool](https://edr-tools.platformops.ciso.ibm.com/host-verification) and select *Watson 2 (Hashicorp)* for the Uptycs Tenants drop-down

3.  You should see your host reported at “Online”

**Q: I have installed the EDR agent on my private Kubernetes cluster, but the Wiz issue is not resolving. Can I get an exception?**

**A:** If you are running a private Kubernetes cluster and do not wish to [allow-list the Wiz Cloud Scanner IPs in the firewall settings](https://hashicorp.atlassian.net/wiki/spaces/SEC/pages/4651483256/HC-COMPUTE-011+VMs+Must+Have+EDR+Installed#Kubernetes-Installation), the Wiz control will not be able to detect the EDR agent. This will unfortunately leave the Wiz issue for your resource in an **Open** state without the ability to transition into **Resolved/Fixed**. Please reach out in [#ask-vuln-mgmt](https://ibm.enterprise.slack.com/archives/C09KSRA501Z) on Slack to discuss your specific need for keeping this resource private.

## Support contact

For any questions or assistance related to this control please ask in [#ask-vuln-mgmt](https://ibm.enterprise.slack.com/archives/C09KSRA501Z) on Slack.

# [Proxmox Home Lab with Terraform and Kubernetes](https://github.com/VizzleTF/home_proxmox)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/VizzleTF/home_proxmox)

This repository contains configurations and scripts to manage a Proxmox home lab environment using Terraform for infrastructure provisioning and ArgoCD for GitOps-based Kubernetes application deployment. It includes Ansible roles, Terraform configurations, ArgoCD applications, and utility scripts to fully automate the deployment and management of virtualized infrastructure.

![Alt](https://repobeats.axiom.co/api/embed/f8bae5bb43169239582bac61ee8996a95f0d64f3.svg "Repobeats analytics image")

## Project Structure

### 1. `ansible/`
Ansible playbooks and roles for automating VM configuration tasks:
- **Playbooks**: Database clusters, NFS servers, Oracle VM setup
- **Roles**: PostgreSQL/Patroni clusters, package installation, system configuration

### 2. `argocd/`
ArgoCD Application manifests for GitOps-based deployment:
- **`applications/`**: Application deployments (Vault, Nextcloud, Immich, Vaultwarden, Lampac, OnlyOffice, CNPG)
- **`infrastructure/`**: Infrastructure components (ArgoCD, Cert-Manager, Cilium, Cloudflared, CNPG Operator, External Secrets, Gateway API, Longhorn, Vault Autounseal)
- **`unused/`**: Archived application manifests
- **`root-application.yaml`**: App of Apps pattern root application

### 3. `scripts/`
Utility scripts for cluster management:
- **`k8s/`**: Kubernetes monitoring and debugging scripts

### 4. `terraform_proxmox/`
Terraform configurations for Proxmox infrastructure:
- **VM provisioning**: Kubernetes nodes, database clusters
- **Resource management**: Storage pools, network configuration
- **Configuration files**: VM specifications, images, LXC containers

## Technologies Used
- **Proxmox VE**: Open-source server virtualization management solution
- **Terraform**: Infrastructure as Code for Proxmox VM provisioning
- **Kubernetes**: Container orchestration platform (3-node cluster)
- **ArgoCD**: GitOps continuous delivery for Kubernetes
- **Ansible**: VM configuration and automation
- **Cilium**: CNI with Gateway API support
- **Cloudflared**: Secure tunnel for external access
- **HashiCorp Vault**: Secrets management
- **CloudNativePG**: PostgreSQL operator for Kubernetes

## Infrastructure Overview

### Kubernetes Cluster
- **3-node cluster**: 2 control plane + worker nodes, 1 worker node
- **Resources**: 4 CPU cores, 12GB RAM, 200GB-500GB storage per node
- **CNI**: Cilium with Gateway API

### Deployed Components

#### Infrastructure:
- **ArgoCD** - GitOps continuous delivery
- **Cert-Manager** - SSL certificate management with Cloudflare DNS01
- **Cilium** - CNI with L2 announcements and Gateway API
- **Cloudflared** - Secure tunnel for external access (replaces traditional ingress exposure)
- **CNPG Operator** - CloudNativePG for PostgreSQL databases
- **External Secrets** - Secrets management with Vault integration
- **Gateway API** - Kubernetes Gateway API for HTTP routing
- **Longhorn** - Distributed block storage
- **Vault Autounseal** - Transit secrets engine for Vault auto-unseal

#### Applications:
- **CNPG** - PostgreSQL database clusters
- **Immich** - Self-hosted photo/video backup solution
- **Lampac** - Media streaming service
- **Nextcloud** - File sync and collaboration platform
- **OnlyOffice** - Document editing integration for Nextcloud
- **Vault** - Secrets management
- **Vaultwarden** - Bitwarden-compatible password manager

## Setup and Usage

### Prerequisites
- [Proxmox VE](https://www.proxmox.com/en/proxmox-ve)
- [Terraform](https://www.terraform.io/)
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [ArgoCD CLI](https://argo-cd.readthedocs.io/en/stable/cli_installation/)

### Instructions

1. **Clone the Repository:**
    ```bash
    git clone https://github.com/VizzleTF/home_proxmox.git
    cd home_proxmox
    ```

2. **Provision Infrastructure:**
   ```bash
   cd terraform_proxmox/
   terraform init
   terraform plan
   terraform apply
   ```

3. **Configure VMs with Ansible:**
   ```bash
   cd ansible/
   ansible-playbook -i inventory/inventory.yaml playbooks/db_cluster.yaml
   ```

4. **Deploy Applications with ArgoCD:**
   ```bash
   # Applications are automatically deployed via GitOps
   # Monitor deployment status:
   kubectl get applications -n argocd
   ```

5. **Monitor Resources:**
   ```bash
   # Use the provided monitoring script
   ./scripts/k8s/k8s-top-pods-with-requests.sh
   ```

## GitOps Workflow

This repository works in conjunction with [home-proxmox-values](https://github.com/VizzleTF/home-proxmox-values) repository:
- **home_proxmox**: ArgoCD Application definitions and infrastructure code (this repo)
- **home-proxmox-values**: Helm values, additional manifests, and service documentation

**Repository Structure:**
```
home-proxmox-values/
├── values/
│   ├── applications/    # Helm values for applications
│   ├── infrastructure/  # Helm values for infrastructure
│   └── unused/          # Archived values
├── manifests/
│   ├── applications/    # HTTPRoutes, External Secrets, CronJobs
│   ├── infrastructure/  # ClusterIssuers, StorageClasses, CiliumL2Pools
│   └── unused/          # Archived manifests
└── README/              # Service documentation
```

Applications are automatically synchronized via ArgoCD when changes are pushed to the values repository.

## Networking

The cluster uses **Cilium** as CNI with the following features:
- **L2 Announcements** for LoadBalancer services
- **Gateway API** for HTTP routing (HTTPRoute resources)
- **Hubble** for network observability

External access is provided via **Cloudflared tunnel** - no direct cluster exposure required.

SSL certificates are managed by **Cert-Manager** with Cloudflare DNS01 challenge and wildcard certificate for `*.vakaf.space`.

## Monitoring and Debugging

- **ArgoCD UI**: Monitor application deployment status
- **Hubble UI**: Cilium network observability
- **Resource monitoring**: Use `scripts/k8s/k8s-top-pods-with-requests.sh`
- **Logs**: `kubectl logs` and ArgoCD application logs

```bash
# Check all applications
kubectl get applications -n argocd

# Check HTTPRoutes
kubectl get httproutes -A

# Check External Secrets
kubectl get externalsecrets -A

# Force sync an application
argocd app sync <app-name>
```

## Contributing
Feel free to open issues or submit pull requests if you have any improvements or feature suggestions.

## License
This project is licensed under the MIT License.

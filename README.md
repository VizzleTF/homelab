# [Proxmox Home Lab with Terraform and Kubernetes](https://github.com/VizzleTF/home_proxmox)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/VizzleTF/home_proxmox)
This repository contains configurations and scripts to manage a Proxmox home lab environment using Terraform for infrastructure provisioning and ArgoCD for GitOps-based Kubernetes application deployment. It includes Ansible roles, Terraform configurations, ArgoCD applications, and utility scripts to fully automate the deployment and management of virtualized infrastructure.

## Project Structure

### 1. `ansible/`
Ansible playbooks and roles for automating VM configuration tasks:
- **Playbooks**: Database clusters, NFS servers, Oracle VM setup
- **Roles**: PostgreSQL/Patroni clusters, package installation, system configuration

### 2. `argocd/`
ArgoCD Application manifests for GitOps-based deployment:
- **`applications/`**: Application deployments (Vault, Nextcloud, CouchDB, N8N, etc.)
- **`infrastructure/`**: Infrastructure components (Prometheus, Grafana, Ingress, Cert-Manager, etc.)

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
- **PostgreSQL/Patroni**: High-availability database cluster

## Infrastructure Overview

### Kubernetes Cluster
- **3-node cluster**: 2 control plane + worker nodes, 1 worker node
- **Resources**: 4 CPU cores, 12GB RAM, 200GB storage per node
- **Network**: 10.11.12.241-243/24

### Database Cluster
- **PostgreSQL with Patroni**: High-availability setup
- **2 nodes**: 2 CPU cores, 4GB RAM, 40GB storage each
- **Network**: 10.11.12.245, 10.11.12.247/24

### Deployed Applications
- **Infrastructure**: Prometheus/Grafana, Ingress-NGINX, Cert-Manager, Longhorn, External-DNS
- **Applications**: HashiCorp Vault, Nextcloud, CouchDB, N8N, Vaultwarden, Lampac
- **Monitoring**: Kube-Prometheus-Stack with custom Proxmox monitoring

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
- **home_proxmox**: ArgoCD Application definitions (this repo)
- **home-proxmox-values**: Helm values, charts, and additional manifests

Applications are automatically synchronized via ArgoCD when changes are pushed to the values repository.

## Monitoring and Debugging

- **Prometheus/Grafana**: Available at configured ingress endpoints
- **ArgoCD UI**: Monitor application deployment status
- **Resource monitoring**: Use `scripts/k8s/k8s-top-pods-with-requests.sh`
- **Logs**: `kubectl logs` and ArgoCD application logs

## Contributing
Feel free to open issues or submit pull requests if you have any improvements or feature suggestions.

## License
This project is licensed under the MIT License.
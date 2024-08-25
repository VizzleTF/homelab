# [Proxmox Home Lab with Terraform and OKD Cluster](https://github.com/VizzleTF/home_proxmox)

This repository contains configurations and scripts to manage a Proxmox home lab environment using Terraform, and kubernetes clusters by kubespray. It includes Ansible roles, Helm charts, Terraform configurations, and Kubernetes manifests to fully automate the deployment and management of virtualized infrastructure.

## Project Structure

### 1. `ansible/`
This folder contains Ansible playbooks for automating tasks like configuring network, deploying services, and managing VM configurations in the Proxmox environment.

### 2. `helm/`
Helm charts are provided here for managing Kubernetes applications, allowing easy deployment of repeatable app environments within the OKD cluster.

### 3. `manifests/`
This directory contains Kubernetes manifest files, such as deployments, services, and configurations, for managing workloads in the OKD cluster. These YAML files define the desired state of the cluster applications.

### 4. `terraform_proxmox/`
This directory holds the core Terraform scripts for provisioning and managing virtual machines on Proxmox.

## Technologies Used
- **Proxmox VE**: A complete open-source server virtualization management solution.
- **Terraform**: Infrastructure as Code tool to define and provision the Proxmox environment.
- **Ansible**: Used for configuring VMs and automating tasks.
- **Helm**: Kubernetes package manager to streamline app deployment.

## Setup and Usage

### Prerequisites
- Install [Proxmox VE](https://www.proxmox.com/en/proxmox-ve)
- Install [Terraform](https://www.terraform.io/)
- Install [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/intro_installation.html)
- Install [Helm](https://helm.sh/docs/intro/install/)

### Instructions

1. **Clone the Repository:**
    ```bash
    git clone https://github.com/VizzleTF/home_proxmox.git
    cd home_proxmox
    ```

2. **Terraform Setup:**
   Navigate to the `terraform_proxmox/` directory and initialize the Terraform environment.
    ```bash
    terraform init
    terraform apply
    ```

3. **Manage Cluster with Kubernetes Manifests:**
   Use the manifests under `manifests/` to manage your OKD cluster resources.
    ```bash
    kubectl apply -f manifests/<resource_file>.yaml
    ```

## Contributing
Feel free to open issues or submit pull requests if you have any improvements or feature suggestions.

## License
This project is licensed under the MIT License.

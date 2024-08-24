#!/bin/zsh
sed -i'' -e '/10.11.12.241/d' ~/.ssh/known_hosts
ssh-keyscan 10.11.12.241 >> ~/.ssh/known_hosts
ssh-keyscan 10.11.12.242 >> ~/.ssh/known_hosts
ssh-keyscan 10.11.12.243 >> ~/.ssh/known_hosts
cd ../ansible
ansible-playbook playbooks/oracle_new_vm.yaml -i inventory/inventory.yaml
cd ../../kubespray
ansible-playbook -i ../home_proxmox/ansible/inventory/inventory.yaml  --become --become-user=root cluster.yml
scp root@10.11.12.241:~/.kube/config ~/.kube/config
sed -i'' -e "s^server:.*^server: https://10.11.12.241:6443^" ~/.kube/config
kubectl get nodes -o wide
cd ../helm
helmfile apply
kubectl apply -f ../manifests/metallb/pool.yaml
kubectl apply -f ../manifests/letsencrypt/ClusterIssuer.yaml
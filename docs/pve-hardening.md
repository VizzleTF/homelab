# Proxmox VE hosts hardening & observability

Runbook для Ansible-автоматизации харденинга PVE-хостов (`pve1`..`pve6`) и добавления
etcd/PVE мониторинга. По мотивам [smallab-k8s-pve-guide](https://github.com/ehlesp/smallab-k8s-pve-guide)
(G007-G014, G035), адаптировано под текущий кластер.

## Что и зачем

До сих пор PVE-хосты не были автоматизированы: без firewall на датацентре, без fail2ban,
без централизованного мониторинга состояния самих гипервизоров. Если нода pve упадёт или
будет скомпрометирована — узнаем случайно. Единственная компенсация сейчас — это замкнутая
домашняя сеть и ручная дисциплина.

Блок 2 этого плана закрывает host security (SSH-harden, fail2ban, sysctl, datacenter
firewall). Доступ к хостам — **только root по SSH-ключу**, ключ раскатан вне Ansible.
Блок 3 добавляет etcd-snapshot-бэкапы Talos и экспортёр метрик PVE в Victoria Metrics.

VM-level бэкапы (vzdump) **сознательно не делаем** — Longhorn 2-replica + Retain policy,
application-level backup CronJobs (NFS + WebDAV), и etcd snapshot — это полноценная DR-cover
для этой инсталляции.

## Состав ролей (Ansible)

| Роль | Что делает |
|------|-----------|
| `pve_ssh_harden` | `sshd_config.d/99-homelab.conf`: `AllowUsers root`, client alive, `MaxAuthTries 3`, `X11Forwarding no` |
| `pve_fail2ban` | `fail2ban` с jail'ами для `sshd` и `proxmox` (pveproxy) |
| `pve_sysctl` | Сетевой sysctl-хардненинг (rp_filter, syncookies, icmp_echo, kptr_restrict) |
| `pve_firewall` | Datacenter `cluster.fw`: default DROP, ACCEPT из 10.11.11.0/24 и 10.11.12.0/24 |

Порядок в `playbooks/pve_hosts.yaml`: **ssh_harden → sysctl → fail2ban → firewall**.
Firewall последним, чтобы в случае бага хотя бы остальные роли применились.

## Trusted CIDRs

Firewall пропускает входящий трафик **только** из:
- `10.11.11.0/24` — основная VLAN хостов и VM
- `10.11.12.0/24` — сеть сервисов (NFS `10.11.12.237`, DNS `10.11.12.1`)

Внутрикластерный трафик между нодами PVE разрешён по ICMP echo (heartbeat), остальное
ограничено tcp 22/8006/3128/5900-5999.

## Источники правды (IaC)

- `terraform_proxmox/configs/pve_hosts.yaml` — хосты, trusted_cidrs, firewall_manager_host.
  Из него модуль `modules/ansible_inventory` генерирует:
  - `ansible/inventory/inventory.yaml`
  - `ansible/inventory/group_vars/pve.yaml`
  - `../home-proxmox-values/values/infrastructure/pve-exporter.yaml` (`pveTargets`).
- `terraform_proxmox/modules/pve_rbac` создаёт:
  - `exporter@pve` в Proxmox + API-токен `!metrics` + ACL PVEAuditor на `/`
  - Vault-секрет `home/homelab/k8s/victoria-metrics/pve-exporter` через hashicorp/vault provider.

То есть `terraform apply` в `terraform_proxmox/` — единственный шаг для развёртывания
observability-части (после того как в Vault уже лежит policy-токен и корневой kv-mount `home`).

## Ручные шаги (один раз)

1. **Положить talosconfig в Vault** для etcd-backup CronJob:
   `vault kv put home/homelab/k8s/kube-system/talos-etcd-backup config=@~/.talos/config`.
   (Единственный секрет не управляемый терраформом — talosconfig содержит приватный CA,
   его не хочется хранить в Terraform state.)
2. ~~Создать каталог на NFS~~ — делается автоматически первым запуском CronJob'а, если
   NFS-монтирование разрешено. Если нет — создать вручную: смонтировать
   `10.11.12.237:/volume5/k8s_svc` с любого pve-узла и `mkdir etcd-backup`.

## Как применять

```bash
cd home_proxmox/ansible

# Dry-run на всех хостах (ничего не меняется)
ansible-playbook -i inventory playbooks/pve_hosts.yaml --check --diff

# Поэтапный apply: сначала pve6 (рабочая нода, наименее критична)
ansible-playbook -i inventory playbooks/pve_hosts.yaml --limit pve6

# Наблюдение 5-10 минут: pve-firewall status, ssh root@pve6, web UI на 8006
# Если всё ок — остальные ноды
ansible-playbook -i inventory playbooks/pve_hosts.yaml --limit '!pve6'
```

## Проверка после apply

```bash
# root-доступ по ключу работает
ssh root@pve1 -i ~/.ssh/id_ed25519     # ок

fail2ban-client status sshd            # active, 0 banned
pve-firewall status                    # enabled
pve-firewall compile                   # без ошибок

# sysctl применился
sysctl net.ipv4.tcp_syncookies         # = 1
sysctl kernel.kptr_restrict            # = 1

# Из 10.11.12.x: PVE UI доступна
nc -zv pve1 8006                       # succeeded
```

## etcd-snapshot бэкапы

CronJob `talos-etcd-backup` в `kube-system`, запускается ежедневно в 03:00 UTC:
1. `talosctl --nodes cp1,cp2,cp3 etcd snapshot /backup/etcd-YYYY-MM-DD.snapshot`
2. `rclone copy /backup 10.11.12.237:/volume5/k8s_svc/etcd-backup/`
3. Cleanup `find /backup -name '*.snapshot' -mtime +7 -delete`

Проверка: `kubectl -n kube-system get cronjob talos-etcd-backup`, затем
`kubectl -n kube-system create job --from=cronjob/talos-etcd-backup manual-test` →
должен завершиться успешно, файл появляется на NFS.

Ручной restore в DR-сценарии: `talosctl etcd recover --from /path/to/snapshot` +
`talosctl bootstrap` (см. Talos docs, не автоматизируем).

## PVE Exporter в Victoria Metrics

Deployment `prometheus-pve-exporter` в namespace `victoria-metrics`:
- авторизуется API-токеном `exporter@pve!metrics` из Vault (user/token/ACL и запись в Vault
  — всё создаётся модулем `terraform_proxmox/modules/pve_rbac`)
- скрейпится VMAgent'ом через `VMServiceScrape` (auto-convert из ServiceMonitor'а)
- Grafana dashboard ID 10347 ("Proxmox via Prometheus") импортируется как встроенный

Проверка: `curl http://pve-exporter:9221/pve?target=10.11.11.1` → метрики в prom-формате,
в Grafana видны графики CPU/RAM/disk per node.

## Rollback

- **Firewall**: `pvesh set /cluster/firewall/options -enable 0` на любой ноде (выключает
  datacenter firewall мгновенно)
- **SSH harden**: `rm /etc/ssh/sshd_config.d/99-homelab.conf && systemctl reload sshd`
- **fail2ban**: `systemctl disable --now fail2ban`
- **sysctl**: `rm /etc/sysctl.d/99-homelab-hardening.conf && sysctl --system`

Если ansible-запуск частично сломал хост, можно вручную подключиться через PVE UI (console
в браузере через 8006 на любой другой ноде — cluster share).

# Talos на terraform-provider-talos

Кластер Talos управляется декларативно через `siderolabs/talos` provider. HCL — единый
источник правды: правки `certSANs`, `extraHostEntries`, kubelet-args, install image и т.п.
раскатываются `terraform apply` на все ноды сразу.

История миграции с `talosctl gen config` + cloud-init snippet — в git log
(`git log --all -- home_proxmox/terraform_proxmox/modules/talos/`).

## Архитектура

### Модуль `terraform_proxmox/modules/talos/`

```
modules/talos/
├── provider.tf       # siderolabs/talos = 0.11.0-beta.2, hashicorp/time ~> 0.12
├── variables.tf      # cluster_name, cluster_endpoint, nodes map, versions, install image, vip, certSANs
├── secrets.tf        # talos_machine_secrets (импортирован из _out/secrets.yaml)
├── configs.tf        # data.talos_machine_configuration × 2 (cp + worker) с common/controlplane/node patches
├── apply.tf          # time_sleep(75s) + talos_machine_configuration_apply × N для managed-нод
├── bootstrap.tf      # talos_machine_bootstrap (импортирован no-op, prevent_destroy=true)
├── outputs.tf        # client_configuration + rescue machineconfigs
└── patches/
    ├── common.yaml.tftpl           # CNI=none, kube-proxy disabled, extraHostEntries, sysctls, kernel modules, features, install, kubelet extraMounts для Longhorn
    ├── controlplane.yaml.tftpl     # VIP, apiServer certSANs, PodSecurity admission, allowSchedulingOnControlPlanes
    └── node.yaml.tftpl             # hostname — multi-doc: machine.features.stableHostname=false + v1alpha1 HostnameConfig (v1.13 schema, см. Gotchas)
```

`modules/vms/` отвечает за Proxmox VM. Поле `talos_managed: true` на ноде говорит не
крепить cloud-init user-data — VM бутится в Talos maintenance. После boot'а
`time_sleep.wait_maintenance` даёт 75s слака (maintenance API отвечает обычно за
20–45s), затем `talos_machine_configuration_apply` с `apply_mode = "auto"`
раскатывает рендеренный конфиг — Talos сам решает: reboot для структурных изменений
(install image, kernel args, certSANs) или hot-reload для мелких правок.

Top-level `main.tf` собирает map нод для модуля из `configs/vms.yaml`, фильтр:
`vm.enabled && contains(vm.tags, "talos")`. Роль определяется префиксом имени:
`talos-cp-*` → controlplane, иначе worker.

### Параметры кластера

| Параметр | Значение |
|---|---|
| `cluster_name` | `talos-proxmox-cluster` |
| `cluster_endpoint` | `https://10.11.11.100:6443` (VIP, анонсируется CP-нодами) |
| `vip` | `10.11.11.100` (анонсируется CP-нодами через eth0) |
| `kubernetes_version` | `v1.36.0-beta.0` |
| `talos_version` (schema) | `v1.13` (соответствует install image) |
| `install_image` | `factory.talos.dev/nocloud-installer/<schematic>:v1.13.0-beta.1` |
| `apiserver_cert_sans` | `k8s.internal.example` + IP всех CP + VIP (автогенерация) |

Секреты: `talos_machine_secrets` + `talos_machine_bootstrap` — импортированы
одноразово из существующего кластера, хранятся в TF-state (бэкенд — S3 Yandex Cloud).

## Операции

### Добавить ноду

См. скилл `.claude/skills/new-talos-node/SKILL.md`. Коротко: запись в `vms.yaml` с
`talos_managed: true` → `terraform apply`. Провайдер создаёт VM, ждёт maintenance,
раскатывает machineconfig, ребутит. `extraHostEntries` и (для CP) `certSANs`
автоматически обновятся на всех существующих нодах через тот же apply.

Для CP — строго одна за раз, `terraform apply -parallelism=1` (etcd quorum 2/3 в
переходный момент + одновременный ребут kube-apiserver на 2 CP = недоступный API).

### Пересоздать ноду

Типичный сценарий: сменить install image / поменять hostpci / ресайз диска.

Предусловия (обязательные):

- etcd backup ≤ 24ч (скилл `victoria-metrics` → `talos-etcd-backup` CronJob)
- ArgoCD apps Healthy/Synced (скилл `argocd-status`)
- Нет firing алертов (скилл `alerts`)
- Для CP: **не лидер** (иначе `talosctl -n <ip> etcd forfeit-leadership` перед destroy)

```bash
# 1. Drain + eviction
kubectl cordon {node}
kubectl drain {node} --ignore-daemonsets --delete-emptydir-data --force

# Для worker с Longhorn данными — дождаться rebalance replicas на другие ноды
# (см. Gotchas → "Longhorn eviction стагнирует" если замирает)

# 2. Replace через TF — одной командой
cd home_proxmox/terraform_proxmox
terraform apply \
  -replace='module.vms.proxmox_virtual_environment_vm.vms["{node}"]' \
  -replace='module.talos.time_sleep.wait_maintenance["{node}"]' \
  -replace='module.talos.talos_machine_configuration_apply.this["{node}"]'

# 3. Для CP — дождаться 3 etcd member'ов без LEARNER
talosctl -n {ip} etcd members

# 4. Uncordon
kubectl uncordon {node}

# 5. Longhorn DiskFilesystemChanged (если worker) — см. Gotchas
```

`-replace` на `time_sleep` обязателен: без него 75s пауза не перезапустится и
`talos_machine_configuration_apply` попадёт в свежий `talos_machine_configuration_apply`
раньше, чем maintenance API откроется.

### Обновить extraHostEntries / certSANs

Никаких ручных правок не нужно. Изменения:

- **extraHostEntries**: автоматически — при правке нод в `vms.yaml` (add/remove).
- **apiServer certSANs**: `apiserver_cert_sans` переменная `modules/talos` (top-level
  `main.tf`, сейчас `["k8s.internal.example"]`). IP всех CP добавляются автоматически.
  После правки переменной — `terraform apply` применит к трём CP, каждый ребутнётся.

### Извлечь kubeconfig / talosconfig

```bash
# talosconfig для talosctl
terraform output -raw talos_client_configuration > ~/.talos/config

# kubeconfig — provider не отдаёт его как output, вытащить через talosctl
talosctl --talosconfig _out/talosconfig kubeconfig -n 10.11.11.101 -
```

## Troubleshooting / Gotchas

### TF apply падает с "no route to host :50000"

Провайдер `talos_machine_configuration_apply` коннектится к maintenance API сразу
после `time_sleep`. На медленно стартующих нодах (особенно при первом boot'е с qcow2
import через SSH) 75s не хватает. Ошибка:

```
rpc error: code = Unavailable desc = connection error: desc = "transport: Error while
dialing: dial tcp 10.11.11.XXX:50000: connect: no route to host"
```

VM создана, но apply не выполнен. **Rescue:**

```bash
# Определить роль ноды
terraform output -json talos_worker_machineconfig | jq -r '.' > /tmp/mc.yaml
# или talos_controlplane_machineconfig для CP

talosctl apply-config --insecure -e 10.11.11.XXX -n 10.11.11.XXX --file /tmp/mc.yaml
```

После join'а — `terraform apply` повторно; провайдер увидит ресурс применённым, drift
быть не должно (machineconfig байт-в-байт такой же).

### Longhorn eviction стагнирует из-за stale stopped replicas

После recreate ноды X на ней остаются "stopped" replica CRs (Longhorn их не чистит).
При миграции ноды Y с eviction Longhorn пытается rebuild replicas Y на X → stopped
replica CR блокирует создание нового → eviction зависает.

**Фикс — удалить stale stopped replicas перед eviction:**

```bash
kubectl -n longhorn-system get replicas.longhorn.io --no-headers \
  | awk '$3=="stopped" && $4=="{recently-recreated-node}" {print $1}' \
  | xargs -I{} kubectl -n longhorn-system delete replica.longhorn.io {}
```

Критерий безопасности "можно удалять stopped": volume соответствующего PVC `healthy`
и имеет ≥ 2 running replicas на других нодах.

### Longhorn DiskFilesystemChanged после recreate

После пересоздания VM `/var/lib/longhorn/` — свежая FS с новым UUID, а Longhorn
Node CR хранит старый UUID → `DiskFilesystemChanged` → диск `NotReady`,
`NotSchedulable` → replicas не шедулятся на ноду.

Восстановление (при условии, что replicas на этой ноде не было — они были мигрированы
до recreate):

```bash
# 1. Пометить на eviction, запретить scheduling
kubectl patch nodes.longhorn.io -n longhorn-system <node> --type merge \
  -p '{"spec":{"disks":{"default-disk-XXXX":{"allowScheduling":false,"evictionRequested":true,"path":"/var/lib/longhorn/","storageReserved":5150133452,"tags":[]}}}}'

# 2. Удалить spec-запись диска
kubectl patch nodes.longhorn.io -n longhorn-system <node> --type json \
  -p '[{"op":"remove","path":"/spec/disks/default-disk-XXXX"}]'

# 3. Стереть stale longhorn-disk.cfg внутри longhorn-manager pod'а ноды
kubectl -n longhorn-system exec $(kubectl -n longhorn-system get pod -l app=longhorn-manager \
  -o jsonpath='{.items[?(@.spec.nodeName=="<node>")].metadata.name}') -- rm -f /var/lib/longhorn/longhorn-disk.cfg

# 4. Добавить диск обратно — Longhorn переинициализирует с новым UUID
kubectl patch nodes.longhorn.io -n longhorn-system <node> --type merge \
  -p '{"spec":{"disks":{"default-disk-XXXX":{"allowScheduling":true,"path":"/var/lib/longhorn/","storageReserved":5150133452,"tags":[]}}}}'
```

Если replicas **были** на диске до recreate — сначала убедиться, что
`kubectl -n longhorn-system get replicas.longhorn.io | grep <node>` пуст, иначе потеря данных.

### bpg/proxmox — SSH для disk import

Провайдер импортирует qcow2 через SSH (`qm disk import`). Без `ssh.agent = true` в
provider block и загруженного ssh-agent падает на password auth с
`attempted methods [none]`. VM создаётся без диска.

В `provider.tf`:
```hcl
provider "proxmox" {
  ...
  ssh {
    agent    = true
    username = "root"
  }
}
```

Плюс `ssh-add ~/.ssh/id_rsa` в shell-сессии с `terraform apply`.

### API token не может ставить hostpci

Proxmox security: `hostpci` (GPU/PCI passthrough) требует `root@pam` password auth.
Токен (даже root-принадлежащий) получает `500: only root can set 'hostpci0' config
for non-mapped devices`.

Workarounds:
- `unset TF_VAR_proxmox_api_token` перед apply — провайдер упадёт на password auth
- Или завести PCI device mapping в Proxmox (`Datacenter → Resource Mappings`) и
  использовать `hostpci.mapping` вместо сырого `id`

### CNPG primary не переезжает только delete'ом pod'а

`kubectl delete pod <primary>` без cordon — CNPG пересоздаёт pod на той же ноде →
тот же primary. Чтобы сместить primary:

```bash
kubectl cordon <node>
kubectl delete pod <primary-pod> --force --grace-period=0
# 20–40s — новый primary переизбирается на другой ноде
```

`--force` потому что без него pod может застрять в `Terminating` 30+ сек на finalizers.

### HostnameConfig multi-doc patch для Talos v1.13

В schema v1.13 `machine.network.hostname` конфликтует с автоматическим
`machine.features.stableHostname = true` (дефолт): stableHostname генерит hostname
из machine ID, и одновременная явная установка ломает apply с ошибкой
`hostname: conflict between machine.network.hostname and stableHostname feature`.

Решение — multi-doc patch в `modules/talos/patches/node.yaml.tftpl`:

```yaml
machine:
  features:
    stableHostname: false
---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: ${hostname}
auto: "off"
```

Первый документ отключает автогенерацию, второй (`HostnameConfig` CRD — новый в v1.12+)
задаёт hostname явно. `auto: "off"` — важно: пустая строка или отсутствие поля даст
ошибку `AutoHostnameKind invalid value`.

### SA-token cascade после Talos secrets mutation

Любая мутация `talos_machine_secrets` (ротация CA, добавление
`aescbc_encryption_secret`, любая правка секретов) инвалидирует SA JWT-токены,
запечённые в уже запущенных pod'ах. Первым падает `cilium-agent`
(`dial tcp 10.96.0.1:443: i/o timeout`) → ClusterIP routing ломается → каскад
`Unauthorized` по кластеру (cilium-operator, CSI sidecars, cnpg, vault-autounseal,
cert-manager, NFD, …).

**Recovery recipe (~15 мин окно после apply на `talos_machine_secrets`):**

```bash
# 1. cilium data plane (главное — agents держат kube-proxy replacement)
kubectl rollout restart ds/cilium ds/cilium-envoy -n kube-system
kubectl rollout restart deploy/cilium-operator deploy/hubble-relay deploy/hubble-ui -n kube-system

# 2. Longhorn CSI sidecars
kubectl rollout restart deploy/csi-attacher deploy/csi-provisioner \
  deploy/csi-resizer deploy/csi-snapshotter -n longhorn-system

# 3. Node Feature Discovery
kubectl rollout restart ds/node-feature-discovery-worker -n node-feature-discovery
kubectl rollout restart deploy/node-feature-discovery-master \
  deploy/node-feature-discovery-gc -n node-feature-discovery

# 4. Force-delete оставшиеся CrashLoopBackOff/Error pod'ы — подхватят свежий projected token
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

# 5. Почистить orphan VolumeAttachments с deletionTimestamp (Longhorn их не чистит сам)
for va in $(kubectl get volumeattachment -o json \
  | jq -r '.items[] | select(.metadata.deletionTimestamp) | .metadata.name'); do
  kubectl patch volumeattachment $va --type=json \
    -p='[{"op":"remove","path":"/metadata/finalizers"}]'
done
```

**Почему:** projected SA token'ы лежат в `/var/run/secrets/kubernetes.io/serviceaccount/token`
pod'а — после ротации SA signing keys старые JWT не принимаются apiserver'ом, но в памяти
pod'а остаются до рестарта. Rolling restart форсит свежий TokenRequest через kubelet.

Память: `feedback_talos_secrets_sa_token_cascade.md`.

## Open questions (не в scope)

- **Talos OS upgrade через провайдер**: вне TF — см. issue
  [siderolabs/terraform-provider-talos#140](https://github.com/siderolabs/terraform-provider-talos/issues/140).
  Сейчас — руками через `talosctl upgrade`.
- **K8s upgrade**: `talosctl upgrade-k8s`, вне TF.
- **Секреты из state → Vault / ephemeral**: TF ≥ 1.11 + provider v0.11+ поддерживают
  `ephemeral` ресурсы; пока `talos_machine_secrets`/`talos_machine_bootstrap` в S3 state
  (Yandex Cloud) — приемлемо, но перевод уберёт секреты из state целиком.

# Tetragon — Runtime Security

eBPF-based process/file/network observability + TracingPolicy enforcement. DaemonSet на каждой ноде, namespace `tetragon`, sync-wave `-3`.

## Что даёт поверх Cilium

| Cilium/Hubble | Tetragon |
|---|---|
| Пакеты: кто с кем говорит | Процесс: кто инициировал соединение |
| L3/L4/L7 policy | Process/file/syscall policy (TracingPolicy) |
| NetworkPolicy enforcement | Sigkill/Override через eBPF (HIPS) |

## Архитектура

1. eBPF-программы в kernel через kprobes, tracepoints, LSM BPF (kernel 5.7+).
2. Ring buffer → user-space agent обогащает k8s-контекстом (pod, namespace, workload) по `PID→cgroup→podUID`.
3. Export: JSON в stdout sidecar (`export-stdout` container) + Prometheus metrics (port 2112).
4. TracingPolicy CRD → operator генерирует BPF-программы на лету.

## Фаза 1 (сейчас) — observation-only

- Базовые process exec/exit events в stdout
- Prometheus scrape через VMServiceScrape
- VMRule алерты в Telegram через существующий Alertmanager
- TracingPolicies: `suspicious-exec` (nc/nmap/socat/tcpdump/strace), `secrets-access` (чтение `/var/run/secrets/…`, `/etc/shadow`, `/root/.ssh/`)
- **Enforcement отключён** — только `Post` (лог + метрика), никаких `Sigkill`

## Что смотреть

```bash
# DaemonSet здоров
kubectl -n tetragon get ds tetragon

# События за последние 20 строк
kubectl -n tetragon logs ds/tetragon -c export-stdout --tail=20

# TracingPolicy статус
kubectl get tracingpolicies
kubectl -n tetragon exec ds/tetragon -c tetragon -- tetra tracingpolicy list

# Проверить метрики
kubectl -n tetragon port-forward ds/tetragon 2112:2112
curl -s localhost:2112/metrics | grep tetragon_events_total
```

## Тест алерта

```bash
# Запустить netcat в тестовом pod'е
kubectl run -it --rm test --image=alpine -- sh -c 'apk add --no-cache netcat-openbsd && nc -l 12345'
# В течение 5 минут должен прийти Telegram-алерт TetragonSuspiciousBinaryExec
```

## Ресурсный оверхед (homelab, 6 нод)

- Idle: ~150–250 MB RAM / 1–2% CPU на ноду (суммарно ~1 GB / ~0.6–1.2 vCPU)
- С TracingPolicy: +50–100 MB RAM / +1–2% CPU
- Event volume: ~10–50 events/s на кластер при baseline

## Фаза 2+ (отдельные задачи)

- **VictoriaLogs + Vector** — полный audit-trail JSON-событий (сейчас события только в `kubectl logs`, rotation через экспортер)
- **Enforcement mode** — Sigkill для явных lateral-movement tools после 1–2 недель обкатки
- **Namespace-scoped TracingPolicies** — разные правила для разных приложений (Immich vs infra)

## Файлы

| Файл | Что |
|---|---|
| `home_proxmox/argocd/infrastructure/infra-appset.yaml` | Entry в list generator |
| `home-proxmox-values/values/infrastructure/tetragon.yaml` | Helm values |
| `home-proxmox-values/manifests/infrastructure/tetragon/vmservicescrape.yaml` | Метрики для VMAgent |
| `home-proxmox-values/manifests/infrastructure/tetragon/tracingpolicy-suspicious-exec.yaml` | TracingPolicy |
| `home-proxmox-values/manifests/infrastructure/tetragon/tracingpolicy-secrets-access.yaml` | TracingPolicy |
| `home-proxmox-values/manifests/infrastructure/tetragon/vmrule.yaml` | Telegram алерты |

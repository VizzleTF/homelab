#!/usr/bin/env bash
# Self-check of the homelab-common workloads engine (charts/homelab-common):
# the schema rejects what it must, values win over chart defaults (0/false
# included), names/selectors/Service/Reloader/Recreate come out as documented.
# Runs in the CI helm-lint job and locally; needs helm and python3 with PyYAML,
# kubeconform optional.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1
C=charts/homelab-common
G=argocd/values/global.yaml
out_dir=$(mktemp -d); trap 'rm -rf "$out_dir"' EXIT
fail=0

tpl() { helm template t "$C" --namespace t -f "$G" -f - 2>&1; }
must_fail() {
  local msg=$1
  if tpl >/dev/null; then echo "FAIL (accepted): $msg"; fail=1
  else echo "ok   rejects: $msg"; fi
}

must_fail "typo contaners" <<'Y'
homelab-common: {workloads: [{name: a, contaners: [], containers: [{name: a, image: {repository: x, tag: "1"}}]}]}
Y
must_fail "image as a string" <<'Y'
homelab-common: {workloads: [{name: a, containers: [{name: a, image: "x:1"}]}]}
Y
must_fail "image object without tag" <<'Y'
homelab-common: {workloads: [{name: a, containers: [{name: a, image: {repository: x}}]}]}
Y
must_fail "statefulset is not a type" <<'Y'
homelab-common: {workloads: [{name: a, type: statefulset, containers: [{name: a, image: {repository: x, tag: "1"}}]}]}
Y
must_fail "cronjob without schedule" <<'Y'
homelab-common: {workloads: [{name: a, type: cronjob, containers: [{name: a, image: {repository: x, tag: "1"}}]}]}
Y
must_fail "schedule on a deployment" <<'Y'
homelab-common: {workloads: [{name: a, schedule: "* * * * *", containers: [{name: a, image: {repository: x, tag: "1"}}]}]}
Y
must_fail "claim not in persistentVolumeClaims" <<'Y'
homelab-common: {workloads: [{name: a, containers: [{name: a, image: {repository: x, tag: "1"}}], persistence: {d: {claim: nope, mountPath: /d}}}]}
Y
must_fail "containers inside pod" <<'Y'
homelab-common: {workloads: [{name: a, pod: {containers: []}, containers: [{name: a, image: {repository: x, tag: "1"}}]}]}
Y
must_fail "pvc without storageClassName" <<'Y'
homelab-common: {persistentVolumeClaims: [{name: d, accessModes: [ReadWriteOnce], size: 1Gi}]}
Y
must_fail "foreign vaultPath without grant" <<'Y'
homelab-common: {externalSecrets: [{name: a, vaultPath: other/x, data: [{secretKey: k, property: p}]}]}
Y
must_fail "three-segment vaultPath" <<'Y'
homelab-common: {externalSecrets: [{name: a, vaultPath: t/a/b, data: [{secretKey: k, property: p}]}]}
Y
must_fail "templateEngineVersion v1 (the ExternalSecret v1 CRD allows only v2)" <<'Y'
homelab-common: {externalSecrets: [{name: a, vaultPath: t/a, templateEngineVersion: v1, data: [{secretKey: k, property: p}]}]}
Y
must_fail "volsync repo paths without the backup grant" <<'Y'
homelab-common: {volsync: [{name: d, targets: [{repo: garage, schedule: "0 1 * * *"}]}]}
Y

# naming: exact or -<name> suffix collapses to the release, a substring does not
helm template openwrt-backup "$C" --namespace t -f "$G" -f - > "$out_dir/names.yaml" 2>&1 <<'Y' || { echo "FAIL: naming render"; cat "$out_dir/names.yaml"; exit 1; }
homelab-common:
  workloads:
    - {name: openwrt, containers: [{name: a, image: {repository: x, tag: "1"}}]}
    - {name: backup, containers: [{name: a, image: {repository: x, tag: "1"}}]}
  configMaps:
    - {name: openwrt-backup, data: {a: b}}
Y

# limitRange defaults: null = requests-only
tpl > "$out_dir/lr.yaml" <<'Y' || { echo "FAIL: limitRange render"; cat "$out_dir/lr.yaml"; exit 1; }
homelab-common: {limitRange: {enabled: true, defaults: null}}
Y

tpl > "$out_dir/render.yaml" <<'Y' || { echo "FAIL: reference render"; cat "$out_dir/render.yaml"; exit 1; }
global:
  openbao: {access: {namespaces: {t: [backup]}}}   # volsync reads shared/restic-* through the grant
homelab-common:
  externalSecrets:
    - {name: t-app, vaultPath: t/app, data: [{secretKey: k, property: p}]}
  persistentVolumeClaims:
    - {name: t-data, accessModes: [ReadWriteOnce], size: 1Gi, storageClassName: longhorn}
  workloads:
    - name: web                     # values win over defaults, also 0/false
      pod: {automountServiceAccountToken: true}
      spec: {revisionHistoryLimit: 0, strategy: {type: RollingUpdate}}
      reload: false
      containers:
        - name: web
          image: {repository: nginx, tag: "1.27"}
          ports: [{name: http, containerPort: 80}]
          envFrom: [{secretRef: {name: s}}]
          readinessProbe: {httpGet: {path: /, port: http}}
        - {name: side, image: {repository: busybox, tag: "1"}}
      persistence:
        data: {claim: t-data, mountPath: /data, containers: [side]}
    - name: api                     # defaults: Recreate on RWO, reloader, legacy selector
      legacySelector: {app: api}
      labels: {tier: backend}
      containers:
        - name: api
          image: {repository: ghcr.io/x/api, tag: "2.0"}
          env: [{name: P, valueFrom: {secretKeyRef: {name: api-secret, key: p}}}]
          ports: [{name: http, containerPort: 8080}]
      persistence:
        data: {claim: t-data, mountPath: /data}
        cfg: {configMap: {name: api-config}, mountPath: /etc/api}
    - name: job
      type: cronjob
      schedule: "0 1 * * *"
      job: {backoffLimit: 0}
      spec: {concurrencyPolicy: Allow, timeZone: UTC}
      containers: [{name: job, image: {repository: busybox, tag: "1"}}]
  configMaps:
    - {name: notify-script, data: {a: b}}
  secrets:
    - {name: repo, fullnameOverride: helm-oci, labels: {argocd.argoproj.io/secret-type: repository}, stringData: {type: helm}}
  volsync:
    - {name: t-data, targets: [{repo: garage, schedule: "0 1 * * *"}]}
    - {name: t-big, claim: t-data, drill: false, targets: [{repo: garage, schedule: "0 2 * * *"}]}
  limitRange: {enabled: true}
Y

python3 - "$out_dir/render.yaml" "$out_dir/lr.yaml" "$out_dir/names.yaml" <<'P' || fail=1
import sys, yaml
docs = {(d['kind'], d['metadata']['name']): d for d in yaml.safe_load_all(open(sys.argv[1])) if d}
names = {(d['kind'], d['metadata']['name']) for d in yaml.safe_load_all(open(sys.argv[3])) if d}
lr_only_req = next(d for d in yaml.safe_load_all(open(sys.argv[2])) if d and d['kind'] == 'LimitRange')['spec']['limits'][0]
web, api, cj = docs[('Deployment', 't-web')], docs[('Deployment', 't-api')], docs[('CronJob', 't-job')]
p, a = web['spec']['template']['spec'], api['spec']['template']['spec']
std = {'app.kubernetes.io/name': 't-web', 'app.kubernetes.io/instance': 't', 'app.kubernetes.io/managed-by': 'Helm'}
checks = {
  'user automountServiceAccountToken true kept': p['automountServiceAccountToken'] is True,
  'enableServiceLinks default false': p['enableServiceLinks'] is False,
  'user revisionHistoryLimit 0 kept': web['spec']['revisionHistoryLimit'] == 0,
  'user RollingUpdate beats RWO Recreate': web['spec']['strategy'] == {'type': 'RollingUpdate'},
  'reload false -> no reloader annotation': 'annotations' not in web['metadata'],
  'image object -> repo:tag': p['containers'][0]['image'] == 'nginx:1.27',
  'native probe passes through': p['containers'][0]['readinessProbe'] == {'httpGet': {'path': '/', 'port': 'http'}},
  'persistence only into listed container': 'volumeMounts' not in p['containers'][0] and p['containers'][1]['volumeMounts'][0]['mountPath'] == '/data',
  'auto selector name+instance': web['spec']['selector']['matchLabels'] == {'app.kubernetes.io/name': 't-web', 'app.kubernetes.io/instance': 't'},
  'standard labels on metadata': web['metadata']['labels'] == std,
  'workload labels on its Service': docs[('Service', 't-api')]['metadata']['labels'].get('tier') == 'backend' and api['metadata']['labels'].get('tier') == 'backend',
  'name substring of release does not collapse': {('Deployment', 'openwrt-backup-openwrt'), ('Deployment', 'openwrt-backup'), ('ConfigMap', 'openwrt-backup')} <= names,
  'service generated from ports': docs[('Service', 't-web')]['spec']['ports'] == [{'name': 'http', 'port': 80, 'targetPort': 'http'}],
  'legacy selector on Deployment and Service': api['spec']['selector']['matchLabels'] == {'app': 'api'} and docs[('Service', 't-api')]['spec']['selector'] == {'app': 'api'},
  'pod template carries legacy + standard labels': a and api['spec']['template']['metadata']['labels']['app'] == 'api' and api['spec']['template']['metadata']['labels']['app.kubernetes.io/name'] == 't-api',
  'RWO claim -> Recreate': api['spec']['strategy'] == {'type': 'Recreate'},
  'defaults automount false, revisionHistoryLimit 2': a['automountServiceAccountToken'] is False and api['spec']['revisionHistoryLimit'] == 2,
  'reloader from env secret and configMap volume': api['metadata']['annotations'] == {'secret.reloader.stakater.com/reload': 'api-secret', 'configmap.reloader.stakater.com/reload': 'api-config'},
  'reloader not on pod template': 'annotations' not in api['spec']['template']['metadata'],
  'cronjob job backoffLimit 0 kept': cj['spec']['jobTemplate']['spec']['backoffLimit'] == 0,
  'cronjob user Allow kept + defaults': cj['spec']['concurrencyPolicy'] == 'Allow' and cj['spec']['startingDeadlineSeconds'] == 600 and cj['spec']['timeZone'] == 'UTC',
  'cronjob history 1/3': cj['spec']['successfulJobsHistoryLimit'] == 1 and cj['spec']['failedJobsHistoryLimit'] == 3,
  'cronjob restartPolicy OnFailure': cj['spec']['jobTemplate']['spec']['template']['spec']['restartPolicy'] == 'OnFailure',
  'no reloader on cronjob': 'annotations' not in cj['metadata'],
  'configMap named like workloads': ('ConfigMap', 't-notify-script') in docs,
  'secret fullnameOverride + labels': docs[('Secret', 'helm-oci')]['metadata']['labels']['argocd.argoproj.io/secret-type'] == 'repository',
  'pvc storageClassName rendered': docs[('PersistentVolumeClaim', 't-data')]['spec']['storageClassName'] == 'longhorn',
  'own-namespace vaultPath under pathPrefix': docs[('ExternalSecret', 't-app')]['spec']['data'][0]['remoteRef']['key'] == 'homelab/k8s/t/app',
  'volsync drill label by default': docs[('ReplicationSource', 't-data-garage')]['metadata']['labels'].get('homelab.dr/drill') == 't-data',
  'volsync drill false -> no label': 'homelab.dr/drill' not in docs[('ReplicationSource', 't-big-garage')]['metadata']['labels'],
  'limitRange enabled -> 500m/512Mi, 50m/64Mi': docs[('LimitRange', 'default-limits')]['spec']['limits'][0] == {'type': 'Container', 'default': {'cpu': '500m', 'memory': '512Mi'}, 'defaultRequest': {'cpu': '50m', 'memory': '64Mi'}},
  'limitRange defaults null -> requests only': 'default' not in lr_only_req and lr_only_req['defaultRequest'] == {'cpu': '50m', 'memory': '64Mi'},
}
for k, v in checks.items():
    print(('ok   ' if v else 'FAIL ') + k)
sys.exit(0 if all(checks.values()) else 1)
P

if command -v kubeconform >/dev/null; then
  kubeconform -strict -summary -ignore-missing-schemas "$out_dir/render.yaml" || fail=1
fi
exit $fail

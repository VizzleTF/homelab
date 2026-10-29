# homelab-common

The one chart for everything this homelab writes itself: workloads without an
upstream chart, and the platform glue every application needs (secrets,
routes, volumes, backups, network policy). Every Argo CD Application renders it
as a second source next to its upstream chart, reading the `homelab-common:`
section of the same `values.yaml`.

## How it is consumed

```yaml
# argocd/apps/<app>/values.yaml
<upstream chart keys>     # only non-default values

homelab-common:           # read by this chart only
  networkPolicy:
    enabled: true
  externalSecrets: [...]
  httpRoutes: [...]
```

`argocd/values/global.yaml` is always the first value file: it carries
`global.*` (OpenBao, gateways, DNS domain, VolSync repositories). The chart has
no `global` defaults of its own.

## Keys

| Key | Renders |
|---|---|
| `workloads` | Deployment (default) or CronJob (`type: cronjob`), plus a Service from the containers' ports |
| `configMaps`, `secrets` | plain ConfigMaps and Secrets (secrets only for generated, non-sensitive objects) |
| `externalSecrets` | ExternalSecrets read from OpenBao through the release's own SecretStore (rendered automatically) |
| `httpRoutes`, `tlsRoutes` | Gateway API routes on the external, internal or both gateways; TLS passthrough |
| `certificates` | cert-manager Certificates |
| `persistentVolumeClaims` | PVCs, always with `helm.sh/resource-policy: keep`; `storageClassName` required |
| `volsync` | restic backups of a PVC to every repository in `global.volsync.repos`; `drill` (default true) labels the ReplicationSources `homelab.dr/drill=<name>` for the weekly restore drill, `false` for volumes larger than its `DRILL_SIZE` |
| `cnpgDatabases` | CloudNativePG `Database` CRs |
| `networkPolicy` | default-deny ingress CiliumNetworkPolicy `default-ingress` plus `allow` entries |
| `limitRange` | namespace LimitRange `default-limits`; `defaults: null` = requests-only (no default limits) |
| `rbac` | ServiceAccount + ClusterRole + ClusterRoleBinding sets |
| `authentikBlueprints` | Authentik blueprint ConfigMaps |

`values.yaml` has an example for every key; `values.schema.json` rejects
unknown keys and typos.

## OpenBao paths

Every `vaultPath` (and the VolSync repositories' `keyVaultPath` /
`passwordVaultPath`) is `<namespace>/<purpose>` under `global.vault.pathPrefix`;
the schema rejects any other shape. In SecretStore mode the render fails when a
path lies outside the release namespace and is not a grant of one of the groups
`global.openbao.access.namespaces` lists for it: add the grant in
`argocd/values/global.yaml` and run `scripts/openbao-eso-access.sh`, otherwise
ESO gets permission denied at runtime. Raw-manifest ExternalSecrets are not
checked.

## Workloads

Pod (`pod:`) and container bodies are native Kubernetes fields. The chart adds:

- names: `fullnameOverride`, else the release name when it equals `name` or
  ends with `-<name>`, else `<release>-<name>` (same rule for `configMaps` and `secrets`);
- labels `app.kubernetes.io/{name,instance,managed-by}` on every object, and
  the selector `app.kubernetes.io/{name,instance}` (`legacySelector` keeps the
  immutable selector of a Deployment created before 1.19);
- defaults: `revisionHistoryLimit: 2`, `automountServiceAccountToken: false`,
  `enableServiceLinks: false`, `strategy: Recreate` when a ReadWriteOnce claim
  is mounted; CronJob `concurrencyPolicy: Forbid`, `startingDeadlineSeconds:
  600`, history 1/3, `backoffLimit: 2`, `restartPolicy: OnFailure`;
- Reloader annotations for every Secret and ConfigMap the pod references
  (`reload: false` turns them off);
- shorthands: `image: {repository, tag}` and `persistence: {<volume>: {claim |
  <native volume source>, mountPath}}`, where `claim` must be a
  `persistentVolumeClaims` entry.

Values always win over the defaults, `0` and `false` included; `spec:`, `job:`
and `pod:` override the controller, JobSpec and PodSpec.

```yaml
homelab-common:
  persistentVolumeClaims:
    - name: myapp-data
      accessModes: [ReadWriteOnce]
      storageClassName: longhorn
      size: 5Gi
  workloads:
    - name: myapp
      containers:
        - name: myapp
          image:
            repository: ghcr.io/org/myapp
            tag: "1.2.3"
          ports:
            - name: http
              containerPort: 8080
          envFrom:
            - secretRef:
                name: myapp-app
      persistence:
        data: {claim: myapp-data, mountPath: /data}
```

## Development

- `scripts/homelab-common-selfcheck.sh` — schema rejections and engine behaviour;
- `scripts/chart-diff.sh` — what a change does to every consumer, against the
  published version;
- `scripts/kubeconform-validate.sh` — every consumer rendered and validated.

All three run in CI. A release is a `homelab-common-v<version>` tag matching
`Chart.yaml`; the publish workflow pushes the package to the Forgejo Helm
registry, and Renovate bumps the pin in the two ApplicationSets and the
standalone `argocd` Application.

A published version is immutable: any change under `charts/homelab-common`
needs a new `version` in `Chart.yaml`, and the helm-lint CI job fails when the
files differ from the registry package of the same version. The registry keeps
every version, so a rollback is the old pin in those three places.

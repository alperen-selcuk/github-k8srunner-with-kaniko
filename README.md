# github-k8srunner-with-kaniko

Self-hosted GitHub Actions runners for Kubernetes that register themselves with GitHub, build container images with **Kaniko** (no Docker daemon, no privileged pods) and deploy with **kubectl** / **helm** from inside the cluster.

The image is not tied to any repository. Which repo or organization a runner joins is decided entirely by a Kubernetes secret, so the same image serves any number of installs.

## Features

- **Kaniko** executor built from source from the maintained [Chainguard fork](https://github.com/chainguard-forks/kaniko) (the original GoogleContainerTools project was archived in June 2025)
- **kubectl** and **helm** included; they authenticate with the pod's ServiceAccount
- `git`, `jq`, `curl` preinstalled
- Repo-level or org-level runners, github.com or GitHub Enterprise Server
- Two registration modes: a one-time registration token with persistent state, or a PAT with ephemeral runners
- Multi-arch image (`linux/amd64`, `linux/arm64`)
- Graceful shutdown: the listener closes its GitHub session and ephemeral runners unregister themselves

## Repository layout

```
.
├── Dockerfile                  # runner image (actions-runner + kaniko + kubectl + helm)
├── start.sh                    # entrypoint: registers, runs and cleans up the runner
├── docker-config.json          # template for the kaniko registry credentials
├── kubernetes/                 # kustomize base
│   ├── rbac.yaml               #   ServiceAccount + namespace-scoped admin RoleBinding
│   ├── statefulset.yaml        #   RUNNER_TOKEN mode (persistent)
│   ├── deployment-ephemeral.yaml  # GITHUB_PAT mode (ephemeral)
│   └── secret-creater.sh       #   interactive helper that creates the secrets
└── environments/               # example overlays, one per install
    ├── example/                #   namespace-scoped runners
    └── example-cluster-admin/  #   runners with cluster-admin on a dedicated cluster
```

## Registration modes

| | `RUNNER_TOKEN` (registration token) | `GITHUB_PAT` (fine-grained PAT) |
|---|---|---|
| Where to get it | Repo → Settings → Actions → Runners → New self-hosted runner, the `--token` value | GitHub → Settings → Developer settings → Fine-grained tokens, permission **Administration: Read & write** |
| Valid for | **1 hour** | Lifetime of the PAT |
| Manifest | [kubernetes/statefulset.yaml](kubernetes/statefulset.yaml) | [kubernetes/deployment-ephemeral.yaml](kubernetes/deployment-ephemeral.yaml) |
| Behaviour | Each pod registers once and keeps its registration on its own PVC; restarts need no new token | Each pod fetches a fresh token on start, runs **ephemeral** (clean environment per job) and unregisters on shutdown |

Notes for `RUNNER_TOKEN` mode:

- The token is valid for one hour, so the **first registration** (first deploy, scaling up, deleting a PVC) must happen within that hour. If it has expired the pod fails; put a new token in place with `secret-creater.sh` and restart the pod.
- Later restarts reuse the registration stored on the PVC and need no token.
- When you scale down, the removed runner stays **Offline** on GitHub (removing it needs another token). GitHub cleans it up after 14 days, or delete it from the UI.
- `RUNNER_LABELS` is only applied on first registration. To change labels, delete the PVC and register again with a new token.
- Jobs share the same container, so pass `--cleanup` to Kaniko builds (see the workflow example below).

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `GITHUB_URL` | yes | `https://github.com/<owner>/<repo>`, or `https://github.com/<org>` for an org runner |
| `RUNNER_TOKEN` / `GITHUB_PAT` | one of them | See [Registration modes](#registration-modes) |
| `RUNNER_LABELS` | no | Comma-separated labels, e.g. `kaniko,helm` |
| `RUNNER_NAME_PREFIX` | no | Runner name becomes `<prefix>-<pod name>`; avoids name clashes when several clusters join the same repo |
| `RUNNER_NAME` | no | Overrides the runner name completely (single replica only) |
| `RUNNER_GROUP` | no | Runner group, org level only |
| `RUNNER_EPHEMERAL` | no | Defaults to `true` in PAT mode; ignored in `RUNNER_TOKEN` mode |

## Installation

### Prerequisites

- A Kubernetes cluster with a default StorageClass (for `RUNNER_TOKEN` mode)
- `kubectl` with kustomize support (v1.14+)
- `docker buildx` and a container registry for the runner image

### 1. Build and push the runner image

```bash
docker buildx build --platform linux/amd64 -t registry.example.com/github-runner:v0.1 --push .
```

Use `--platform linux/arm64` (or both, comma-separated) for arm64. The latest runner and kubectl releases are downloaded at build time; pin them with build args:

```bash
--build-arg RUNNER_VERSION=2.x.y \
--build-arg KUBECTL_VERSION=v1.x.y \
--build-arg KANIKO_VERSION=v1.x.y \
--build-arg HELM_VERSION=v3.x.y
```

### 2. Create the secrets

```bash
./kubernetes/secret-creater.sh
```

The script asks for `GITHUB_URL`, the token type (`token` / `pat`), the token itself, the namespace and, optionally, the path to a registry `config.json` for Kaniko (see the [template](docker-config.json)). It creates the namespace if needed. Running it again updates the secrets, which is also how you put a fresh one-hour token in place.

| Secret | Keys | Used for |
|---|---|---|
| `gh-runner` | `GITHUB_URL`, `RUNNER_TOKEN` or `GITHUB_PAT` | Runner registration |
| `registry-auth` (optional) | `config.json` | Kaniko push credentials, mounted at `/kaniko/.docker` |

### 3. Deploy

[kubernetes/](kubernetes/) is a kustomize base (`RUNNER_TOKEN` mode: `rbac.yaml` + `statefulset.yaml`). Each install is a small overlay under `environments/<name>/` that sets the namespace, image, labels and replica count.

```bash
cp -r environments/example environments/my-runners
# edit namespace, images, replicas and RUNNER_LABELS
kubectl apply -k environments/my-runners
```

Within a few minutes the runners show up as **Idle** under repo → Settings → Actions → Runners.

For PAT mode, use `deployment-ephemeral.yaml` instead of `statefulset.yaml` (change the `resources` list in [kubernetes/kustomization.yaml](kubernetes/kustomization.yaml)).

If the image lives in a private registry the cluster is not authorized for, create a docker-registry secret and add it as `imagePullSecrets` (see [environments/example-cluster-admin](environments/example-cluster-admin/kustomization.yaml)):

```bash
kubectl create secret docker-registry reg-cred -n <namespace> \
  --docker-server=registry.example.com --docker-username=<user> --docker-password=<password>
```

## Permissions

By default [rbac.yaml](kubernetes/rbac.yaml) grants the runner the built-in `admin` role **in its own namespace only** (Roles/RoleBindings included, nothing outside the namespace). To deploy elsewhere:

- add RoleBindings in the target namespaces, or
- on a dedicated cluster, replace it with a `cluster-admin` ClusterRoleBinding as shown in [environments/example-cluster-admin](environments/example-cluster-admin/).

## Multiple repositories or environments

Nothing is hard-coded. For another repo or cluster:

1. Copy an overlay under `environments/` and set `namespace`, `images`, `replicas` and `RUNNER_LABELS`.
2. Run `secret-creater.sh` for that namespace with the new repo URL and token.
3. `kubectl apply -k environments/<name>`

To attach several runner pools to the same repo for different purposes (e.g. `build` and `deploy-prod`), create multiple StatefulSets/Deployments with different names and labels.

## Using it in a workflow

```yaml
jobs:
  build:
    runs-on: [self-hosted, linux, kaniko]
    steps:
    - uses: actions/checkout@v4

    - name: Build & push with Kaniko
      run: |
        executor \
          --context "${GITHUB_WORKSPACE}" \
          --dockerfile "${GITHUB_WORKSPACE}/Dockerfile" \
          --destination registry.example.com/myapp:${GITHUB_SHA} \
          --cleanup

    - name: Deploy
      run: helm upgrade --install myapp ./chart -n myapp --set image.tag=${GITHUB_SHA}
```

Kaniko needs the `registry-auth` secret (`/kaniko/.docker/config.json`) to push.

## Security

Tokens are not exported to job steps, but jobs run as root inside the runner container. They can read everything in the container (including `/proc/1/environ`) and act with the pod's ServiceAccount. Only attach these runners to repositories you trust, and never use them for pull requests from forks of public repositories.

## Contributing

Issues and pull requests are welcome.

---

## Türkçe özet

Kubernetes üzerinde çalışan, GitHub'a kendini otomatik kaydeden self-hosted GitHub Actions runner. **Kaniko** ile Docker daemon ve privileged pod gerektirmeden image build/push eder, **kubectl** ve **helm** ile pod'un ServiceAccount'u üzerinden cluster'a deploy eder. Image hiçbir repo'ya bağlı değildir; hangi repo veya organizasyona bağlanacağı tamamen Kubernetes secret'ı ile belirlenir.

**İki çalışma modu**

- `RUNNER_TOKEN`: Repo → Settings → Actions → Runners ekranındaki 1 saatlik registration token. Her pod bir kez kayıt olur, kaydı kendi PVC'sinde saklar; restart'larda yeni token gerekmez. İlk kayıt token alındıktan sonraki 1 saat içinde yapılmalıdır.
- `GITHUB_PAT`: **Administration: Read & write** yetkili fine-grained PAT. Her pod açılışta kendi token'ını alır, ephemeral çalışır (her job temiz ortam) ve kapanırken kaydını siler.

**Hızlı kurulum**

```bash
# 1. Image'ı build edip push et
docker buildx build --platform linux/amd64 -t registry.example.com/github-runner:v0.1 --push .

# 2. Secret'ları oluştur (GITHUB_URL, token tipi, token, namespace, opsiyonel registry config.json)
./kubernetes/secret-creater.sh

# 3. Örnek overlay'i kopyala, namespace / image / replica / label değerlerini düzenle ve uygula
cp -r environments/example environments/my-runners
kubectl apply -k environments/my-runners
```

Birkaç dakika içinde runner'lar repo → Settings → Actions → Runners altında **Idle** olarak görünür. Workflow'da `runs-on: [self-hosted, linux, kaniko]` ile kullanılır.

**Yetkiler:** Varsayılan olarak runner sadece kendi namespace'inde `admin` yetkisine sahiptir. Tüm cluster'a deploy gerekiyorsa [environments/example-cluster-admin](environments/example-cluster-admin/) örneğine bakın.

**Güvenlik:** Job'lar container içinde root olarak çalışır ve pod'un ServiceAccount'una erişebilir. Bu runner'ları sadece güvendiğiniz repo'lara bağlayın; public repo'larda fork'lardan gelen PR'lar için kullanmayın.

Detaylar için yukarıdaki İngilizce bölümlere bakabilirsiniz.


---

## Table of Contents
1. [Architecture Overview](#architecture-overview)
2. [Prerequisites](#prerequisites)
3. [Files in This Directory](#files-in-this-directory)
4. [Step-by-Step Deployment](#step-by-step-deployment)
5. [Vault Plugin Setup](#vault-plugin-setup)
6. [HTTPRoute & gRPC Configuration](#httproute--grpc-configuration)
7. [Writing Vault-backed Secrets](#writing-vault-backed-secrets)
8. [Upgrade Notes](#upgrade-notes)
9. [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
                        ┌─────────────────────────────────────────────────┐
                        │                  Kubernetes Cluster              │
                        │                                                  │
  Browser / argocd CLI  │  ┌──────────────────────────────────────────┐   │
  ──────────────────►  HTTPRoute (Contour Gateway)                     │   │
                        │  ├─ HTTP/gRPC-web  → argocd-server:80        │   │
                        │  └─ native gRPC    → argocd-server:80 (h2c) │   │
                        │                                              │   │
                        │  argocd-server  (3 replicas + HPA)          │   │
                        │  argocd-repo-server (3 replicas + HPA)      │   │
                        │    └─ avp sidecar  ──────────────────────►  Vault│
                        │  argocd-app-controller  (3 replicas)        │   │
                        │  argocd-applicationset-controller (3)        │   │
                        │  argocd-dex  (2 replicas, LDAP auth)        │   │
                        │  argocd-redis  (HA sentinel, 3 replicas)    │   │
                        └─────────────────────────────────────────────────┘
```

**Vault Plugin flow:**
1. ArgoCD syncs an Application whose source path contains YAML with `<placeholder>` values
2. The `avp` sidecar in repo-server intercepts manifest generation
3. AVP authenticates to Vault using the `vault-auth` Kubernetes service account
4. AVP replaces each `<placeholder>` with the real value fetched from Vault KV
5. The resolved manifest is applied to the cluster

---

## Prerequisites

### 1. Secrets that must exist before `helm install`

**Redis password:**
```bash
kubectl create secret generic argocd-redis \
  --from-literal=redis-password='<password>' \
  -n argocd
```

**ArgoCD initial admin / LDAP bind credentials** (referenced in `argocd-cm`):
```bash
kubectl create secret generic argocd-secret \
  --from-literal=dex.ldap.bindDN='cn=svc-argocd,ou=...' \
  --from-literal=dex.ldap.bindPW='<password>' \
  -n argocd
```

**Vault plugin credentials** (see [`argocd-vault-plugin-credentials-fixed.yaml`](#argocd-vault-plugin-credentials-fixedyaml)):
```bash
kubectl apply -f argocd-vault-plugin-credentials-fixed.yaml
```

**Image pull secret** (must be named `regcred` in namespace `argocd`):
```bash
kubectl create secret docker-registry regcred \
  --docker-server=repo.ops.homelab.com \
  --docker-username=<user> \
  --docker-password=<token> \
  -n argocd
```

### 2. Service Account for Vault
The `vault-auth` service account is auto-created by a Kyverno policy when the `argocd`
namespace is created. Verify it exists:
```bash
kubectl get serviceaccount vault-auth -n argocd
```

### 3. Vault role `argocd` must allow `vault-auth` SA
The Vault admin must configure:
```bash
vault write auth/homelab/role/argocd \
  bound_service_account_names=vault-auth \
  bound_service_account_namespaces=argocd \
  policies=argocd-read \
  ttl=1h
```

---

## Files in This Directory

| File | Purpose |
|------|---------|
| `Chart.yaml` | Bitnami chart metadata (pinned to v15.2.15 / ArgoCD 3.3.6) |
| `values.yaml` | Full Bitnami chart defaults — **do not edit** |
| `values-override-global.yaml` | Shared: HA sizing, accounts config, HTTPRoute structure — **no cluster-specific values** |
| `values-override-cluster.yaml` | **Cluster-specific**: hostname, gateway refs, LDAP IP, storage class, image registry |
| `values-override-vault-plugin.yaml` | Vault plugin (AVP) sidecar setup — uses `global.imageRegistry` from cluster file |
| `values-override-explicit-images.yaml` | Pin all image registries to internal mirror |
| `argocd-vault-plugin-credentials-fixed.yaml` | AVP credentials for sv4d-rndsandbox-nonp |
| `argocd-vault-plugin-credentials-template.yaml` | **Template** for creating per-cluster AVP credentials |

### Multi-Cluster Pattern

To deploy on a new cluster:
1. Copy `values-override-cluster.yaml` → `values-override-cluster-<newcluster>.yaml`
2. Update all values in the new cluster file (hostname, gateway, LDAP IP, storage class, image registry)
3. Copy `argocd-vault-plugin-credentials-template.yaml` → `argocd-vault-plugin-credentials-<newcluster>.yaml`
4. Set `AVP_K8S_MOUNT_PATH` to `auth/<vault-env>/<cluster-name>` (base64-encoded)
5. Deploy using the commands below

---

## Step-by-Step Deployment

### Install / Upgrade
```bash
# Apply AVP credentials first (must exist before helm install)
kubectl apply -f argocd-vault-plugin-credentials-<cluster>.yaml -n argocd

helm upgrade --install argocd . \
  -n argocd --create-namespace \
  -f values-override-explicit-images.yaml \
  -f values-override-global.yaml \
  -f values-override-vault-plugin.yaml \
  -f values-override-cluster.yaml \
  --timeout 10m
```

> **Order matters:** later files override earlier ones. `values-override-cluster.yaml` must be last.

### Verify rollout
```bash
kubectl get pods -n argocd
kubectl rollout status deployment/argocd-argo-cd-repo-server -n argocd
kubectl rollout status deployment/argocd-argo-cd-server -n argocd
```

### Login
```bash
# Get initial admin password
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d

# CLI login (native gRPC — requires port 443 h2c routing to be working)
argocd login argocd-demo.homelab.com

# CLI login fallback (grpc-web over HTTP)
argocd login argocd-demo.homelab.com --grpc-web --port-forward-namespace argocd
```

---

## Vault Plugin Setup

### How it works

The ArgoCD Vault Plugin (AVP) runs as a **Config Management Plugin (CMP) sidecar** inside
each `repo-server` pod. It replaces `<placeholder>` values in YAML manifests with real
secrets fetched from HashiCorp Vault at sync time.

### Key components

#### 1. Plugin ConfigMap (`argocd-vault-plugin-cmp`)
Created via `extraDeploy` in `values-override-vault-plugin.yaml`.
```yaml
# plugin.yaml — loaded by the avp sidecar at startup
apiVersion: argoproj.io/v1alpha1
kind: ConfigManagementPlugin
metadata:
  name: argocd-vault-plugin
spec:
  allowConcurrency: true
  # No 'discover' block — plugin is selected explicitly per Application
  generate:
    command: [argocd-vault-plugin, generate, ./]
  lockRepo: false
```
> ⚠️ **Do not add a `discover:` block.** Even when `plugin.name` is set explicitly in an
> Application, ArgoCD v3.x evaluates the discover rule. Without it the plugin accepts all
> explicitly-named requests.

#### 2. Init containers in repo-server

| Container | What it does |
|-----------|-------------|
| `download-tools` | Downloads `argocd-vault-plugin` v1.18.0 binary into the `custom-tools` emptyDir |
| `copyutil` | Copies the Bitnami argocd binary (`/opt/bitnami/argo-cd/bin/argocd`) to `/var/run/argocd/argocd` and symlinks it as `argocd-cmp-server` |

#### 3. AVP sidecar container
```
image:    same as repo-server (Bitnami argo-cd)
command:  /var/run/argocd/argocd-cmp-server   ← the symlink from copyutil
runAsUser: 1001                                ← MUST match repo-server uid
envFrom:  argocd-vault-plugin-credentials
```

> ⚠️ **`runAsUser: 1001` is critical.** The CMP socket at
> `/home/argocd/cmp-server/plugins/argocd-vault-plugin.sock` is created by the sidecar.
> The repo-server main container (uid=1001) needs **write** permission on the socket to
> connect. Running the sidecar as uid=999 creates a socket owned by 999 with group
> permissions `r-x` only → `permission denied` on connect.

#### 4. AVP credentials secret

```yaml
# argocd-vault-plugin-credentials-fixed.yaml (values are base64-encoded)
AVP_TYPE:            vault
AVP_AUTH_TYPE:       k8s
AVP_K8S_MOUNT_PATH:  auth/homelab   # ← includes 'auth/' prefix!
AVP_K8S_ROLE:        argocd
VAULT_ADDR:          https://vault.homelab.com
```

> ⚠️ **`AVP_K8S_MOUNT_PATH` must include the `auth/` prefix.**
> The vault-sdk `WithMountPath()` uses the value as-is to build the login URL:
> `PUT $VAULT_ADDR/v1/$AVP_K8S_MOUNT_PATH/login`
> Without `auth/` it hits the KV engine endpoint → **403 permission denied**.

### Service Account

The repo-server uses the existing `vault-auth` SA (created by Kyverno):
```yaml
# values-override-vault-plugin.yaml
repoServer:
  automountServiceAccountToken: true
  serviceAccount:
    create: false
    name: vault-auth
```

### Volume layout

```
/var/run/argocd/
  argocd              ← binary copied by copyutil
  argocd-cmp-server   ← symlink → ./argocd

/home/argocd/cmp-server/
  plugins/
    argocd-vault-plugin.sock   ← Unix socket (uid=1001, perms rwxr-xr-x)
  config/
    plugin.yaml                ← mounted from ConfigMap

/usr/local/bin/argocd-vault-plugin  ← binary downloaded by download-tools
/tmp/                               ← writable tmpdir for AVP
```

---

## HTTPRoute & gRPC Configuration

The ArgoCD server runs in `--insecure` mode (no TLS termination) behind a Contour
Gateway API HTTPRoute.

### Why two routing rules are needed

| Traffic type | Header | Backend port |
|---|---|---|
| Browser UI + grpc-web | `Content-Type: application/grpc-web*` or anything else | **80** (HTTP/1.1) |
| Native gRPC (argocd CLI) | `Content-Type: application/grpc` (exact type, no `-web` suffix) | **443** (h2c cleartext HTTP/2) |

```yaml
# values-override-global.yaml  (relevant excerpt)
server:
  insecure: true
  httpRoute:
    enabled: true
    parentRefs:
      - group: gateway.networking.k8s.io
        kind: Gateway
        name: contour
        namespace: tanzu-system-ingress
        sectionName: https
    hostnames:
      - argocd-demo.homelab.com
    matches:
      - path: {type: PathPrefix, value: /}     # default → port 80
    extraRules:
      - backendRefs:
          - name: argocd-argo-cd-server
            port: 443
        matches:
          - path: {type: PathPrefix, value: /}
            headers:
              - name: Content-Type
                type: RegularExpression
                value: ^application/grpc($|\+.*|;.*)  # native gRPC only
  service:
    annotations:
      projectcontour.io/upstream-protocol.h2c: "443"  # tell Contour to use h2c upstream
```

> The regex `^application/grpc($|\+.*|;.*)` matches `application/grpc` but **not**
> `application/grpc-web+proto`, ensuring browser traffic isn't routed to the h2c backend.

---

## Writing Vault-backed Secrets

### Application must declare the plugin
```yaml
# ArgoCD Application spec
spec:
  source:
    repoURL: https://git.homelab.com/scm/ho/lb-cluster.git
    path: secrets/
    targetRevision: default
    plugin:
      name: argocd-vault-plugin   # ← required
```

### Secret manifest template (in Git)
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  namespace: my-namespace
  annotations:
    # KV v2 path: <mount>/data/<path>
    avp.kubernetes.io/path: "platform/infrastructure/homelab/data/<team>/<secret-name>"
type: Opaque
stringData:
  username: <username>       # placeholder = Vault key name
  password: <password>
```

### Docker registry secret template
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: regcred
  annotations:
    avp.kubernetes.io/path: "platform/infrastructure/homelab/data/argocd/regcred"
type: kubernetes.io/dockerconfigjson
stringData:
  .dockerconfigjson: <dockerconfigjson>
```

> ⚠️ **The Vault value for `.dockerconfigjson` must be compact single-line JSON.**
> Multi-line (pretty-printed) JSON breaks YAML parsing when AVP substitutes the value.
> Store it as: `{"auths":{"registry.example.com":{"auth":"<base64>"}}}` (no newlines).

### Vault KV path reference

| Secret | Vault path |
|--------|-----------|
| argocd/database | `platform/infrastructure/homelab/data/argocd/database` |
| argocd/regcred | `platform/infrastructure/homelab/data/argocd/regcred` |
| argocd/wordpress-credential | `platform/infrastructure/homelab/data/argocd/wordpress-credential` |

---



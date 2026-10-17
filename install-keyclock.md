# Install Keycloak on the Home Lab Kubernetes Cluster

This guide installs **Keycloak** (open-source identity and access management / SSO) on the home lab Kubernetes cluster using the official **Keycloak Operator**, backed by a **PostgreSQL** database and exposed through an **Ingress** with TLS.

> Why the Operator and not a Helm chart? The Operator is the install method maintained by the Keycloak project itself. The popular Bitnami Helm chart moved its images behind a paid/legacy registry in 2025, so it is no longer a good fit for a free home lab.

---

## 1. What You Will Build

```
            Browser (https://keycloak.homelab.local)
                          │
                 ┌────────▼────────┐
                 │  Ingress (nginx) │
                 └────────┬────────┘
                          │ HTTPS
   namespace: keycloak    │
   ┌──────────────────────▼──────────────────────┐
   │  Keycloak pod(s)  ◄── managed by ── Keycloak Operator
   │        │                                     │
   │        ▼                                     │
   │  PostgreSQL StatefulSet + PersistentVolume   │
   └─────────────────────────────────────────────┘
```

| Component         | Purpose                                         |
|-------------------|-------------------------------------------------|
| Keycloak Operator | Installs, upgrades and configures Keycloak      |
| Keycloak          | The SSO / identity server                       |
| PostgreSQL        | Stores realms, users, clients and sessions      |
| Ingress + TLS     | Makes Keycloak reachable from your network      |

---

## 2. Prerequisites

Run these checks from the machine where you use `kubectl` (for example your WSL terminal or the control-plane VM).

| Requirement | How to check | Notes |
|---|---|---|
| A running cluster (1.27+) | `kubectl get nodes` | All nodes should be `Ready` |
| `kubectl` configured | `kubectl version` | Client and server versions shown |
| A default StorageClass | `kubectl get storageclass` | One entry must say `(default)` — see 2.1 |
| An Ingress controller | `kubectl get pods -A \| grep -i ingress` | This guide uses ingress-nginx — see 2.2 |
| `openssl` | `openssl version` | Used to make a self-signed certificate |
| Resources | — | At least ~2 GB RAM and 1 CPU free for Keycloak + Postgres |

### 2.1 No default StorageClass? Install local-path-provisioner

Most home lab clusters built with kubeadm have no storage. The Rancher local-path provisioner is the simplest option:

```bash
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml

kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

kubectl get storageclass
```

> k3s already ships with `local-path` as the default — skip this step on k3s.

### 2.2 No Ingress controller? Install ingress-nginx

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.3/deploy/static/provider/baremetal/deploy.yaml

kubectl -n ingress-nginx get svc ingress-nginx-controller
```

On bare metal / VirtualBox the service is a `NodePort`. Note the HTTPS port (e.g. `443:3xxxx/TCP`) — you will browse to `https://keycloak.homelab.local:3xxxx`.
If you run **MetalLB**, change the service type to `LoadBalancer` to get a normal port 443.

> **k3s users:** k3s ships with Traefik instead of nginx. Either disable Traefik and install ingress-nginx, or set `className: traefik` in step 6 and skip the nginx-specific notes.

---

## 3. Set Variables

Pick a Keycloak version (check the latest at <https://www.keycloak.org/downloads>) and a hostname for your lab.

```bash
export KC_VERSION=26.4.0
export KC_NAMESPACE=keycloak
export KC_HOST=keycloak.homelab.local
```

Create the namespace:

```bash
kubectl create namespace $KC_NAMESPACE
```

---

## 4. Install the Keycloak Operator

The Operator is installed from the official `keycloak-k8s-resources` repository: first the CRDs, then the operator deployment.

```bash
# Custom Resource Definitions
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$KC_VERSION/kubernetes/keycloaks.k8s.keycloak.org-v1.yml
kubectl apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$KC_VERSION/kubernetes/keycloakrealmimports.k8s.keycloak.org-v1.yml

# Operator deployment (watches the namespace it is installed into)
kubectl -n $KC_NAMESPACE apply -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$KC_VERSION/kubernetes/kubernetes.yml
```

Verify:

```bash
kubectl -n $KC_NAMESPACE get pods
# NAME                                 READY   STATUS    RESTARTS   AGE
# keycloak-operator-xxxxxxxxxx-xxxxx   1/1     Running   0          30s
```

---

## 5. Deploy PostgreSQL

### 5.1 Create the database credentials

```bash
kubectl -n $KC_NAMESPACE create secret generic keycloak-db-secret \
  --from-literal=username=keycloak \
  --from-literal=password="$(openssl rand -base64 18)"
```

### 5.2 Create the Postgres StatefulSet and Service

Save as `keycloak-postgres.yaml`:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgresql-db
  namespace: keycloak
spec:
  serviceName: postgresql-db
  replicas: 1
  selector:
    matchLabels:
      app: postgresql-db
  template:
    metadata:
      labels:
        app: postgresql-db
    spec:
      containers:
        - name: postgresql-db
          image: postgres:16
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: keycloak
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: keycloak-db-secret
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-db-secret
                  key: password
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d keycloak"]
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 100m
              memory: 256Mi
            limits:
              memory: 512Mi
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 5Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-db
  namespace: keycloak
spec:
  selector:
    app: postgresql-db
  ports:
    - port: 5432
      targetPort: 5432
```

Apply and wait for it to be ready:

```bash
kubectl apply -f keycloak-postgres.yaml
kubectl -n $KC_NAMESPACE rollout status statefulset/postgresql-db
kubectl -n $KC_NAMESPACE get pvc
# data-postgresql-db-0   Bound   ...   5Gi   RWO   local-path
```

> If the PVC stays `Pending`, you have no default StorageClass — go back to step 2.1.

---

## 6. Deploy Keycloak

### 6.1 Create a TLS certificate

For a home lab, a self-signed certificate is enough (your browser will show a warning you can accept).

```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout keycloak.key -out keycloak.crt \
  -subj "/CN=$KC_HOST" \
  -addext "subjectAltName=DNS:$KC_HOST"

kubectl -n $KC_NAMESPACE create secret tls keycloak-tls \
  --cert=keycloak.crt --key=keycloak.key
```

> Already running **cert-manager**? Create a `Certificate` that writes to a secret named `keycloak-tls` instead and skip the openssl step.

### 6.2 Create the Keycloak custom resource

Save as `keycloak.yaml` (replace the hostname if you changed `KC_HOST`):

```yaml
apiVersion: k8s.keycloak.org/v2alpha1
kind: Keycloak
metadata:
  name: keycloak
  namespace: keycloak
spec:
  instances: 1
  db:
    vendor: postgres
    host: postgres-db
    port: 5432
    database: keycloak
    usernameSecret:
      name: keycloak-db-secret
      key: username
    passwordSecret:
      name: keycloak-db-secret
      key: password
  http:
    tlsSecret: keycloak-tls
  hostname:
    hostname: keycloak.homelab.local
  proxy:
    headers: xforwarded
  ingress:
    enabled: true
    className: nginx
  resources:
    requests:
      cpu: 250m
      memory: 768Mi
    limits:
      memory: 1536Mi
```

Apply and watch it start (the first start takes 1–3 minutes):

```bash
kubectl apply -f keycloak.yaml
kubectl -n $KC_NAMESPACE get keycloak keycloak -w
kubectl -n $KC_NAMESPACE get pods,svc,ingress
```

Expected result:

```
pod/keycloak-0                           1/1   Running
pod/keycloak-operator-xxxxxxxxxx-xxxxx   1/1   Running
pod/postgresql-db-0                      1/1   Running

service/keycloak-service   ClusterIP   ...   8443/TCP,9000/TCP
service/postgres-db        ClusterIP   ...   5432/TCP

ingress.networking.k8s.io/keycloak-ingress   nginx   keycloak.homelab.local
```

---

## 7. Reach Keycloak from Your Browser

### 7.1 Add a DNS / hosts entry

Point `keycloak.homelab.local` at the IP of a node (NodePort) or the MetalLB LoadBalancer IP.

- **Windows:** edit `C:\Windows\System32\drivers\etc\hosts` as Administrator
- **Linux / WSL / macOS:** edit `/etc/hosts`

```
192.168.56.10   keycloak.homelab.local
```

(Or add the record to Pi-hole / your router DNS if you run one.)

### 7.2 Get the initial admin password

The Operator generates a temporary admin user:

```bash
kubectl -n $KC_NAMESPACE get secret keycloak-initial-admin \
  -o jsonpath='{.data.username}' | base64 -d; echo
kubectl -n $KC_NAMESPACE get secret keycloak-initial-admin \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

### 7.3 Log in

Open `https://keycloak.homelab.local` (add `:<NodePort>` if you are not using a LoadBalancer), accept the self-signed certificate warning, and click **Administration Console**.

**Quick check without Ingress/DNS** (useful for troubleshooting):

```bash
kubectl -n $KC_NAMESPACE port-forward svc/keycloak-service 8443:8443
# then browse to https://localhost:8443
```

---

## 8. Post-Install Tasks

1. **Replace the temporary admin.** In the `master` realm go to **Users → Add user**, create your own admin, set a password, and under **Role mapping** assign the `admin` role. Log in as the new user, then delete the `temp-admin` user.
2. **Create a realm for your lab apps.** Never use `master` for applications. Top-left realm dropdown → **Create realm** → e.g. `homelab`.
3. **Create a test user** in the `homelab` realm and log in at `https://keycloak.homelab.local/realms/homelab/account` to confirm it works.
4. **Create an OIDC client** for an app (Grafana, Argo CD, Kubernetes dashboard, etc.): **Clients → Create client**, type *OpenID Connect*, enable *Client authentication*, and set the app's redirect URI. The issuer URL for apps is:
   ```
   https://keycloak.homelab.local/realms/homelab
   ```

---

## 9. Day-2 Operations

| Task | Command / action |
|---|---|
| Check status | `kubectl -n keycloak get keycloak keycloak -o yaml` (see `status.conditions`) |
| View logs | `kubectl -n keycloak logs keycloak-0 -f` |
| Operator logs | `kubectl -n keycloak logs deploy/keycloak-operator -f` |
| Scale up | set `spec.instances: 2` in `keycloak.yaml` and re-apply |
| Back up the DB | `kubectl -n keycloak exec postgresql-db-0 -- pg_dump -U keycloak keycloak > keycloak-backup.sql` |
| Restore the DB | `kubectl -n keycloak exec -i postgresql-db-0 -- psql -U keycloak keycloak < keycloak-backup.sql` |
| Upgrade | re-run step 4 with the new `KC_VERSION` — the Operator rolls Keycloak to the matching version. **Back up the DB first.** |

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `postgresql-db-0` stuck `Pending` | No default StorageClass | Step 2.1 |
| `keycloak-0` in `CrashLoopBackOff`, logs mention DB connection | Postgres not ready or wrong secret | `kubectl -n keycloak get pods`; check `keycloak-db-secret` keys are `username` / `password` |
| `keycloak-0` `OOMKilled` | Memory limit too low | Raise `resources.limits.memory` to 2Gi |
| Browser shows **404** from nginx | Hostname mismatch | Make sure the URL hostname exactly matches `spec.hostname.hostname` |
| Browser shows **502 / 503** | Keycloak still starting, or backend protocol wrong | Wait for `keycloak-0` Ready; `kubectl -n keycloak describe ingress keycloak-ingress` should show `backend-protocol: HTTPS` |
| Login page loops / "HTTPS required" | Proxy headers not passed | Keep `proxy.headers: xforwarded` and access via `https://` |
| Redirects go to the wrong port | Using NodePort | Use MetalLB/LoadBalancer on 443, or set `spec.hostname.hostname` to the full URL including port, e.g. `https://keycloak.homelab.local:30443` |

---

## 11. Uninstall

```bash
kubectl delete -f keycloak.yaml
kubectl delete -f keycloak-postgres.yaml
kubectl -n keycloak delete -f https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$KC_VERSION/kubernetes/kubernetes.yml
kubectl delete namespace keycloak          # also removes the PVC and all data
kubectl delete crd keycloaks.k8s.keycloak.org keycloakrealmimports.k8s.keycloak.org
```

---

## References

- Keycloak Operator installation: <https://www.keycloak.org/operator/installation>
- Keycloak Operator basic deployment: <https://www.keycloak.org/operator/basic-deployment>
- Keycloak server configuration: <https://www.keycloak.org/server/all-config>

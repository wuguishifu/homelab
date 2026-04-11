# Bootstrap

Everything in this repo is managed by ArgoCD via GitOps. These are the one-time manual steps to get the cluster running from scratch.

## 1. Install k3s

```sh
curl -sfL https://get.k3s.io | sh -
```

## 2. Set up kubeconfig

**On the server:**

```sh
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

# Verify the node is ready
kubectl get nodes
```

**On your Mac (remote access via Tailscale):**

```sh
# Copy the kubeconfig from the server
scp user@<tailscale-ip>:~/.kube/config ~/.kube/config-homelab

# Replace the loopback address with the server's Tailscale IP
sed -i '' 's/127.0.0.1/<tailscale-ip>/g' ~/.kube/config-homelab

export KUBECONFIG=~/.kube/config-homelab
kubectl get nodes
```

## 3. Install ArgoCD

```sh
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=120s
```

## 4. Create bootstrap secrets

These are the only secrets ever created manually. Everything else will be managed by Infisical after it is running.

### Cloudflare API token (for cert-manager)

In the Cloudflare dashboard go to **My Profile → API Tokens → Create Token** with these permissions:

- `Zone > Zone > Read` — All zones (or specific: `wuguishifu.dev`)
- `Zone > DNS > Edit` — Specific zone: `wuguishifu.dev`

```sh
kubectl create namespace cert-manager

kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token=<YOUR_TOKEN_HERE>
```

> This secret is temporary. Once Infisical is running it will be replaced by the `InfisicalSecret` in `manifests/infisical-secrets/cloudflare.yaml`.

### Infisical bootstrap credentials

```sh
kubectl create namespace infisical

POSTGRES_PASS=$(openssl rand -base64 24 | tr -d '=+/')
POSTGRES_ADMIN_PASS=$(openssl rand -base64 24 | tr -d '=+/')
REDIS_PASS=$(openssl rand -base64 24 | tr -d '=+/')

kubectl create secret generic infisical-secrets \
  --namespace infisical \
  --from-literal=ENCRYPTION_KEY=$(openssl rand -hex 16) \
  --from-literal=AUTH_SECRET=$(openssl rand -base64 32) \
  --from-literal=DB_CONNECTION_URI="postgresql://infisical:${POSTGRES_PASS}@postgresql:5432/infisicalDB" \
  --from-literal=REDIS_URL="redis://:${REDIS_PASS}@redis-master:6379/0" \
  --from-literal=SITE_URL="https://infisical.wuguishifu.dev" \
  --from-literal=POSTGRES_PASSWORD="${POSTGRES_PASS}" \
  --from-literal=POSTGRES_ADMIN_PASSWORD="${POSTGRES_ADMIN_PASS}" \
  --from-literal=REDIS_PASSWORD="${REDIS_PASS}"
```

> Save the generated values in a password manager. They cannot be recovered if lost.

## 5. Add a DNS record in Cloudflare

Add an **A record** in Cloudflare for `wuguishifu.dev`:

- Name: `*` (wildcard, covers all subdomains)
- IPv4: your machine's Tailscale IP (`tailscale ip -4`)
- Proxy status: **DNS only** (grey cloud — Cloudflare cannot proxy Tailscale IPs)

## 6. Push the repo and apply the root app

```sh
git add -A && git commit -m "bootstrap homelab" && git push

kubectl apply -f apps/root.yaml
```

ArgoCD will discover all `apps/*.yaml` files and reconcile everything in sync-wave order:

| Wave | Apps                                                                          |
| ---- | ----------------------------------------------------------------------------- |
| 0    | cert-manager                                                                  |
| 1    | cert-manager-config (ClusterIssuer), postgresql, redis                        |
| 2    | argocd-config (ingress + TLS), infisical, infisical-operator (secrets-operator) |
| 3    | infisical-secrets (InfisicalSecret CRDs)                                      |

## 7. Get the initial ArgoCD admin password

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Log in at `https://argocd.wuguishifu.dev` with username `admin` and the password above. Change it immediately via **User Info → Update Password**.

---

## Post-install: Configure Infisical machine identity

Once `https://infisical.wuguishifu.dev` is up and you have created your admin account:

1. Create a project named `homelab`
2. Go to **Access Control → Machine Identities → Create**
3. Name it `k8s-operator`, choose **Universal Auth**
4. Copy the **Client ID** and **Client Secret**
5. In the project, grant the machine identity **Secrets → Read** permission
6. Add the Cloudflare token as a secret:
   - Environment: `prod`
   - Path: `/cert-manager`
   - Key: `api-token`
   - Value: your Cloudflare API token

Then create the machine identity secret in Kubernetes:

```sh
kubectl create secret generic infisical-machine-identity \
  --namespace infisical-operator-system \
  --from-literal=clientId=<CLIENT_ID> \
  --from-literal=clientSecret=<CLIENT_SECRET>
```

Once the `InfisicalSecret` is syncing (verify with `kubectl get infisicalsecret -A`), delete the temporary Cloudflare secret:

```sh
kubectl delete secret cloudflare-api-token -n cert-manager
```

The operator will recreate it from Infisical within 60 seconds. From this point on, all new secrets go into Infisical — add an `InfisicalSecret` manifest to `manifests/infisical-secrets/` and ArgoCD handles the rest.

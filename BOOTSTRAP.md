# Bootstrap

Everything in this repo is managed by ArgoCD via GitOps. These are the one-time manual steps to get the cluster and ArgoCD running.

## 1. Install k3s

```sh
curl -sfL https://get.k3s.io | sh -
```

## 2. Set up kubeconfig

k3s writes its kubeconfig to `/etc/rancher/k3s/k3s.yaml` as root-only. Copy it before running any `kubectl` commands.

```sh
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

export KUBECONFIG=~/.kube/config

# Verify the node is ready
kubectl get nodes
```

## 3. Install ArgoCD

```sh
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Wait for ArgoCD to be ready
kubectl -n argocd wait --for=condition=available deployment/argocd-server --timeout=120s
```

## 4. Create the Cloudflare API token secret

In the Cloudflare dashboard go to **My Profile → API Tokens → Create Token** with these permissions:

- `Zone > Zone > Read` — All zones (or specific: `wuguishifu.dev`)
- `Zone > DNS > Edit` — Specific zone: `wuguishifu.dev`

Then on the server:

```sh
# Pre-create the cert-manager namespace so the secret has somewhere to live
kubectl create namespace cert-manager

kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token=<YOUR_TOKEN_HERE>
```

## 5. Add a DNS record in Cloudflare

Add an **A record** in Cloudflare for `wuguishifu.dev`:

- Name: `*` (wildcard, covers all future subdomains)
- IPv4: your machine's Tailscale IP (`tailscale ip -4`)
- Proxy status: **DNS only** (grey cloud — Cloudflare cannot proxy Tailscale IPs)

## 6. Apply the root app

```sh
kubectl apply -f apps/root.yaml
```

ArgoCD will discover all other `apps/*.yaml` files and reconcile everything automatically in sync-wave order:

- Wave 0: cert-manager
- Wave 1: cert-manager-config (ClusterIssuer)
- Wave 2: argocd-config (ingress + TLS)

## 7. Get the initial ArgoCD admin password

```sh
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d && echo
```

Log in at `https://argocd.wuguishifu.dev` with username `admin` and the password above. Change it immediately via **User Info → Update Password**.

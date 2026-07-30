# Removing an App

ArgoCD has a finalizer (`resources-finalizer.argocd.argoproj.io`) that cascade-deletes live Kubernetes resources when an Application is removed. To do this it resolves git HEAD — so if the manifests are already gone from git, deletion gets stuck.

Every Application in `apps/` must carry exactly this finalizer:

```yaml
finalizers:
  - resources-finalizer.argocd.argoproj.io
```

The string has to match exactly. Kubernetes accepts any value as a finalizer, but only a controller that recognizes its own key will ever remove one — so a typo produces an object that stays in `Terminating` forever, and ArgoCD skips the cascade delete entirely, orphaning the app's live resources. Copy the line from an existing app rather than retyping it.

## With autosync enabled (standard)

Remove files in two separate commits:

1. Remove `apps/<dir>/<app>.yaml` and push — ArgoCD deletes the Application and cascade-deletes its live resources
2. Wait for the app to fully disappear from the ArgoCD UI
3. Remove `manifests/<app>/` and any `manifests/infisical-secrets/<app>.yaml`, then push

## If deletion gets stuck

This should be rare. Before reaching for the patch below, find out why — a stuck delete usually means something real:

- The Application's finalizer is misspelled (see above) — check with
  `kubectl get application <app-name> -n argocd -o jsonpath='{.metadata.finalizers}'`
- The destination cluster is unreachable, so the cascade delete can never finish
- A managed resource has its own finalizer blocking it — a PVC still mounted, a namespace stuck `Terminating`
- `manifests/` was removed in the same commit as `apps/`, so manifest generation fails

Once you know the cause, force it through:

```sh
sudo kubectl patch application <app-name> -n argocd \
  -p '{"metadata":{"finalizers":[]}}' \
  --type=merge
```

Deletion will complete immediately. Clean up the remaining git files afterward.

Note that this **orphans the app's live resources** — clearing the finalizer skips the cascade delete, so Deployments, Services, Ingresses, and PVCs keep running with no Application managing them. After using it, sweep for leftovers:

```sh
# resources still labelled for an app that no longer exists
kubectl get all,ingress,pvc -A -l app.kubernetes.io/instance=<app-name>
```

Delete anything it finds, and check for a leftover namespace.

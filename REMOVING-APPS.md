# Removing an App

ArgoCD has a finalizer (`resources-finalizer.argocd.argoproj.io`) that cascade-deletes live Kubernetes resources when an Application is removed. To do this it resolves git HEAD — so if the manifests are already gone from git, deletion gets stuck.

## With autosync enabled (standard)

Remove files in two separate commits:

1. Remove `apps/<dir>/<app>.yaml` and push — ArgoCD deletes the Application and cascade-deletes its live resources
2. Wait for the app to fully disappear from the ArgoCD UI
3. Remove `manifests/<app>/` and any `manifests/infisical-secrets/<app>.yaml`, then push

## If deletion gets stuck

The finalizer is blocking. Remove it manually:

```sh
sudo kubectl patch application <app-name> -n argocd \
  -p '{"metadata":{"finalizers":[]}}' \
  --type=merge
```

Deletion will complete immediately. Clean up the remaining git files afterward.

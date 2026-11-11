# homelab – k3s on Raspberry Pi (later + x86 laptop)

This repo decides **what runs on the cluster** and is the only thing that touches it.
Apps live in their own repos, created from `homelab-app-template`, and only build images.

```
app repo (push dev/main) ─▶ Actions: build arm64+amd64 ─▶ GHCR
        │
        └─ repository_dispatch {app, env, tag} ─▶ homelab: validate ─▶ runner on cluster: helm upgrade
                                                              └─▶ commit tag to apps/<app>/tag-<env>.yaml

Users ─▶ Cloudflare Access (Google login) ─▶ Tunnel ─▶ cloudflared ─▶ Traefik ─▶ app
```

App repo `dev` → namespace `staging` · app repo `main` → namespace `prod`.
This repo has only a `main` branch.

## Repo layout

| Path | What |
|---|---|
| `charts/web-app/` | One generic chart: Deployment + Service + Ingress |
| `apps/<name>/values.yaml` | Image repository, port, env, resources – shared by both environments |
| `apps/<name>/values-staging.yaml`, `values-prod.yaml` | Per-environment settings such as `host` |
| `apps/<name>/tag-staging.yaml`, `tag-prod.yaml` | **Written by the workflow** – the version currently deployed |
| `platform/` | Cluster-wide things (cloudflared) |
| `.github/workflows/deploy.yml` | The only workflow that deploys |

## What triggers a deploy

| Event | What happens |
|---|---|
| App repo pushes (dispatch) | That app/env is deployed with the new tag. If it succeeds, the tag is committed here |
| Push to `main` here | Apps whose config changed are redeployed with their recorded tags. A chart or workflow change redeploys everything |
| *Run workflow* (manual) | Everything with a recorded tag is redeployed, plus `platform/`. Use it after rebuilding the cluster |

Rolling back an app means changing its `tag-<env>.yaml` to an older SHA and pushing.

## Adding an app

Follow the README in `homelab-app-template`. In short: create a repo from the template, add the dispatch secret, copy its `homelab-config/` folder here as `apps/<name>/`, then push to `dev` in the app repo.

Keep hostnames **one level deep** (`x.murarvagen.se`, `x-staging.murarvagen.se`), because the free Cloudflare certificate only covers one level.
An app without `host` is internal-only and reachable at `http://<name>.<namespace>.svc`.

---

## One-time setup

### 1. Raspberry Pi
- Raspberry Pi OS Lite **64-bit**. A USB SSD is preferred over an SD card.
- Append to the single line in `/boot/firmware/cmdline.txt`, then reboot:
  `cgroup_memory=1 cgroup_enable=memory`
- Install k3s with defaults:
  ```bash
  curl -sfL https://get.k3s.io | sh -
  ```
- Install Helm and give your user a kubeconfig:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown $USER ~/.kube/config
  ```

### 2. GitHub organization
All repos (`homelab`, `homelab-app-template` and the apps) live in the organization.

- **Who can deploy:** anyone with write access to `homelab` can change what runs on the cluster. Give write access to a small team (e.g. `homelab-admins`); others only need write access to their own app repos.
- **Template:** in `homelab-app-template` → Settings, tick *Template repository*.
- **Packages:** Organization → Settings → Packages: allow members to create packages (private, or public if you choose public images in step 4).

**Deploy GitHub App** (lets app repos trigger deploys without anyone's personal token):
1. Organization → Settings → Developer settings → GitHub Apps → *New GitHub App*.
   - Name e.g. `<org>-homelab-deploy`. Homepage URL: anything. Webhook: **uncheck** *Active*.
   - Repository permissions: **Contents: Read and write** (needed to trigger `repository_dispatch`). Nothing else.
   - *Only on this account*.
2. Create the app, note the **App ID**, and generate a **private key** (.pem file).
3. *Install App* → the organization → **Only select repositories** → `homelab`.
4. Organization → Settings → Secrets and variables → Actions:
   - Variable `HOMELAB_DEPLOY_APP_ID` = the App ID
   - Secret `HOMELAB_DEPLOY_APP_KEY` = the whole .pem file content
   - Repository access: *All repositories*, or *Selected* if you want to choose which repos can deploy (then add each new app repo).
5. Delete the downloaded .pem file.

The App can only touch `homelab`, and every token it hands out expires within an hour.

### 3. GitHub runner (on the Pi for now)
Keep this repo **private**: the runner has full access to the cluster.

Register the runner on **this repo** (not at org level), so no other repo in the organization can run jobs on the Pi:
repo Settings → Actions → Runners → *New self-hosted runner* → Linux / ARM64. Run the commands shown, and when `config.sh` asks for extra labels, enter `homelab`. Then:
```bash
sudo ./svc.sh install && sudo ./svc.sh start
```
Under Settings → Environments, create `staging` and `prod`. Optionally give `prod` a required reviewer to get a manual approval before prod deploys.

### 4. Pulling images from GHCR
Pick one option:

- **Public images (simplest):** fine when the images contain no secrets. Secrets belong in Kubernetes anyway, not in images. After the first build of each app, set its package to public (package → Package settings → Change visibility), and set `imagePullSecrets: []` in `charts/web-app/values.yaml`. Nothing to maintain.
- **Private images:** GHCR has no organization-owned pull tokens, so this needs a **classic** PAT with only `read:packages` from an org member. A dedicated bot account is better than a personal one. Then:
  ```bash
  for ns in staging prod; do
    kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n $ns create secret docker-registry ghcr \
      --docker-server=ghcr.io --docker-username=<account> --docker-password=<PAT>
  done
  ```

### 5. Cloudflare (murarvagen.se must be on Cloudflare DNS)
1. **Tunnel:** Zero Trust → Networks → Tunnels → Create (type *Cloudflared*). Copy the token, then:
   ```bash
   kubectl create namespace cloudflared
   kubectl -n cloudflared create secret generic tunnel-token --from-literal=token=<TOKEN>
   kubectl apply -f platform/cloudflared.yaml
   ```
2. **Route:** in the tunnel, add a public hostname `*.murarvagen.se` → service `http://traefik.kube-system.svc.cluster.local:80`.
3. **DNS:** check that a proxied record `*` CNAME → `<tunnel-id>.cfargotunnel.com` exists. Add it yourself if the dashboard didn't create it.
4. **Google login:** Zero Trust → Settings → Authentication → add *Google Workspace* as an identity provider.
5. **Access app:** Access → Applications → Self-hosted, domain `*.murarvagen.se`, policy *Allow* → emails ending in `@<your-workspace-domain>`, or specific emails/groups. Add a stricter app for `*-staging` hosts if you like.

### 6. First app
Create the `homepage` repo from `homelab-app-template`. `apps/homepage/` already exists here; set `image.repository` in its `values.yaml` to the organization name (lowercase). Then push to `dev` in the homepage repo and open `https://home-staging.murarvagen.se`.

---

## When the x86 laptop (or a Tradera find) arrives

The stronger machine should become the k3s **server** and run the runner. The Pi becomes an **agent**. Single-server k3s can't hand over its control plane, so the move is a reinstall. That's fine, because everything, including which version of each app runs, lives in this repo.

1. **Laptop:** Ubuntu Server or Debian. Stop it from sleeping when the lid is closed (`HandleLidSwitch=ignore` in `/etc/systemd/logind.conf`), and set the BIOS to power on after power loss. The battery doubles as a small UPS.
2. Install k3s on the laptop: `curl -sfL https://get.k3s.io | sh -`
3. On the Pi: `/usr/local/bin/k3s-uninstall.sh`, then join it as an agent:
   ```bash
   curl -sfL https://get.k3s.io | K3S_URL=https://<laptop-ip>:6443 K3S_TOKEN=<from /var/lib/rancher/k3s/server/node-token on laptop> sh -
   ```
4. Move the runner: remove it from the Pi and register a new one on the laptop (Linux / **x64**, label `homelab`), plus Helm and kubeconfig as above.
5. Recreate the secrets: the GHCR pull secret (step 4, if you use private images) and the tunnel token (step 5.1). The tunnel and Access settings in Cloudflare stay as they are.
6. Actions → *deploy* → *Run workflow*. This applies `platform/` and redeploys every app at its recorded version.

Images are built for both arm64 and amd64, so pods can run on either machine.

**Things to keep in mind with more than one node:**
- `local-path` volumes stay on the node where they were created. Pin stateful apps with `nodeSelector`. If you need shared storage, use an NFS share on the laptop; Longhorn is too heavy for a Pi 3.
- Label nodes for placement: `kubectl label node <pi> role=edge`, `kubectl label node <laptop> role=main`, `has-usb=true` where a USB device is plugged in. Then set `nodeSelector` in an app's values.

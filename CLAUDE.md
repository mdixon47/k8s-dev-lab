# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project overview

`k8s-dev-lab` is a reproducible local Kubernetes development environment. Vagrant provisions
three Ubuntu 26.04 LTS VMs on VirtualBox, kubeadm forms them into a real cluster
(1 control plane + 2 workers, Flannel CNI), and a FastAPI + Postgres sample app runs on it.

```
cp1  192.168.56.10  control plane
w1   192.168.56.11  worker
w2   192.168.56.12  worker
web  192.168.56.20  edge (nginx reverse proxy; NOT a cluster member)
```

Host requirements: VirtualBox 7.x (7.1+ on Apple Silicon), Vagrant 2.4+, Docker, kubectl (within one minor of `K8S_VERSION`), make, curl, ~9 GB free RAM (~7 GB with `K8S_DESKTOP=""`).

## Repository layout

| Path | Purpose |
|------|---------|
| `Vagrantfile` | VM/node definitions. `NODES` array controls count, IPs, CPU, RAM. Constants: `K8S_VERSION` (1.36), `FLANNEL_VERSION` (release tag for the CNI manifest), `POD_CIDR`, `NET_PREFIX`, `BOX` (`bento/ubuntu-26.04` on every host arch, since Canonical publishes no 26.04 box; override with `K8S_BOX`). The desktop node boots with its VirtualBox window open (`K8S_GUI=1`, default); `K8S_GUI=0` boots every node headless, `K8S_GUI=all` opens every node's window, `K8S_GUI=cp1,w1` a list. |
| `scripts/desktop.sh` | Stock Ubuntu desktop (`ubuntu-desktop-minimal`: GNOME Shell, Ubuntu dock, Yaru, Firefox, App Center) with GDM auto-login (Wayland; GNOME 50 has no Xorg session) and no lock screen, on `DESKTOP_NODE` (Vagrantfile, default `cp1`, override `K8S_DESKTOP=<node>` or `""`). That node is sized up to `DESKTOP_MEM`/`DESKTOP_CPUS` (4 GB / 4 CPUs) and gets a bidirectional clipboard. Auto-logs in as `vagrant`. Purges an older XFCE/lightdm install if found. Needs a framebuffer; the stock 26.04 kernel (7.0, simpledrm) provides one on amd64 and arm64. Runs last so the cluster is up first. |
| `scripts/common.sh` | Runs on every node: kernel modules, sysctl, swap off, containerd (SystemdCgroup), kubeadm/kubelet/kubectl from pkgs.k8s.io, pins kubelet `--node-ip`. |
| `scripts/control-plane.sh` | `kubeadm init`, writes kubeconfig to `/vagrant/kubeconfig`, installs Flannel (manifest from the `FLANNEL_VERSION` release tag) pinned to the interface that owns `NODE_IP` (`eth1`; the bento box boots with `net.ifnames=0`), writes `/vagrant/join.sh`. |
| `scripts/worker.sh` | Waits for `join.sh` then joins the cluster. |
| `scripts/web.sh` | `web` role only: nginx on 80/443 (self-signed cert) proxying `/` to the site NodePort 30081 and `/api/` to the API NodePort 30080 on `WORKERS` with failover. No kubeadm/containerd on this node. |
| `scripts/console-banner.sh` | Every VM: `/etc/issue` login banner with credentials and `kernel.printk` lowered so the tty prompt stays readable. |
| `scripts/load-image.sh` | Builds `devapp/api:dev` (from `app/`) and `devapp/web:dev` (from `web/`) with Docker on the host and imports them into containerd on each worker via `ctr -n k8s.io images import`. No registry. Args select images (`make image IMAGES=web`); bash-3.2 compatible (macOS). |
| `app/main.py` | FastAPI service (psycopg 3). Endpoints: `/healthz`, `/readyz`, `GET/POST /notes`. Creates the `notes` table on startup. |
| `web/` | Static site (`site/`), `nginx.conf` proxying `/api/` to the `api` Service and `/docs`,`/openapi.json` through, `Dockerfile` on `nginxinc/nginx-unprivileged` (uid 101, port 8080). Built as `devapp/web:dev`. |
| `app/Dockerfile` | python:3.12-slim, non-root `appuser` (UID 1000), uvicorn on 8000. |
| `k8s/00-namespace.yaml` | `devapp` namespace. |
| `k8s/10-postgres.yaml` | Secret, PVC, StatefulSet (postgres:16-alpine), ClusterIP Service. |
| `k8s/20-api.yaml` | Deployment (2 replicas, probes, limits, non-root securityContext), NodePort Service on 30080. |
| `k8s/30-web.yaml` | web Deployment (2 replicas, `restricted`-compliant: read-only root fs, drop ALL, seccomp, no SA token, emptyDirs for `/tmp` and `/var/cache/nginx`), NodePort Service on 30081. |
| `Makefile` | Workflow targets (below). `test` derives the worker and edge IPs from the Vagrantfile (`NET_PREFIX`, first `worker`/`web` node); `deploy` waits `ROLLOUT_TIMEOUT` (180s) per rollout. |
| `scripts/check.sh` | `make check`: ShellCheck on every script, yamllint (`.yamllint`: relaxed, line length and colon alignment off), kubeconform on `k8s/`, `policy/examples/`, `policy/tests/fixtures/`, `security/policies/` (unknown CRD kinds skipped), and a relative-link check over every `*.md`. Missing shellcheck/yamllint → SKIP; kubeconform falls back to its Docker image. |
| `scripts/policy-test.sh` | `make policy-test`: `gator verify policy/tests/suite.yaml`. Extracts the StatefulSet/Deployments from `k8s/` into `policy/tests/fixtures/lab/` (git-ignored, one object per file, which gator requires) on every run. Local `gator` if installed, else `openpolicyagent/gator:$GATEKEEPER_VERSION` via Docker on a temp copy (Docker Desktop cannot mount this external-drive path). |
| `policy/tests/` | Gator suite: every template + constraint against `fixtures/privileged-pod.yaml` (devapp), the same pod in `default` (must not match), the lab workloads, and `pod-level-nonroot.yaml`; plus `policy/examples/` registry policy against its two deployments. Asserts exact violation counts (postgres: 2 non-root, 2 resource-limits; privileged pod: 4 no-privilege). Add a case whenever a template changes. |
| `.github/workflows/check.yml` | CI: `make check` + `make policy-test` on push and PR. No VM steps. |
| `docs/issues.md` | Known gaps, unverified claims and future work, each with status. Update it when one is resolved. |
| `scripts/gatekeeper.sh` | `make policy`: applies the pinned OPA Gatekeeper release manifest (`GATEKEEPER_VERSION`, Makefile), scales the controller to 1 replica (3×512Mi does not fit a 2 GB worker), applies `policy/templates/` then waits for their CRDs, then `policy/constraints/`. `uninstall` argument removes all of it. |
| `policy/` | Gatekeeper policy. `templates/`: ConstraintTemplates in Rego (`K8sLabNoPrivilege`: privileged/host namespaces/hostPath; `K8sLabNonRoot`: runAsNonRoot + allowPrivilegeEscalation false; `K8sLabResourceLimits`: cpu/memory limits). Each handles Pods and workload kinds via `spec.template.spec` so warnings appear on `kubectl apply` of the Deployment/StatefulSet. `constraints/`: one per template, scoped to namespaces `devapp` and `sec-*`; `no-privilege` is `deny`, the other two `warn` because postgres violates them. Not applied by `make deploy` (`kubectl apply -f k8s/` is not recursive and `policy/` sits outside it). |
| `security/` | Security test routines, `make sectest` (`ROUTINE=NN` for one, `SKIP_SLOW=1` to skip Trivy/kube-bench). `lib.sh` has the PASS/FAIL helpers; `policies/` holds the NetworkPolicy and privileged-pod fixtures. Routines create and remove `sec-probe`/`sec-psa`/`sec-gk` namespaces and kube-bench Jobs. `10-gatekeeper.sh` skips unless `make policy` has run. |
| `docs/learn.md` | Learning guide: layer-by-layer explanation of the lab, guided walkthrough, exercises. |
| `docs/course.md` | 30-lesson course (Part 1 foundations, Part 2 admission control/Gatekeeper, capstone). Every command verified against the lab; "Lab note" blocks mark where the lab differs. Keep it in sync with `learn.md` when behaviour changes. |
| `policy/examples/` | Course reference solutions, not applied by `make policy`: `registry-template.yaml`/`registry-constraint.yaml` (`K8sLabApprovedRegistry`, parameter `allowedRegistries`, warn, devapp + `sec-*`) and `approved-deployment.yaml` (`cgr.dev/chainguard/nginx:latest`, distroless: no `kubectl exec`) / `unapproved-deployment.yaml`. `kubectl delete -f policy/examples/` removes all four. |

Generated, git-ignored files: `kubeconfig`, `join.sh`, `*-image.tar`, `.vagrant/`.

## Common commands

```bash
make all       # up → storage → image → deploy → test in one command
make up        # open the VirtualBox app (make vbox), then vagrant up (15–20 min first run; VBOX_APP=0 skips the app)
make storage   # install local-path-provisioner and set it as default StorageClass
make image     # build api + web images and load onto workers (IMAGES=web for one)
make deploy    # kubectl apply -f k8s/ and wait for rollouts
make status    # nodes, pods, svc, pvc
make logs      # tail API logs
make test      # API via 30080, site via 30081, and via the web edge 192.168.56.20
make policy    # OPA Gatekeeper + policy/ constraints (optional, after deploy; GATEKEEPER_VERSION=vX.Y.Z)
make sectest   # security routines in security/ (ROUTINE=NN, SKIP_SLOW=1)
make snapshot  # vagrant snapshot save --force $(SNAP) on every VM (SNAP=base)
make restore   # vagrant snapshot restore --no-provision $(SNAP)
make check     # static checks, no VMs: shellcheck, yamllint, kubeconform, doc links
make policy-test  # gator verify on policy/tests/suite.yaml, no cluster
make down      # vagrant halt
make clean     # vagrant destroy + remove generated files
```

`kubectl` from the host: `export KUBECONFIG="$PWD/kubeconfig"`.

Run order for a fresh clone: `up → storage → image → deploy → test` (`make all` runs them in order, stopping at the first failure).
`storage` must precede `deploy` or the Postgres PVC stays Pending.

## Development loop

1. Edit `app/main.py` (API) or `web/site/`, `web/nginx.conf` (site).
2. `make image` (or `IMAGES=api` / `IMAGES=web`) — rebuilds and re-imports on both workers.
3. `kubectl -n devapp rollout restart deployment/api` (or `deployment/web`).

Because `imagePullPolicy: IfNotPresent` and the tags are fixed (`devapp/api:dev`, `devapp/web:dev`), a rollout
restart is required after every image reload; pods won't pick up the new image otherwise.

Local run without the cluster: `cd app && pip install -r requirements.txt && uvicorn main:app --reload`
(needs a Postgres reachable at `DATABASE_URL`, default `postgresql://app:app@localhost:5432/appdb`).

## Conventions and constraints

- **Networking is VirtualBox-specific.** Every VM's NAT NIC shares 10.0.2.15, so kubelet is
  pinned with `--node-ip` and Flannel with `--iface=<interface owning NODE_IP>` (resolved at
  provision time, falls back to `eth1`). Do not remove these when editing the scripts.
- **Adding a node:** append to `NODES` in the Vagrantfile, then `vagrant up <name>`. `role` selects the
  provisioners: `control-plane`/`worker` run `common.sh` + kubeadm; `web` runs only `web.sh`; anything
  else raises. `WORKER_IPS` is derived from `NODES`. Update `load-image.sh`'s worker list and `make test`'s IP if relevant.
- **Kubernetes version:** change `K8S_VERSION` in the Vagrantfile only; scripts read it from env.
  Keep the pkgs.k8s.io minor-version repo in sync (it is derived automatically). A change needs
  fresh VMs (`make clean && make all`): `common.sh` holds the packages, so re-provisioning an
  existing node does not upgrade it. Bump `FLANNEL_VERSION` the same way (release tag; check the
  manifest's args are still a YAML list or the JSON form the `sed` handles).
- **Before committing:** `make check` and `make policy-test` both pass without VMs. Any template
  change gets a case in `policy/tests/suite.yaml`; any new manifest goes through kubeconform.
- **Images:** no registry is used. Any new image must be loaded with the same
  `docker save | ctr import` pattern or pulled from a public registry.
- **Policy:** any new workload in `devapp` must satisfy `policy/`: the `deny` constraint rejects privileged
  containers, host namespaces and hostPath; the `warn` ones expect `runAsNonRoot`, `allowPrivilegeEscalation: false`
  and limits. Keep new constraints scoped to `devapp`/`sec-*` and default new ones to `warn` until the existing
  workloads pass audit (`kubectl get constraints -o wide` shows TOTAL-VIOLATIONS). Templates are Rego v0 syntax.
- **Manifests:** numbered prefixes (`00-`, `10-`, `20-`) control apply order. Keep new
  resources in the `devapp` namespace and follow the same numbering.
- **Secrets:** `k8s/10-postgres.yaml` contains dev-only plaintext credentials. Never treat
  this layout as production-ready; anything shared should move to an external secrets store.
- **Security posture:** API pods run as non-root with `allowPrivilegeEscalation: false` and
  resource limits. Preserve these on any new workloads.
- Shell scripts use `set -euo pipefail`; keep that. Validate YAML before committing.
- **Provisioning is idempotent and re-runnable.** `vagrant provision` skips `kubeadm init`/`join` on initialized nodes. Provisioners are named (`hosts`, `banner`, `common`, `control-plane`, `worker`, `web`, `desktop`), so prefer `vagrant provision <node> --provision-with <name>` for one step; `control-plane.sh` waits for the API server.
- **Desktop:** only one node gets it. Re-run just that step with `vagrant provision cp1 --provision-with desktop`. Closing the VM window must use "Continue running in background"; "Power off" halts the node (recover with `vagrant up <node>`).
- **Console window:** the desktop node boots with its window open; the others are headless. `make up` launches the VirtualBox Manager first (`VBOX_APP=0` to skip). Open a running headless node's window from it (select it, Show), or boot with `K8S_GUI=all`; `K8S_GUI=0` keeps every node headless. `VBoxManage startvm` on a running node fails with "already locked by a session"; that is expected. The 26.04 kernel (7.0) ships `simpledrm`, so the window shows a login prompt on arm64 too; a window stuck at "EFI stub: Exiting boot services" means the kernel lacks a display driver while the OS is up, so use `vagrant ssh`.

## Troubleshooting

- Workers stuck "Waiting for join.sh": control plane provisioning failed — check `vagrant ssh cp1` and `journalctl -u kubelet`.
- Pods `Pending` with PVC unbound: run `make storage`.
- Pods `ErrImageNeverPull` / `ImagePullBackOff`: run `make image`.
- Nodes `NotReady`: Flannel not up — `kubectl -n kube-flannel get pods`; confirm the private-network interface (`eth1`) exists in the VM.
- Pods can't resolve DNS / reach pods on other nodes (`Temporary failure in name resolution`, `nslookup` times out) while nodes are Ready: Flannel is advertising the NAT address. Check `kubectl get nodes -o custom-columns='NAME:.metadata.name,IP:.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip'`; every node must show its 192.168.56.x address, not 10.0.2.15. Fix with `vagrant provision cp1 --provision-with control-plane` (re-applies Flannel with `--iface`, no reboot), then delete the affected pods.
- `kubeadm init` preflight errors (ports in use, manifests exist, `/var/lib/etcd` not empty): provisioning was re-run on an initialized node. The scripts are idempotent, so this only happens with an old copy of `scripts/control-plane.sh`; `vagrant provision` is safe to re-run.
- `mount.vboxsf: No such device` / `/vagrant` empty after a kernel change (e.g. an unattended upgrade pulled a new kernel): Guest Additions modules are missing for the running kernel. Run `sudo /sbin/rcvboxadd quicksetup $(uname -r)` in the VM (needs `make` and the `gcc` the kernel was built with), then `vagrant reload <node>`.
- kubelet fails with `running with swap on` after a reboot: `/etc/fstab` swap line not commented. `scripts/common.sh` handles the tab-separated line; re-run `vagrant provision <node>`.
- Desktop shows a black screen but `gdm3`/`gnome-shell` are running: the display output got disabled (on ARM64 the ramfb display cannot resize; `VBoxClient --vmsvga` reacting to a host resize hint turns it off). `scripts/desktop.sh` installs `/usr/local/bin/vbox-display-fix` and sets `GUI/AutoresizeGuest=off`; as a one-off, run `xrandr --output None-1 --auto` inside the session.
- Console login "fails": credentials are `vagrant` / `vagrant` on every node (bento box default; verify with `echo vagrant | pamtester login vagrant authenticate`). The tty banner prints them; press Enter to redraw the prompt. The desktop has no lock screen (`desktop.sh` disables it through dconf).
- API `/readyz` returns 503: Postgres not ready yet or `DATABASE_URL` wrong.
- `make deploy` fails with `error: timed out waiting for the condition`: a rollout did not finish within `ROLLOUT_TIMEOUT`. Postgres → PVC Pending (`make storage`); api/web → image missing (`make image`) or `/readyz` failing. Fix and re-run `make deploy`.
- `make policy` fails at `kubectl apply -f policy/constraints/` with "no matches for kind K8sLab…": the template CRDs were not established yet; re-run, the script waits for them. `gatekeeper-audit` showing 1 restart right after install is the known startup race on the webhook cert (`/certs/tls.crt: no such file`), harmless.
- A pod in `devapp` is rejected with `admission webhook "validation.gatekeeper.sh" denied the request`: read the `[no-privilege]` message; it names the container and field. Pods in `default` are not matched. If Gatekeeper is down the webhook's `failurePolicy: Ignore` admits everything, so a "missing" denial usually means the controller pod is not Running.

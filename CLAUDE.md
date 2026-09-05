# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project overview

`k8s-dev-lab` is a reproducible local Kubernetes development environment. Vagrant provisions
three Ubuntu 22.04 VMs on VirtualBox, kubeadm forms them into a real cluster
(1 control plane + 2 workers, Flannel CNI), and a FastAPI + Postgres sample app runs on it.

```
cp1  192.168.56.10  control plane
w1   192.168.56.11  worker
w2   192.168.56.12  worker
web  192.168.56.20  edge (nginx reverse proxy; NOT a cluster member)
```

Host requirements: VirtualBox 7.x (7.1+ on Apple Silicon), Vagrant 2.4+, Docker, kubectl, make, curl, ~8 GB free RAM (~6 GB with `K8S_DESKTOP=""`).

## Repository layout

| Path | Purpose |
|------|---------|
| `Vagrantfile` | VM/node definitions. `NODES` array controls count, IPs, CPU, RAM. Constants: `K8S_VERSION`, `POD_CIDR`, `NET_PREFIX`, `BOX` (auto-selected by host arch: `ubuntu/jammy64` on amd64, `bento/ubuntu-22.04` on arm64; override with `K8S_BOX`). |
| `scripts/console-kernel.sh` | arm64 only (`CONSOLE_KERNEL` in the Vagrantfile, override `K8S_CONSOLE_KERNEL=0|1`): installs the 22.04 HWE kernel (6.8) so the VirtualBox console window shows output, patches and rebuilds Oracle Guest Additions (vboxsf backs `/vagrant`) for it. Vagrant reboots the node afterwards. |
| `scripts/desktop.sh` | XFCE desktop + Firefox on `DESKTOP_NODE` (Vagrantfile, default `cp1`, override `K8S_DESKTOP=<node>` or `""`). That node is sized up to `DESKTOP_MEM`/`DESKTOP_CPUS` (4 GB / 4 CPUs) and gets a bidirectional clipboard. Auto-logs in as `vagrant`. Needs a framebuffer, i.e. the console kernel on arm64. Runs last so the cluster is up first. |
| `scripts/common.sh` | Runs on every node: kernel modules, sysctl, swap off, containerd (SystemdCgroup), kubeadm/kubelet/kubectl from pkgs.k8s.io, pins kubelet `--node-ip`. |
| `scripts/control-plane.sh` | `kubeadm init`, writes kubeconfig to `/vagrant/kubeconfig`, installs Flannel pinned to the interface that owns `NODE_IP` (`enp0s8` on `ubuntu/jammy64`, `eth1` on `bento/ubuntu-22.04`), writes `/vagrant/join.sh`. |
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
| `Makefile` | Workflow targets (below). |
| `security/` | Security test routines, `make sectest` (`ROUTINE=NN` for one, `SKIP_SLOW=1` to skip Trivy/kube-bench). `lib.sh` has the PASS/FAIL helpers; `policies/` holds the NetworkPolicy and privileged-pod fixtures. Routines create and remove `sec-probe`/`sec-psa` namespaces and kube-bench Jobs. |
| `docs/learn.md` | Learning guide: layer-by-layer explanation of the lab, guided walkthrough, exercises. |

Generated, git-ignored files: `kubeconfig`, `join.sh`, `*-image.tar`, `.vagrant/`.

## Common commands

```bash
make up        # vagrant up — provisions cluster (10–15 min first run)
make storage   # install local-path-provisioner and set it as default StorageClass
make image     # build api + web images and load onto workers (IMAGES=web for one)
make deploy    # kubectl apply -f k8s/ and wait for rollouts
make status    # nodes, pods, svc, pvc
make logs      # tail API logs
make test      # API via 30080, site via 30081, and via the web edge 192.168.56.20
make sectest   # security routines in security/ (ROUTINE=NN, SKIP_SLOW=1)
make down      # vagrant halt
make clean     # vagrant destroy + remove generated files
```

`kubectl` from the host: `export KUBECONFIG="$PWD/kubeconfig"`.

Run order for a fresh clone: `up → storage → image → deploy → test`.
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
  provision time, falls back to `enp0s8`). Do not remove these when editing the scripts.
- **Adding a node:** append to `NODES` in the Vagrantfile, then `vagrant up <name>`. `role` selects the
  provisioners: `control-plane`/`worker` run `common.sh` + kubeadm; `web` runs only `web.sh`; anything
  else raises. `WORKER_IPS` is derived from `NODES`. Update `load-image.sh`'s worker list and `make test`'s IP if relevant.
- **Kubernetes version:** change `K8S_VERSION` in the Vagrantfile only; scripts read it from env.
  Keep the pkgs.k8s.io minor-version repo in sync (it is derived automatically).
- **Images:** no registry is used. Any new image must be loaded with the same
  `docker save | ctr import` pattern or pulled from a public registry.
- **Manifests:** numbered prefixes (`00-`, `10-`, `20-`) control apply order. Keep new
  resources in the `devapp` namespace and follow the same numbering.
- **Secrets:** `k8s/10-postgres.yaml` contains dev-only plaintext credentials. Never treat
  this layout as production-ready; anything shared should move to an external secrets store.
- **Security posture:** API pods run as non-root with `allowPrivilegeEscalation: false` and
  resource limits. Preserve these on any new workloads.
- Shell scripts use `set -euo pipefail`; keep that. Validate YAML before committing.
- **Provisioning is idempotent and re-runnable.** `vagrant provision` skips `kubeadm init`/`join` on initialized nodes. On arm64 a full run reboots every node (console-kernel provisioner). Provisioners are named (`hosts`, `console-kernel`, `common`, `control-plane`, `worker`, `desktop`), so prefer `vagrant provision <node> --provision-with <name>` for one step; `control-plane.sh` waits for the API server.
- **Desktop:** only one node gets it. Re-run just that step with `vagrant provision cp1 --provision-with desktop`. Closing the VM window must use "Continue running in background"; "Power off" halts the node (recover with `vagrant up <node>`).
- **Console window:** on arm64 the VM display only works on the HWE kernel installed by `scripts/console-kernel.sh`. On the stock 5.15 kernel the window stops at "EFI stub: Exiting boot services" while the OS is fully up; use `vagrant ssh` instead.

## Troubleshooting

- Workers stuck "Waiting for join.sh": control plane provisioning failed — check `vagrant ssh cp1` and `journalctl -u kubelet`.
- Pods `Pending` with PVC unbound: run `make storage`.
- Pods `ErrImageNeverPull` / `ImagePullBackOff`: run `make image`.
- Nodes `NotReady`: Flannel not up — `kubectl -n kube-flannel get pods`; confirm the private-network interface (`enp0s8` or `eth1`) exists in the VM.
- Pods can't resolve DNS / reach pods on other nodes (`Temporary failure in name resolution`, `nslookup` times out) while nodes are Ready: Flannel is advertising the NAT address. Check `kubectl get nodes -o custom-columns='NAME:.metadata.name,IP:.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip'`; every node must show its 192.168.56.x address, not 10.0.2.15. Fix with `vagrant provision cp1 --provision-with control-plane` (re-applies Flannel with `--iface`, no reboot), then delete the affected pods.
- `kubeadm init` preflight errors (ports in use, manifests exist, `/var/lib/etcd` not empty): provisioning was re-run on an initialized node. The scripts are idempotent, so this only happens with an old copy of `scripts/control-plane.sh`; `vagrant provision` is safe to re-run.
- `mount.vboxsf: No such device` / `/vagrant` empty after a kernel change: Guest Additions modules are missing for the running kernel. Run `sudo /sbin/rcvboxadd quicksetup $(uname -r)` in the VM (see `scripts/console-kernel.sh` for the header patch 7.2.x needs on 6.8), then `vagrant reload <node>`.
- kubelet fails with `running with swap on` after a reboot: `/etc/fstab` swap line not commented. `scripts/common.sh` handles the tab-separated line; re-run `vagrant provision <node>`.
- Desktop shows a black screen but `lightdm`/`xfce4-session` are running: the display output got disabled (on ARM64 the ramfb display cannot resize; `VBoxClient --vmsvga` reacting to a host resize hint turns it off). `scripts/desktop.sh` installs `/usr/local/bin/vbox-display-fix` and sets `GUI/AutoresizeGuest=off`; as a one-off, run `xrandr --output None-1 --auto` inside the session.
- Console login "fails": credentials are `vagrant` / `vagrant` on every node (bento box default; verify with `echo vagrant | pamtester login vagrant authenticate`). The tty banner prints them; press Enter to redraw the prompt. The desktop has no lock screen (`desktop.sh` purges `xfce4-screensaver`).
- API `/readyz` returns 503: Postgres not ready yet or `DATABASE_URL` wrong.

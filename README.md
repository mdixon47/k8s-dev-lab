# Kubernetes Dev Lab — VirtualBox + kubeadm + FastAPI/Postgres

A reproducible local development environment: three Ubuntu 26.04 LTS VMs on VirtualBox
form a real kubeadm cluster (1 control plane, 2 workers), and a FastAPI + Postgres
sample app runs on it behind an nginx site, with a fourth VM acting as the edge. One node also gets the stock Ubuntu desktop (GNOME) and boots with its VirtualBox window
open, so you can work inside the cluster from a VM window.

```
Host ──vagrant──▶ cp1  192.168.56.10  (control plane, Flannel CNI, Ubuntu desktop)
                  w1   192.168.56.11  (worker)
                  w2   192.168.56.12  (worker)
                  web  192.168.56.20  (edge: nginx reverse proxy, not in the cluster)
```

## Prerequisites (host)
- VirtualBox 7.x (7.1+ on Apple Silicon; the `bento/ubuntu-26.04` box ships amd64 and arm64 builds)
- Vagrant 2.4+
- Docker (to build the API and site images)
- kubectl within one minor version of `K8S_VERSION` (Vagrantfile; kubectl's skew policy), make, curl
- ~9 GB free RAM (~7 GB without the desktop), ~30 GB disk

## Quick start
```bash
make up        # open the VirtualBox app, then provision VMs + cluster (15–20 min first run)
make storage   # default StorageClass for the Postgres PVC
make image     # build devapp/api:dev and devapp/web:dev, import into each worker's containerd
make deploy    # apply k8s/ manifests
make test      # curl the API (30080), the site (30081), and the web edge
make policy    # optional: OPA Gatekeeper + the lab's admission policy (policy/)
make snapshot  # optional: VirtualBox snapshot of every VM, so make restore undoes any experiment
```

`make all` runs the first five in order and stops at the first failure; `make policy` and
`make snapshot` stay separate, optional steps. Each rollout wait in `make deploy` gives up
after `ROLLOUT_TIMEOUT` (180 s), so a missing StorageClass or image fails the step instead
of hanging.

Without VMs at all: `make check` lints the scripts and manifests (ShellCheck, yamllint,
kubeconform, doc links) and `make policy-test` unit-tests the Gatekeeper policy with `gator`
(Docker fallback for both when the tools are not installed).

New to Kubernetes? [docs/course.md](docs/course.md) is a 30-lesson hands-on course built on
this lab (foundations, then admission control with OPA Gatekeeper and a capstone);
[docs/learn.md](docs/learn.md) explains each layer in depth.

`kubectl` works from the host once the cluster is up:
```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes
```

`make up` (and `vagrant provision`) can be re-run safely: the scripts skip `kubeadm init`
and `kubeadm join` on nodes that are already part of the cluster.

`make up` first launches the VirtualBox Manager and brings it to the front (`make vbox` does
only that), so the `k8s-*` machines are visible as they boot and **Show** is one click away.
Only the desktop node (`cp1`) opens a window of its own; the other VMs start headless unless
`K8S_GUI` says otherwise (table below). `make up VBOX_APP=0` skips the app, for CI or an ssh
session with no display.

## Console and desktop
`make up` boots `k8s-cp1` with its VirtualBox window open. You land in the stock Ubuntu
desktop (GNOME Shell, the Ubuntu dock with Firefox, Files, App Center and Help, a Home
folder on the desktop) as `vagrant` (password `vagrant`, passwordless `sudo`) with a
terminal, a working `kubectl`, and a clipboard shared with the host. The Swagger UI for
the sample app is at `http://192.168.56.11:30080/docs`.

- Close the window with **Continue running in background**. **Power off** halts the node;
  recover with `vagrant up cp1`.
- The window opens only when the VM *boots*: `vagrant up` skips machines that are already
  running. If cp1 is running headless, open the VirtualBox app, select `k8s-cp1` and click
  **Show**, or `vagrant halt cp1` then `vagrant up cp1`. `K8S_GUI=0 make up` boots
  everything headless. The window can open behind other apps; look for VirtualBox in the Dock.
- Each VM has exactly one VirtualBox process, headless (`VBoxHeadless`) or windowed
  (`VirtualBoxVM`). `VBoxManage startvm k8s-cp1` on a running node therefore fails with
  "already locked by a session"; that is normal, use **Show** instead.
- To see what a headless VM's screen shows without opening a window:
  `VBoxManage controlvm k8s-cp1 screenshotpng cp1.png`.
- The screen is fixed at 1280x800 (VirtualBox's ARM64 display cannot resize).
- The desktop never locks or blanks; there is no screensaver password to remember.
- **Copy and paste with the Mac** works in both directions, but the keys differ inside the
  window. Left ⌘ is VirtualBox's *host key* (the badge at the bottom right says so), so
  ⌘C/⌘V never reach Ubuntu. Use **Ctrl+V** to paste in Firefox and other apps and
  **Ctrl+Shift+V** (or right-click, Paste) in the terminal; copy with Ctrl+C / Ctrl+Shift+C
  and then ⌘V on the Mac. If a paste does nothing, click inside the window first so it has
  focus. `wl-paste` in a VM terminal prints whatever is on the Mac clipboard, which is the
  quickest check that the link itself is fine. (The session is Wayland; GNOME 50 on 26.04
  has no Xorg session. Guest Additions' clipboard service attaches to XWayland and GNOME
  bridges it to Wayland apps.)
- `w1`, `w2` and `web` have a text console only: log in as `vagrant` / `vagrant` (the banner
  says so; press Enter if boot messages have scrolled over the prompt, and note the
  password does not echo as you type). `vagrant ssh <node>` is the everyday way in.
- Tunables (environment variables read by the Vagrantfile):

| Variable | Default | Effect |
|----------|---------|--------|
| `K8S_DESKTOP` | `cp1` | Node that gets the desktop, 4 GB RAM and 4 CPUs. `""` for none. |
| `K8S_BOX` | `bento/ubuntu-26.04` | Override the Vagrant box (Ubuntu 26.04 LTS; the same box serves amd64 and arm64 hosts). |
| `VBOX_APP` | `1` | `make up` opens the VirtualBox Manager first (macOS `open -a VirtualBox`; Linux when a display is present). `0` skips it. |
| `K8S_GUI` | `1` (desktop node windowed) | `0` boots every node headless, `all` opens a window for every node, `cp1,w1` for a list. A running headless node's window opens from the VirtualBox Manager (select it, Show). |

## The web edge
`web` is a plain VM outside Kubernetes running nginx, the way a load balancer or bastion
sits in front of a real cluster. It proxies `/` to the site NodePort (30081) and `/api/...`
to the API NodePort (30080) on every worker with failover, and serves HTTPS with a self-signed cert.

```bash
vagrant up web                                # only needed once; make up creates it too
open http://192.168.56.20/                    # landing page with links
curl -s http://192.168.56.20/api/healthz      # -> {"status":"ok","pod":...}
curl -sk https://192.168.56.20/api/notes
```
Roles are set in `NODES`: `control-plane` and `worker` get kubeadm; `web` gets only nginx.
Take it down with `vagrant halt web`; it has no effect on the cluster.

## The site (in-cluster nginx)
`web/` is a static site plus an nginx proxy to the API, built into `devapp/web:dev` and loaded
onto the workers exactly like the API image. `k8s/30-web.yaml` runs it as a 2-replica
Deployment on NodePort **30081**. It is the hardened counterpart of the API manifest: read-only
root filesystem, all capabilities dropped, seccomp, no service-account token, so it passes the
`restricted` Pod Security profile (`make sectest ROUTINE=07`).

```
http://192.168.56.11:30081/          site (any worker IP)
http://192.168.56.11:30081/api/notes proxied to the api Service inside the cluster
http://192.168.56.20/                same site through the edge VM
```

## Dev loop
1. Edit `app/main.py` (API) or `web/site/` (site)
2. `make image` (both images) or `make image IMAGES=web`
3. `kubectl -n devapp rollout restart deployment/api` (or `deployment/web`)

The Postgres `notes` table persists across API restarts via the PVC.
Nothing in the loop needs a VM restart: `kubectl apply`, `make storage`, `make image` and
`make deploy` all act on the running cluster. `make down` halts the VMs and keeps their
state; `make up` brings the cluster and its pods back as they were. Only `make clean`
tears everything down.

## Snapshots
Most exercises in [docs/learn.md](docs/learn.md) break something on purpose. Take a
VirtualBox snapshot of the whole lab once it works, and roll back in a minute instead of
re-provisioning for twenty:

```bash
make snapshot                 # saves "base" on every VM (running VMs are snapshotted live)
make snapshot SNAP=pre-calico # any name; the same name is overwritten
make restore                  # back to "base": VMs, cluster state and pods as they were
make restore SNAP=pre-calico
vagrant snapshot list
```

`kubeconfig` on the host stays valid across a restore (the cluster CA does not change). A
restore rolls back the VMs' disks, so images loaded with `make image` after the snapshot are
gone too; re-run it.

## Your first pod by hand
The app's pods come from Deployments in `k8s/`. To see the smallest unit on its own,
create one pod directly (no `make image` needed; it uses a public image):

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl run hello --image=nginxinc/nginx-unprivileged:alpine --port=8080
kubectl get pod hello -o wide          # Pending → ContainerCreating → Running, and which node
kubectl describe pod hello | tail -8   # events: scheduled, pulled, started
kubectl port-forward pod/hello 8080:8080   # then, in another terminal: curl -s localhost:8080
kubectl delete pod hello               # gone for good: nothing recreates a bare pod
```

That last line is why the manifests use Deployments. [docs/learn.md](docs/learn.md)
walks through the same thing with a full manifest and explains each field.

## API
| Method | Path      | Purpose                     |
|--------|-----------|-----------------------------|
| GET    | /healthz  | liveness                    |
| GET    | /readyz   | readiness (checks Postgres) |
| GET    | /notes    | list notes                  |
| POST   | /notes    | create note `{"text": "…"}` |

Swagger UI: `http://192.168.56.11:30080/docs`

## Layout
```
Vagrantfile                VM + node definitions (edit NODES to resize), desktop/console switches
scripts/common.sh          containerd, kubeadm, kubelet on every node
scripts/control-plane.sh   kubeadm init, Flannel, writes kubeconfig + join.sh (idempotent)
scripts/worker.sh          waits for join.sh, joins the cluster (idempotent)
scripts/web.sh             web role: nginx edge proxy to the API NodePorts (+ self-signed TLS)
scripts/console-banner.sh  every VM: login banner with credentials, quiet tty
scripts/desktop.sh         stock Ubuntu (GNOME) desktop + Firefox + auto-login on the desktop node
scripts/load-image.sh      build api + web images on host → import into workers (no registry)
scripts/gatekeeper.sh      install OPA Gatekeeper (pinned) and apply policy/ (make policy; `uninstall` removes it)
scripts/policy-test.sh     gator verify on policy/tests/suite.yaml, no cluster needed (make policy-test)
scripts/check.sh           ShellCheck, yamllint, kubeconform, Markdown link check (make check)
app/                       FastAPI service + Dockerfile
web/                       static site + nginx proxy config + Dockerfile
k8s/                       Namespace, Postgres StatefulSet, API Deployment + NodePort, web Deployment + NodePort
policy/                    Gatekeeper ConstraintTemplates (Rego) and Constraints for the lab's security posture
policy/examples/           course solutions: approved-registry policy + approved/unapproved test deployments (not applied by make policy)
policy/tests/              gator test suite + fixtures for every template (make policy-test)
docs/                      learn.md (layer-by-layer guide), course.md (30-lesson course with capstone), issues.md (known gaps, status)
security/                  Security test routines (make sectest); see security/README.md
```

## Policy (OPA Gatekeeper)
`make policy` installs [OPA Gatekeeper](https://github.com/open-policy-agent/gatekeeper)
(pinned release manifest, one controller replica to fit a 2 GB worker) and applies the
lab's own rules from `policy/`:

| Constraint | Action | Rule |
|------------|--------|------|
| `no-privilege` | deny | no `privileged` containers, no `hostPID`/`hostIPC`/`hostNetwork`, no `hostPath` volumes |
| `non-root` | warn | every container sets `runAsNonRoot: true` and `allowPrivilegeEscalation: false` |
| `resource-limits` | warn | every container has cpu and memory limits |

They match Pods and the workloads that create them (Deployment, StatefulSet, DaemonSet,
Job) in `devapp` and any `sec-*` namespace, so `default` stays a sandbox. `warn` is
deliberate: `k8s/10-postgres.yaml` has no securityContext and no limits, so `deny` would
break `make deploy`. Instead the violations print on every apply and in the audit:

```bash
kubectl apply -f k8s/10-postgres.yaml        # Warning: [non-root] ... [resource-limits] ...
kubectl get constraints -o wide              # TOTAL-VIOLATIONS per constraint (audit, every 60 s)
kubectl get k8slabnonroot non-root -o yaml | grep -A12 violations:
kubectl -n devapp apply -f security/policies/privileged-pod.yaml   # denied by no-privilege
```

The Rego in `policy/templates/` is short and commented; `policy/constraints/` sets the
scope and the action. `make policy-test` runs `policy/tests/suite.yaml` through
[gator](https://open-policy-agent.github.io/gatekeeper/website/docs/gator) without a
cluster: every template against the privileged pod, the lab's own workloads (extracted from
`k8s/` on each run) and a few edge cases, asserting the exact violation counts. Edit a
template, run the suite, then `make policy` to apply it. Fix postgres (non-root securityContext, limits, and `PGDATA` moved to a
subdirectory of the volume; exercise 19 in [docs/learn.md](docs/learn.md), lesson 18 in the
course), flip the two constraints to `deny`, and re-run `make sectest ROUTINE=10` to see the
gate close. Remove everything with `./scripts/gatekeeper.sh uninstall`.

`policy/examples/` holds a fourth, worked policy that `make policy` does not apply: an
approved-registry template and constraint (`K8sLabApprovedRegistry`, `warn`, allows
`cgr.dev/chainguard/`) with one approved and one unapproved Deployment to test it. It is the
reference solution for lessons 19–23 of [docs/course.md](docs/course.md); see
[policy/examples/README.md](policy/examples/README.md). `kubectl delete -f policy/examples/`
removes it.

## Security testing
```bash
make sectest                 # all routines: pod specs, runtime probe, RBAC, NetworkPolicy,
                             # secrets in etcd, Trivy, Pod Security Admission, kube-bench, exposure,
                             # Gatekeeper (skips until make policy has run)
make sectest ROUTINE=05      # just one
SKIP_SLOW=1 make sectest     # without Trivy and kube-bench
```
The stock lab fails several checks on purpose (plaintext `DATABASE_URL`, no NetworkPolicy
enforcement under Flannel, unencrypted etcd). [security/README.md](security/README.md) explains
each finding and how to fix it. Only ever point these at your own cluster.

## Notes & gotchas
- kubelet is pinned to `--node-ip` on the host-only NIC; VirtualBox's NAT interface gives
  every VM the same 10.0.2.15 address, which breaks pod networking otherwise.
- Flannel is likewise pinned via `--iface` to the interface that owns the node IP
  (`eth1`: the bento box boots with `net.ifnames=0`), resolved during
  provisioning. Its manifest comes from a release tag (`FLANNEL_VERSION` in the
  Vagrantfile), not `master`, like every other component the lab installs. If every node's `flannel.alpha.coreos.com/public-ip` annotation reads
  10.0.2.15, the pin is missing and cross-node pod traffic (including DNS) fails.
- Credentials in `k8s/10-postgres.yaml` are dev-only. For anything shared, move them
  to a sealed secret or external secrets store.
- `kubectl get pods` prints "No resources found in default namespace" even though the app
  is running: the app lives in the `devapp` namespace. Use `-n devapp`, `-A` for every
  namespace, or make it the default with
  `kubectl config set-context --current --namespace=devapp`.
- A worker missing from `kubectl get nodes` while its VM is running never joined (its
  kubelet has no `/etc/kubernetes/kubelet.conf`, typically because the control plane was
  re-initialised after the worker was provisioned). `vagrant provision <name> --provision-with worker`
  joins it live; no reboot.
- To add a worker, append to `NODES` in the Vagrantfile and run `vagrant up <name>`.
- `K8S_VERSION` (Vagrantfile) picks the pkgs.k8s.io minor. Changing it needs fresh VMs
  (`make clean`, then `make all`): the packages are held on existing nodes, and a live
  cluster is upgraded with `kubeadm upgrade`, not by reprovisioning.
- Known gaps and unverified claims are tracked in [docs/issues.md](docs/issues.md).
- Provisioners are named, so one step can be re-run on its own:
  `vagrant provision cp1 --provision-with control-plane`
  (others: `hosts`, `banner`, `common`, `worker`, `web`, `desktop`).
- Troubleshooting table: see [CLAUDE.md](CLAUDE.md).

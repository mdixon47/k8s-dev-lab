# Learning Guide: k8s-dev-lab

This lab exists to teach how a Kubernetes cluster is actually assembled and how a
stateful application runs on it. Nothing is hidden behind a managed service: you
watch three VMs boot, get bootstrapped into a cluster with `kubeadm`, and serve a
FastAPI + Postgres app. This guide explains *why* each piece is there and gives
exercises to try.

Read alongside [README.md](../README.md) (quick start) and [CLAUDE.md](../CLAUDE.md)
(conventions and troubleshooting). [course.md](course.md) turns the same material into a
30-lesson course with a security capstone; this guide is its reference text.

---

## 1. The big picture

```
┌──────────────────────── host (macOS / Linux) ────────────────────────┐
│  vagrant up ──▶ VirtualBox                                           │
│  docker build ──▶ devapp/api:dev, devapp/web:dev ──▶ ctr import      │
│  kubectl (KUBECONFIG=./kubeconfig) ──▶ https://192.168.56.10:6443    │
│                                                                      │
│   ┌──────── cp1 ────────┐  ┌──────── w1 ────────┐  ┌──── w2 ────┐    │
│   │ kube-apiserver      │  │ kubelet            │  │ kubelet    │    │
│   │ etcd, scheduler,    │  │ containerd         │  │ containerd │    │
│   │ controller-manager  │  │ flannel, kube-proxy│  │ flannel    │    │
│   │ kubelet, flannel    │  │ api pod  postgres  │  │ api pod    │    │
│   │ GNOME desktop (opt.)│  │ web pod            │  │ web pod    │    │
│   └─────────────────────┘  └────────────────────┘  └────────────┘    │
│        192.168.56.10            192.168.56.11         192.168.56.12  │
│                                                                      │
│   web 192.168.56.20 (not a cluster node): nginx edge ──▶ NodePorts   │
│   30081 (site) and 30080 (api) on w1 and w2                          │
└──────────────────────────────────────────────────────────────────────┘
```

Layers, bottom to top:

| Layer | Tool | Files |
|-------|------|-------|
| Virtual machines | Vagrant + VirtualBox | `Vagrantfile` |
| Node preparation | bash provisioning | `scripts/common.sh` |
| Cluster bootstrap | kubeadm | `scripts/control-plane.sh`, `scripts/worker.sh` |
| Pod networking | Flannel (CNI) | applied in `control-plane.sh` |
| Storage | local-path-provisioner | `make storage` |
| Image distribution | docker save → ctr import | `scripts/load-image.sh` |
| Application | FastAPI + Postgres, nginx static site | `app/`, `web/`, `k8s/` |
| Edge (outside the cluster) | nginx reverse proxy VM | `scripts/web.sh` |
| Console & desktop (optional) | Guest Additions, Ubuntu (GNOME) desktop | `scripts/desktop.sh` |
| Admission policy (optional) | OPA Gatekeeper, ConstraintTemplates, Constraints | `scripts/gatekeeper.sh`, `policy/` |

---

## 2. Layer by layer

### 2.1 Virtual machines (`Vagrantfile`)

- `NODES` is the single source of truth for the cluster shape: name, IP, CPUs, RAM, role.
- Each VM gets **two NICs**. VirtualBox always adds a NAT adapter (internet access), and
  `private_network` adds a host-only adapter on `192.168.56.0/24` so the VMs and the host
  can reach each other by fixed IP.
- The box is `bento/ubuntu-26.04` (Ubuntu 26.04 LTS, Linux 7.0) on every host. Canonical
  stopped publishing official Vagrant boxes after 22.04; bento ships VirtualBox builds for
  both amd64 and arm64, so Apple Silicon hosts need no special case.
- The synced folder `/vagrant` mirrors the repo inside every VM. This is how the control
  plane hands `kubeconfig` and `join.sh` to the host and to the workers with no extra tooling.
  It is backed by the `vboxsf` kernel module from VirtualBox Guest Additions, which matters
  in section 2.7.
- The host-only interface is `eth1`: the bento box boots with `net.ifnames=0`, so NICs keep
  classic names instead of `enp0s8`. The scripts never hard-code it; they look up which
  interface owns `NODE_IP`, so a different box still works.
- `role` decides what a VM becomes. `control-plane` and `worker` are kubeadm nodes; `web` is a
  plain nginx box outside the cluster that proxies to the API's NodePort, the way a load balancer
  or bastion sits in front of a real cluster. It exists so you can practise the edge: TLS, headers,
  failover when a worker dies, and what an attacker on the LAN sees first.
- One node (`DESKTOP_NODE`, default `cp1`) is sized up to 4 GB / 4 CPUs and gets a desktop.
  Three environment variables (`K8S_DESKTOP`, `K8S_BOX`, `K8S_GUI`) tune this without editing
  the file; see the README.

**Concept: the NAT trap.** Every VM's NAT interface has the *same* address, 10.0.2.15.
If kubelet or Flannel picks that interface, nodes cannot talk to each other. The lab
pins both to the host-only IP. This is the most common reason DIY clusters "look
healthy but pods can't reach each other".

### 2.2 Node preparation (`scripts/common.sh`)

Runs identically on all three nodes. Each block answers a kubeadm preflight check:

| Step | Why |
|------|-----|
| `overlay`, `br_netfilter` modules | containerd uses overlayfs; bridge traffic must pass through iptables for Services to work |
| `net.ipv4.ip_forward=1` | nodes route pod traffic |
| `swapoff -a` + comment the fstab line | kubelet refuses to start with swap on (memory accounting). `swapoff` alone is not enough: swap returns on reboot unless `/etc/fstab` is edited too, and the bento box writes that line tab-separated, so the pattern must match any whitespace |
| containerd with `SystemdCgroup = true` | kubelet and the runtime must agree on the cgroup driver; Ubuntu uses systemd |
| `pkgs.k8s.io` repo pinned to `v${K8S_VERSION}` | one minor version per repo; changing `K8S_VERSION` in the Vagrantfile is enough |
| `apt-mark hold` | prevents an unattended upgrade from skewing versions between nodes |
| `--node-ip=${NODE_IP}` in `/etc/default/kubelet` | the NAT trap fix for kubelet |

### 2.3 Cluster bootstrap (`scripts/control-plane.sh`, `scripts/worker.sh`)

`kubeadm init` on cp1:
1. Generates the CA and certificates.
2. Writes static-pod manifests for etcd, apiserver, scheduler, controller-manager into
   `/etc/kubernetes/manifests/`. kubelet notices them and starts them without any
   scheduler involvement. This is why the control plane can bootstrap itself.
3. Produces `admin.conf`, copied to `/vagrant/kubeconfig` for the host.

Flannel is then applied with `--iface` set to the host-only interface (resolved from
`NODE_IP`). The manifest is fetched from the release tag in `FLANNEL_VERSION` (Vagrantfile)
rather than `master`, so two clones a month apart get the same CNI. Until a CNI is running,
every node stays `NotReady`. That is expected.

The `--iface` flag is injected into the upstream manifest with `sed`, and the script refuses
to apply the manifest if the flag did not land. That guard exists because upstream once
changed the args from a JSON-style list to a YAML list, the `sed` silently matched nothing,
and the cluster came up *looking* healthy: nodes Ready, Flannel pods Running, but every node
advertised 10.0.2.15 and pods on w1 could not reach CoreDNS on cp1. The tell is
`kubectl get nodes -o custom-columns='NAME:.metadata.name,IP:.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip'`.

**Idempotency.** Both scripts check for an existing cluster (`/etc/kubernetes/admin.conf` on
the control plane, `kubelet.conf` on workers) and skip `kubeadm init`/`join` if present, so
`vagrant provision` can be re-run to refresh Flannel, the kubeconfig copy, or the join token.
Without that check, kubeadm's preflight fails with "Port 6443 is in use" and
"/var/lib/etcd is not empty", which is kubeadm telling you the node is already initialized.

Finally `kubeadm token create --print-join-command` writes `join.sh`. Workers poll for
that file (up to five minutes), wait for the API server it names to answer, and run it,
retrying up to three times: a control plane that reboots mid-join (a "Power off" from its
window) once left a worker out of the cluster for days because nothing tried again. Join tokens expire after 24 hours; if you add a
worker much later, regenerate one with `vagrant ssh cp1 -c "sudo kubeadm token create --print-join-command"`.

**Try it:** inside cp1, `ls /etc/kubernetes/manifests` and `kubectl -n kube-system get pods -o wide`.
Match the static pods to the files.

### 2.4 Storage (`make storage`)

Bare kubeadm clusters have **no StorageClass**, so any PVC sits `Pending` forever.
`local-path-provisioner` creates a hostPath directory on whichever node the pod lands and
binds the PVC to it. Marking it default lets the Postgres PVC omit `storageClassName`.

Consequence worth understanding: the volume lives on one node. If that node dies, the
data is gone, and the pod cannot be rescheduled elsewhere. That is fine for a lab and
exactly the reason production clusters use networked or cloud block storage.

### 2.5 Image distribution (`scripts/load-image.sh`)

There is no registry. Each image (`devapp/api:dev` from `app/`, `devapp/web:dev` from `web/`)
is built on the host, saved to a tarball in the synced folder, and imported straight into
containerd's `k8s.io` namespace on each worker.

Two details that trip people up:
- The `k8s.io` namespace matters. `ctr images ls` with no `-n` shows a different namespace,
  and kubelet only sees images in `k8s.io`.
- The manifest uses `imagePullPolicy: IfNotPresent` with a fixed tag. Because the tag never
  changes, a Deployment update does nothing; you must `rollout restart` after each reload.

### 2.6 The application (`app/`, `k8s/`)

`app/main.py` is deliberately small so the Kubernetes behaviour is what you study:

| Endpoint | Kubernetes role |
|----------|-----------------|
| `/healthz` | liveness probe. Returns the pod's hostname so you can see load balancing across replicas |
| `/readyz` | readiness probe. Runs `SELECT 1`; returns 503 until Postgres is reachable, so traffic is withheld until the pod can serve |
| `/notes` | proves persistence: data survives API restarts because it lives in the Postgres PVC |

Manifest walk-through:

- `00-namespace.yaml`: everything lives in `devapp`. Numbered prefixes give `kubectl apply -f k8s/` a deterministic order.
- `10-postgres.yaml`: **Secret** (env injection via `envFrom`), **PVC**, **StatefulSet**
  (stable pod name `postgres-0`, ordered restarts), **ClusterIP Service** (DNS name
  `postgres.devapp.svc.cluster.local`). A StatefulSet rather than a Deployment because the
  database must never have two pods writing the same volume during a rollout.
- `20-api.yaml`: **Deployment** with 2 replicas (stateless, safe to roll), resource requests
  and limits, both probes, a non-root `securityContext`, and a **NodePort Service** on 30080.
  NodePort opens the port on *every* node, which is why `make test` can hit w1 even though
  a pod may be on w2.
- `30-web.yaml`: the static site as an nginx **Deployment** on NodePort 30081, proxying `/api/`
  to the `api` Service by its DNS name. Read it next to `20-api.yaml`: it is what the API
  manifest would look like fully hardened (read-only root filesystem with `emptyDir` scratch
  space, `capabilities.drop: [ALL]`, `seccompProfile`, `automountServiceAccountToken: false`).
  `make sectest ROUTINE=07` shows one passing `restricted` and the other not.

### 2.7 Console and desktop (`scripts/desktop.sh`)

This layer is optional for the cluster but a good lesson in how firmware, kernel drivers,
and hypervisor tooling fit together.

**How the console gets a picture.** On Apple Silicon, VirtualBox gives ARM64 guests a very
simple display device (QEMU's `ramfb`) and boots them with EFI. The firmware sets up a
framebuffer and hands its address to the kernel, and the kernel needs a driver that can
take that framebuffer over after "EFI stub: Exiting boot services". That driver is
`simpledrm`, and Ubuntu 26.04's 7.0 kernel ships it, so the console window shows boot
messages and a login prompt with no extra work. Inside the guest, `ls /dev/dri` shows the
device and `dmesg | grep -i simple` shows the driver claiming the EFI framebuffer.

**Why this used to be hard.** Ubuntu 22.04's 5.15 kernel had no such driver, so the window
froze at the EFI stub line while the OS was fully up and SSH worked. The workaround was to
install a newer HWE kernel, which then broke two more things: VirtualBox Guest Additions
(`vboxsf` for `/vagrant`, `vboxguest` for the clipboard) are kernel modules built per
kernel and had to be rebuilt with `rcvboxadd quicksetup <version>`, and a header mismatch
between the Additions and the backported kernel needed a patch before they would compile.
Moving the lab to 26.04 removed all of that. The lesson stands: any kernel change in a
VirtualBox guest means rebuilding the Additions, and `/vagrant` disappearing after a kernel
upgrade is the symptom (see the troubleshooting table in CLAUDE.md).

**The desktop.** `desktop.sh` installs the stock Ubuntu desktop (`ubuntu-desktop-minimal`:
GNOME Shell, the Ubuntu dock, Firefox, App Center) and GDM with auto-login as `vagrant` (a
Wayland session; Guest Additions' clipboard service attaches to XWayland and mutter bridges it
to Wayland apps), then runs Guest Additions' X11 setup so that clipboard service autostarts
with the session. Copy/paste with the Mac then works both ways, with one catch: Left ⌘ is
VirtualBox's host key, so ⌘V is swallowed by VirtualBox. Inside the window it is Ctrl+V in
apps and Ctrl+Shift+V in the terminal; `wl-paste` prints the Mac clipboard if you want
proof the link works. One more trap:
when the VirtualBox window opens it sends a "resize to fit" hint, the Guest Additions
display service tries to honour it, `ramfb` cannot change mode, and the only output is
left *disabled*: a black screen behind a running desktop. The script stops that service at
login and re-enables the output, and the VM is configured not to send the hint at all.

**Headless or windowed.** Vagrant starts every VM with `VBoxManage startvm --type headless`,
so the guest runs and renders its framebuffer with no window on the Mac. A VirtualBox VM
is always exactly one host process, `VBoxHeadless` or `VirtualBoxVM`, and that process
holds the machine's session lock. Two consequences: `VBoxManage startvm` against a
running node fails with "already locked by a session" (nothing is wrong, the lock is
doing its job), and the Manager's **Show** button does not start anything, it attaches a
window to the process that already exists. For the desktop node Vagrant passes `--type gui`
instead (`K8S_GUI=1`, the default; `K8S_GUI=0` for headless), but only for machines it actually boots; `vagrant up` leaves running VMs alone.
The frontend is not remembered: a node started headless stays headless until its next boot.

**Try it:** `VBoxManage showvminfo k8s-cp1 --machinereadable | grep SessionName` says
`headless` or `GUI/Qt`. `VBoxManage controlvm k8s-cp1 screenshotpng cp1.png` captures the
guest's screen either way, which is the quickest proof that a "blank" VM is rendering fine.
On cp1, `cat /sys/class/drm/card0-*/enabled` and `xrandr` from a desktop
terminal. Then `vagrant ssh cp1` and run `uname -r` (7.0) and `lsmod | grep vboxsf` to see
the kernel and the Guest Additions module that backs `/vagrant`.

### 2.8 Admission policy (`scripts/gatekeeper.sh`, `policy/`)

Everything so far *describes* a secure posture (non-root, no privilege escalation, limits)
and `security/01-pod-spec-audit.sh` checks it after the fact. Nothing stops someone from
applying a privileged pod. `make policy` adds the missing enforcement layer:
[OPA Gatekeeper](https://github.com/open-policy-agent/gatekeeper), a **validating
admission webhook**. Every create or update goes API server → authentication → authorization
→ admission → etcd; Gatekeeper sits in the admission step and can reject the request, warn,
or just record it.

**Three objects.** A `ConstraintTemplate` (`policy/templates/`) holds the rule, written in
Rego, and declares a new CRD kind such as `K8sLabNoPrivilege`. A `Constraint`
(`policy/constraints/`) is an instance of that kind: it says *where* the rule applies
(`match.namespaces: [devapp, sec-*]`, which kinds) and *how hard* (`enforcementAction`:
`deny`, `warn`, or `dryrun`). Gatekeeper's `audit` deployment re-evaluates every constraint
against what already exists every 60 s and writes the results to the constraint's
`status.violations`, which is how you find the pods that were admitted before the rule existed.

**Why two of the three constraints only warn.** `k8s/10-postgres.yaml` has no
`securityContext` and no limits. With `deny`, `make deploy` on a fresh clone would fail at
the StatefulSet. With `warn`, the apply succeeds, `kubectl` prints a `Warning:` line per
violation, and the audit counts it. That is the normal rollout path for a new policy in a
real cluster: `dryrun` → `warn` → fix the offenders → `deny`.

**Try it:** `make policy`, then

```bash
kubectl get constraints -o wide                     # ENFORCEMENT-ACTION, TOTAL-VIOLATIONS
kubectl -n devapp apply -f security/policies/privileged-pod.yaml   # denied: four [no-privilege] reasons (+ [non-root] warnings)
kubectl apply -f security/policies/privileged-pod.yaml             # default namespace: admitted!
kubectl delete pod sec-test-privileged
kubectl get k8slabnonroot non-root -o jsonpath='{.status.violations}' | jq .
```

Read `policy/templates/10-no-privilege.yaml`: each `violation[...]` block is one rule, and
`pod_spec` picks `spec` or `spec.template.spec` depending on the kind, which is why applying
the StatefulSet itself warns, not only the pod it creates.

**Testing Rego without a cluster.** `make policy-test` runs `policy/tests/suite.yaml` through
Gatekeeper's `gator verify`: each template and constraint pair is evaluated against fixture
objects (the privileged pod, the lab's own workloads extracted from `k8s/`, a pod that sets
`runAsNonRoot` at pod level) and the suite asserts the exact number of violations, with
optional message matching. It is the fast loop for policy work: change a template, run the
suite in a second, and only then `make policy`. The counts in the suite are also the answer
key for several exercises below (postgres: 2 non-root and 2 resource-limits violations).

**A fourth policy, worked.** `policy/examples/` holds an approved-registry template and
constraint (`K8sLabApprovedRegistry`, parameter `allowedRegistries`, `warn`, same namespaces)
plus an approved (`cgr.dev/chainguard/nginx`) and an unapproved Deployment to test it. It is
the reference solution for lessons 19–23 of [course.md](course.md), and the first template
here that takes parameters. `make policy` does not apply it; follow
[policy/examples/README.md](../policy/examples/README.md), and remove it with
`kubectl delete -f policy/examples/`. The approved image is distroless, so `kubectl exec`
into it finds no shell.

---

## 3. Guided walkthrough

Do these in order on a fresh clone and observe the cluster state changing.

```bash
make up                       # 15-20 min. Opens the VirtualBox app and cp1's window;
                              # kubeadm's output scrolls in this terminal.
                              # (`make all` chains every step below; do them by hand this once.)
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes             # all Ready once Flannel is up
kubectl -n kube-flannel get pods -o wide
kubectl get pods              # "No resources found in default namespace": nothing deployed yet
```

**A pod by hand, before the app.** A pod is one or more containers sharing a network
namespace and an IP; it is the unit the scheduler places and the kubelet runs. Create one
directly, with the same security posture the app's manifests use (non-root, no privilege
escalation, resource limits) and a public image so no `make image` is needed:

```bash
cat > hello-pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: hello
  labels:
    app: hello
spec:
  containers:
    - name: web
      image: nginxinc/nginx-unprivileged:alpine
      ports:
        - containerPort: 8080
      resources:
        requests: { cpu: 50m, memory: 32Mi }
        limits:   { cpu: 200m, memory: 64Mi }
      securityContext:
        runAsNonRoot: true
        allowPrivilegeEscalation: false
EOF
kubectl apply -f hello-pod.yaml
kubectl get pod hello -w      # Pending (scheduling) → ContainerCreating (image pull) → Running
kubectl get pod hello -o wide # the node it landed on and its 10.244.x.x pod IP
kubectl describe pod hello    # Events at the bottom explain any stall
kubectl logs hello
kubectl exec -it hello -- sh  # a shell inside the container; `exit` to leave
kubectl port-forward pod/hello 8080:8080   # then curl localhost:8080 from another terminal
kubectl delete pod hello
kubectl get pods              # gone; nothing recreates a bare pod
```

That last observation is the whole reason `k8s/20-api.yaml` wraps the same kind of pod
spec in a Deployment: a Deployment owns a ReplicaSet, which keeps the requested number of
pods alive and replaces any that die. Compare its `template:` block with the manifest above.
Now deploy the app:

```bash
make deploy                   # deliberately BEFORE storage; the postgres rollout wait
                              # fails after ROLLOUT_TIMEOUT (180 s), which is the point
kubectl -n devapp get pvc     # Pending
kubectl -n devapp describe pvc postgres-data | tail -5   # "no storage class"
make storage
kubectl -n devapp get pvc -w  # flips to Bound

kubectl -n devapp get pods    # api and web pods: ErrImageNeverPull or ImagePullBackOff
make image
kubectl -n devapp rollout restart deployment/api deployment/web
kubectl -n devapp get pods -w # api and web pods reach Running; api is READY 1/1 once /readyz passes
kubectl config set-context --current --namespace=devapp   # optional: stop typing -n devapp

make test
for i in 1 2 3 4; do curl -s 192.168.56.11:30080/healthz; echo; done   # pod name alternates

make policy                   # Gatekeeper + policy/; ~1 min for the image pull
kubectl -n devapp apply -f security/policies/privileged-pod.yaml   # denied by [no-privilege]
kubectl apply -f k8s/10-postgres.yaml                              # unchanged, so no admission call;
kubectl -n devapp rollout restart statefulset/postgres              # ...but the new pod is warned about
kubectl get constraints -o wide                                    # postgres shows up in TOTAL-VIOLATIONS
make sectest ROUTINE=10       # the routine proves deny, warn and audit in one run

vagrant provision cp1         # safe re-run: "already initialized; skipping kubeadm init"
```

cp1's VirtualBox window opened when it booted (if you closed it, open the VirtualBox app,
select `k8s-cp1`, click **Show**). In the Ubuntu desktop:

- Open Firefox at `http://192.168.56.11:30080/docs` and POST a note from the Swagger UI.
- Open a terminal and run `kubectl -n devapp get pods -o wide`; the node has admin access
  through `~/.kube/config`.
- Paste something from your Mac into the terminal (Ctrl+Shift+V, not ⌘V) to confirm the
  shared clipboard.
- Note nothing above needed a VM restart. Kubernetes changes apply to the running cluster;
  `make down` / `make up` halts and resumes the VMs with their state intact.

---

## 4. Exercises

Each exercise is designed to break something you can then diagnose with the
troubleshooting table in `CLAUDE.md`. Take `make snapshot` first; `make restore` then
undoes any of them in about a minute, VMs and cluster state included.

1. **Persistence.** POST a note, `kubectl -n devapp delete pod postgres-0`, wait, GET notes.
   The note is still there. Then delete the PVC and pod together and confirm it is gone.
2. **Readiness in action.** `kubectl -n devapp scale statefulset/postgres --replicas=0`, then
   `kubectl -n devapp get endpoints api`. The API pods drop out of the endpoints list because
   `/readyz` fails, and `curl` to 30080 gets connection refused rather than a 503. Scale back up.
3. **Scheduling.** `kubectl -n devapp get pods -o wide`. Cordon the node hosting one API pod
   (`kubectl cordon w2`), delete that pod, and watch it land on w1. Uncordon afterwards.
4. **Resource limits.** Lower the API memory limit to `32Mi` in `20-api.yaml`, apply, and watch
   pods get `OOMKilled`. Revert.
5. **Dev loop.** Add a `DELETE /notes/{id}` endpoint in `app/main.py`, `make image`,
   `rollout restart`, and test it through the NodePort.
6. **Add a worker.** Append `w3` at `192.168.56.13` to `NODES`, add it to the loop in
   `load-image.sh`, run `vagrant up w3`. If the join token has expired, regenerate it (see 2.3).
7. **Break networking on purpose.** In a VM, `sudo ip link set eth1 down` (check `ip -o -4 addr`
   for the interface with the 192.168.56 address). Watch the node go `NotReady` and pods
   on it become unreachable. Bring it back up.
8. **Read the control plane.** `vagrant ssh cp1`, then `sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml`.
   Find the `--advertise-address` and `--service-cluster-ip-range` flags and relate them to
   the Vagrantfile and `POD_CIDR`.
9. **The NAT trap, live.** Remove the pin: `kubectl -n kube-flannel edit ds kube-flannel-ds`
   and delete the `--iface=...` arg. Wait for the Flannel pods to roll, then check the
   `public-ip` annotation on each node (see 2.3) and run
   `kubectl -n devapp run dns --rm -it --image=busybox:1.36 -- nslookup postgres.devapp`.
   Nodes stay Ready while DNS times out. Restore with
   `vagrant provision cp1 --provision-with control-plane` (re-applies Flannel without rebooting).
10. **Re-provision without fear.** Run `vagrant provision` and read the output: which steps
    say "already ...; skipping", which re-run anyway (apt, Flannel apply, join token), and
    why is that safe?
11. **Swap on reboot.** On w1, uncomment the `/swap.img` line in `/etc/fstab`, `vagrant reload w1`,
    and read `journalctl -u kubelet`. Fix it by hand, then compare with what `common.sh` does.
12. **Kill the desktop's display.** In a cp1 desktop terminal, `xrandr --output None-1 --off`.
    The window goes black while the session keeps running. Bring it back with
    `xrandr --output None-1 --auto`, then read `/usr/local/bin/vbox-display-fix`.
13. **Power off from the window, on purpose.** Close w2's console window with "Power off".
    Watch `kubectl get nodes` mark it NotReady after about 40 s, see which pods were on it,
    then `vagrant up w2` and watch them come back.
14. **One process per VM.** With cp1 running, run `VBoxManage startvm k8s-cp1 --type gui`
    and read the "already locked" error. Then `vagrant halt cp1`, `K8S_GUI=0 vagrant up cp1`
    (headless), and compare `VBoxManage showvminfo k8s-cp1 --machinereadable | grep SessionName`
    with the windowed boot. Finally run `make up` with everything already running and explain
    why no window appears.
15. **Pod vs Deployment.** Create the bare `hello` pod from the walkthrough, then delete it
    and one of the app's pods at the same time: `kubectl delete pod hello` and
    `kubectl -n devapp delete pod -l app=api --wait=false`. Watch `kubectl get pods -A -w`.
    Explain which pods come back, who brings them back, and why the new api pods have new names.
16. **Rejoin a worker.** `vagrant ssh w1 -c 'sudo kubeadm reset -f'`, watch `kubectl get nodes`
    mark w1 NotReady, then `vagrant provision w1 --provision-with worker` and watch it come
    back. The join script in `join.sh` carries a token with a 24 h lifetime;
    `kubeadm token create --print-join-command` on cp1 mints a fresh one when it has expired.

17. **Failover at the edge.** `watch curl -s http://192.168.56.20/api/healthz` (the pod name
    alternates), then `vagrant halt w2`. Requests keep succeeding via w1; nginx marks the dead
    upstream after two failures. `vagrant up w2` and watch it return to rotation.
18. **Inspect the edge.** `curl -skI https://192.168.56.20/` and read the headers nginx adds.
    Then `openssl s_client -connect 192.168.56.20:443 </dev/null | head` to see why your browser
    warns: the cert is self-signed. Replace it with one from a local CA you create with openssl.
19. **Close the gate.** Give `k8s/10-postgres.yaml` a pod `securityContext` (`runAsUser: 70`,
    `runAsGroup: 70`, `fsGroup: 70`, `runAsNonRoot: true`), `allowPrivilegeEscalation: false`
    and cpu/memory limits on the container, plus `env: [{name: PGDATA, value: /var/lib/postgresql/data/pgdata}]`.
    Without that last one Postgres crash-loops: local-path creates the volume directory as
    root, `fsGroup` does not apply to hostPath volumes, and `initdb` as uid 70 cannot chmod
    it; a subdirectory it creates itself works. (Existing data at the volume root is left
    behind; the lab's notes are disposable.) `make deploy`, wait for
    `kubectl get constraints -o wide` to show 0 violations, then change `enforcementAction`
    to `deny` in `policy/constraints/20-non-root.yaml` and `30-resource-limits.yaml`,
    `kubectl apply -f policy/constraints/`, and re-run `make sectest ROUTINE=10`.
20. **Write a constraint.** Add a template that rejects images without a tag or with
    `:latest` (hint: `endswith(c.image, ":latest")` and `not contains(c.image, ":")`), a
    `warn` constraint for it, and a test for each in `policy/tests/suite.yaml` before you
    apply them (`make policy-test`). Which of the lab's images trips it? (Mind
    digests: `image@sha256:...` has a colon but no tag.) `policy/examples/registry-template.yaml`
    is a worked template to model it on, and its approved Deployment uses `:latest`, so the two
    policies disagree about it; course lesson 28 picks that up.
21. **Kill the gatekeeper.** `kubectl -n gatekeeper-system scale deploy gatekeeper-controller-manager --replicas=0`,
    apply the privileged pod in `devapp`, and explain why it went through
    (`kubectl get validatingwebhookconfiguration gatekeeper-validating-webhook-configuration -o yaml | grep failurePolicy`).
    Scale it back to 1 and delete the pod.

---

## 5. Mental model checklist

You have understood the lab when you can answer these without looking:

- Why does `kubectl get nodes` show `NotReady` right after `kubeadm init`?
- Why is the node IP pinned, and what breaks if it is not?
- Why does the Postgres PVC stay `Pending` before `make storage`?
- Why does changing `app/main.py` and running `make image` not change the running pods?
- Why is Postgres a StatefulSet but the API a Deployment?
- Why can you reach the API on w1's IP even when both API pods are on w2?
- What is in `join.sh`, and why does it stop working after a day?
- Nodes are Ready and Flannel pods are Running, but pods cannot resolve DNS across nodes.
  What single `kubectl` command exposes the cause?
- Why can `vagrant provision` be re-run on a live cluster, and which two files make that decision?
- Why did the VM console show only EFI messages on Ubuntu 22.04's stock kernel while SSH
  worked fine, and what does the 26.04 kernel have that fixes it?
- What breaks when you change a VM's kernel, and why does `/vagrant` depend on it?
- Why does `VBoxManage startvm` on a running node say "already locked", and why does
  `make up` open no window when the VMs are already up?
- Why does `kubectl get pods` show nothing while `make status` shows five running pods?
- What happens to a pod created with `kubectl run` or a `kind: Pod` manifest when it dies,
  and what does a Deployment add?
- Why does ⌘V do nothing inside the VM window, and what does Ctrl+Shift+V do that Ctrl+V does not?
- Where in the request path does Gatekeeper sit, and why can it not do anything about a pod
  that was created before the constraint existed? What can?
- What is the difference between a ConstraintTemplate and a Constraint, and why does the lab
  ship two of its constraints as `warn` rather than `deny`?
- Why does Postgres crash-loop as uid 70 on a local-path volume until `PGDATA` points at a
  subdirectory, and why does `fsGroup` not help?

---

## 6. Where to go next

- Replace `ctr import` with a local registry (`registry:2` as a Deployment plus a NodePort) and
  switch the manifest to a versioned tag. Then rolling updates work without `rollout restart`.
- Swap Flannel for Calico to get NetworkPolicy and write a policy that only lets `api` reach `postgres`.
- Move the plaintext Secret to Sealed Secrets or External Secrets.
- Install an Ingress controller (ingress-nginx via NodePort) and expose the API on a hostname.
- Add a second control-plane node and a load balancer to see why HA needs a stable endpoint.
- Run `make sectest` and work through [security/README.md](../security/README.md): ten routines
  that audit pod specs, probe from inside a container, check RBAC, prove Flannel ignores
  NetworkPolicy, read a Secret straight out of etcd, scan images, test Pod Security Admission,
  run the CIS benchmark, map what the nodes expose on the LAN, and exercise Gatekeeper.
  Each finding is a hardening exercise.
- Port the Rego templates in `policy/` to Gatekeeper's CEL engine (`K8sNativeValidation`) or
  to a plain Kubernetes `ValidatingAdmissionPolicy`, which needs no webhook at all, and compare.

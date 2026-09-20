# Getting Started with Kubernetes

## Complete Hands-On Learning Series

Every command in this course was run against this repository's lab. Where the lab
differs from the general case, a **Lab note** says so. Read it alongside
[README.md](../README.md) (quick start), [learn.md](learn.md) (the why behind each
layer) and [CLAUDE.md](../CLAUDE.md) (conventions and troubleshooting).

## Course Overview

This series teaches Kubernetes by building, operating, breaking, securing, and repairing a real cluster.

Instead of hiding infrastructure behind a managed Kubernetes service, the lab exposes the individual components. Learners work with virtual machines, Linux configuration, `kubeadm`, containerd, Flannel, Kubernetes workloads, persistent storage, networking, OPA Gatekeeper, and admission-control policies.

The application environment consists of a FastAPI application backed by PostgreSQL running across a multi-node Kubernetes cluster, with an nginx edge VM in front of it.

The course is divided into two major sections:

### Part 1 — Kubernetes Foundations and Operations

Build the cluster and understand how Kubernetes actually works.

### Part 2 — Kubernetes Security and Policy Enforcement

Move beyond deployment into admission control, OPA Gatekeeper, trusted container sources, security policy, and troubleshooting.

---

# Course Architecture

```text
Developer / Administrator
          │
          ▼
      kubectl
          │
          ▼
 Kubernetes API Server
          │
          ├── Authentication
          │
          ├── Authorization
          │
          ├── Admission Control
          │       │
          │       ▼
          │   OPA Gatekeeper
          │
          ▼
         etcd
          │
          ▼
      Scheduler
          │
          ▼
       Kubelet
          │
          ▼
      containerd
          │
          ▼
         Pods
       ┌─────┐
       │ API │
       └──┬──┘
          │
          ▼
     PostgreSQL
          │
          ▼
   Persistent Storage
```

Underlying the cluster:

```text
Host Computer
     │
     ▼
   Vagrant
     │
     ▼
 VirtualBox
     │
 ┌───┴───────────────┬──────────────┐
 │                   │              │
cp1                  Workers        web
Control Plane        w1 / w2        nginx edge (not a cluster member)
```

**Lab note.** `web` (192.168.56.20) is a plain VM running nginx as a reverse proxy to the
workers' NodePorts. It is part of the lab but not of the Kubernetes cluster, so it never
appears in `kubectl get nodes`.

---

# PART 1

# Kubernetes Foundations and Operations

---

# Lesson 1 — Understanding the Kubernetes Lab

## Objective

Understand the overall architecture before working with individual Kubernetes components.

By the end of this lesson, learners should understand:

* the purpose of the control plane
* the role of worker nodes
* the relationship between Vagrant and VirtualBox
* how Linux hosts Kubernetes
* how containerd runs containers
* how kubeadm builds the cluster
* how Flannel connects pods
* where FastAPI and PostgreSQL run

## Lab Architecture

```text
Host
 │
 ├── cp1 — 192.168.56.10
 │     Kubernetes control plane (also gets the Ubuntu desktop)
 │
 ├── w1 — 192.168.56.11
 │     Kubernetes worker
 │
 ├── w2 — 192.168.56.12
 │     Kubernetes worker
 │
 └── web — 192.168.56.20
       nginx edge, outside the cluster
```

The control plane runs components such as:

```text
kube-apiserver
etcd
scheduler
controller-manager
kubelet
kube-proxy
Flannel
```

Workers run components such as:

```text
kubelet
containerd
kube-proxy
Flannel
application pods
```

## Lab

Start the environment:

```bash
make up
```

**Lab note.** `make up` is `vagrant up` plus opening the VirtualBox app; cp1's window opens
by itself and lands in an Ubuntu desktop. The first run takes 15–20 minutes. `make all`
runs this and every deploy step in one go, but do them by hand in this course.

Configure kubectl on your host:

```bash
export KUBECONFIG="$PWD/kubeconfig"
```

Inspect the cluster:

```bash
kubectl get nodes
```

Then:

```bash
kubectl get pods -A
```

Identify:

```text
cp1
w1
w2
```

(`web` is absent by design.) Inside cp1 the `vagrant` user already has a working
`kubectl`, so every command in this course also works from a terminal in the VM window.

## Exercise

Draw the following path in your own words:

```text
Laptop
  ↓
Vagrant
  ↓
VirtualBox
  ↓
Linux VM
  ↓
containerd
  ↓
Kubernetes
  ↓
Pod
  ↓
Application
```

## Knowledge Check

What does Kubernetes provide that VirtualBox does not?

---

# Lesson 2 — Virtual Machines and Cluster Networking

## Objective

Understand the network supporting the Kubernetes cluster.

Each VM has two networking paths.

```text
NAT network          eth0   10.0.2.15        (internet access; identical on every VM)
Host-only network    eth1   192.168.56.x     (cluster traffic; unique per VM)
```

The host-only network provides the stable addresses used by the cluster.

```text
cp1  192.168.56.10
w1   192.168.56.11
w2   192.168.56.12
```

## The NAT Trap

VirtualBox gives each VM a NAT interface that reports:

```text
10.0.2.15
```

If Kubernetes selects that interface for cluster traffic, every node appears to have the same address.

The result can be deceptive:

```text
Nodes: Ready
Flannel: Running
Pods: Running

BUT

Cross-node networking: Broken
DNS: Broken
```

The lab pins kubelet with `--node-ip` and Flannel with `--iface` to the host-only
interface (see `scripts/common.sh` and `scripts/control-plane.sh`).

## Lab

Log in to a node first; the interface commands run inside the VM:

```bash
vagrant ssh w1
```

Inspect interfaces:

```bash
ip -o -4 addr
```

Inspect routes:

```bash
ip route
```

From the host:

```bash
kubectl get nodes -o wide
```

The `INTERNAL-IP` column must show 192.168.56.x for every node.

## Failure Exercise

Temporarily disable the host-only interface on w1 (inside `vagrant ssh w1`):

```bash
sudo ip link set eth1 down
```

Watch from the host:

```bash
kubectl get nodes -w
```

The node turns `NotReady` after about 40 seconds. Restore it:

```bash
sudo ip link set eth1 up
```

## Knowledge Check

Why must Kubernetes use the `192.168.56.x` address rather than `10.0.2.15`?

---

# Lesson 3 — Preparing Linux for Kubernetes

## Objective

Understand the Linux requirements Kubernetes depends upon. All of them are applied by
`scripts/common.sh` on every cluster node.

Important configuration includes:

```text
overlay
br_netfilter
IP forwarding
swap configuration
containerd
systemd cgroups
kubelet
Kubernetes repositories
```

All checks below run inside a node (`vagrant ssh w1`).

## Inspect Kernel Modules

```bash
lsmod | grep overlay
```

```bash
lsmod | grep br_netfilter
```

## Inspect IP Forwarding

```bash
sysctl net.ipv4.ip_forward
```

Expected:

```text
net.ipv4.ip_forward = 1
```

## Inspect Swap

```bash
swapon --show
```

Kubernetes node preparation disables swap and ensures it does not automatically return after reboot:

```bash
grep swap /etc/fstab        # the line is commented out
```

## Inspect Runtime

```bash
systemctl status containerd
```

```bash
grep SystemdCgroup /etc/containerd/config.toml
```

Inspect kubelet:

```bash
systemctl status kubelet
cat /etc/default/kubelet          # KUBELET_EXTRA_ARGS=--node-ip=...
apt-mark showhold                 # kubelet kubeadm kubectl are held
```

## Failure Exercise

Re-enable swap on a worker and reboot it:

```bash
sudo sed -i 's|^#/swap.img|/swap.img|' /etc/fstab
exit
vagrant reload w1
```

Inspect:

```bash
vagrant ssh w1 -c 'journalctl -u kubelet | grep -i swap | tail -3'
```

Repair the configuration by hand (`swapoff -a`, comment the line again, `systemctl restart kubelet`)
and compare with the provisioning script. `vagrant provision w1 --provision-with common`
does the same thing idempotently.

## Key Lesson

Infrastructure configuration must survive:

```text
reboots
updates
reprovisioning
```

not merely work during the current shell session.

---

# Lesson 4 — Building the Kubernetes Control Plane

## Objective

Understand what `kubeadm init` actually creates.

When the control plane initializes, kubeadm creates certificates and static pod manifests for:

```text
etcd
kube-apiserver
kube-scheduler
kube-controller-manager
```

These manifests are stored under:

```text
/etc/kubernetes/manifests
```

The kubelet discovers these files and launches the control-plane components.

## Lab

Connect to the control plane:

```bash
vagrant ssh cp1
```

Inspect manifests:

```bash
sudo ls /etc/kubernetes/manifests
```

Inspect system pods:

```bash
kubectl -n kube-system get pods -o wide
```

Compare the running pods to the manifest files. Then read one:

```bash
sudo grep -E 'advertise-address|service-cluster-ip-range' /etc/kubernetes/manifests/kube-apiserver.yaml
```

## Mental Model

```text
kubeadm init
      ↓
configuration
      ↓
static manifests
      ↓
kubelet
      ↓
control-plane pods
```

## Knowledge Check

How can Kubernetes start its scheduler when the scheduler itself is part of Kubernetes?

---

# Lesson 5 — Worker Nodes and Pod Networking

## Objective

Understand:

* `kubeadm join`
* worker registration
* CNI
* Flannel
* pod networking
* node readiness

Workers use the join information produced by the control plane to enter the cluster. In
the lab that is `join.sh`, written by cp1 into the shared folder and run by
`scripts/worker.sh`. Its token expires after 24 hours.

## CNI

After `kubeadm init`, the node initially shows:

```text
NotReady
```

That is expected until a CNI network is installed.

The lab uses:

```text
Flannel
```

## Lab

```bash
kubectl get nodes
```

Inspect Flannel:

```bash
kubectl -n kube-flannel get pods -o wide
```

Inspect the address Flannel is advertising:

```bash
kubectl get nodes \
-o custom-columns='NAME:.metadata.name,IP:.metadata.annotations.flannel\.alpha\.coreos\.com/public-ip'
```

Every node must show its 192.168.56.x address.

## Mental Model

```text
kubeadm init
      ↓
Node NotReady
      ↓
Install CNI
      ↓
Pod network created
      ↓
Node Ready
```

## Troubleshooting Scenario

If:

```text
Nodes = Ready
Flannel = Running
Cross-node DNS = Broken
```

check which interface Flannel selected (the command above). The fix is
`vagrant provision cp1 --provision-with control-plane`, which re-applies Flannel with
`--iface` and needs no reboot.

**Lab note.** A worker VM that is running but missing from `kubectl get nodes` never
joined (typically the control plane was re-initialised after it was provisioned).
`vagrant provision w1 --provision-with worker` joins it live.

---

# Lesson 6 — Kubernetes Pods

## Objective

Create and inspect the smallest deployable Kubernetes workload.

A Pod contains one or more containers that share networking and other resources.

Save this as `hello-pod.yaml`:

```yaml
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
        requests:
          cpu: 50m
          memory: 32Mi
        limits:
          cpu: 200m
          memory: 64Mi

      securityContext:
        runAsNonRoot: true
        allowPrivilegeEscalation: false
```

Apply:

```bash
kubectl apply -f hello-pod.yaml
```

Watch:

```bash
kubectl get pod hello -w
```

Observe:

```text
Pending
↓
ContainerCreating
↓
Running
```

Inspect:

```bash
kubectl describe pod hello
```

Logs:

```bash
kubectl logs hello
```

Open a shell:

```bash
kubectl exec -it hello -- sh
```

Port-forward (then `curl -s localhost:8080 | head -3` from a second terminal):

```bash
kubectl port-forward pod/hello 8080:8080
```

Delete it:

```bash
kubectl delete pod hello
```

Now run:

```bash
kubectl get pods
```

The Pod does not return.

**Lab note.** This pod lives in the `default` namespace, which the lab's Gatekeeper
constraints deliberately do not match (Part 2). The app lives in `devapp`; plain
`kubectl get pods` never shows it. Use `-n devapp`, `-A`, or
`kubectl config set-context --current --namespace=devapp`.

## Key Lesson

A standalone Pod has no controller responsible for replacing it.

---

# Lesson 7 — Deployments, ReplicaSets, and StatefulSets

## Objective

Understand Kubernetes workload controllers.

### Pod

One workload instance.

### ReplicaSet

Keeps a requested number of pods alive.

### Deployment

Manages ReplicaSets and supports rolling updates.

### StatefulSet

Provides stable identity and ordered behavior for stateful applications.

## Application Architecture

```text
Client
   ↓
NodePort 30080
   ↓
API Service
   ↓
API Deployment (2 replicas)
 ┌─────┴─────┐
Pod         Pod
   ↓
Postgres Service (ClusterIP)
   ↓
postgres-0 (StatefulSet)
   ↓
Persistent Volume
```

**Lab note.** This lesson assumes the app is deployed. If you are following in order it
is not yet; Lesson 9 deploys it. Do Lesson 9 first, then return here.

## Lab

```bash
kubectl -n devapp get deployments
```

```bash
kubectl -n devapp get replicasets
```

```bash
kubectl -n devapp get statefulsets
```

```bash
kubectl -n devapp get pods -o wide
```

Delete the API pods (both replicas carry the `app=api` label):

```bash
kubectl -n devapp delete pod -l app=api
kubectl -n devapp get pods -w
```

Observe Kubernetes create replacements with new names.

## Compare

Standalone Pod:

```text
Delete Pod
↓
Gone
```

Deployment-managed Pod:

```text
Delete Pod
↓
ReplicaSet notices
↓
Replacement Pod created
```

---

# Lesson 8 — Kubernetes Services and Application Networking

## Objective

Understand how Kubernetes gives workloads stable network access.

Important Service types in the lab include:

```text
ClusterIP
NodePort
```

PostgreSQL uses a ClusterIP Service (`postgres.devapp.svc.cluster.local`).

The API uses NodePort 30080; the static site uses NodePort 30081.

Example flow:

```text
192.168.56.11:30080
          ↓
     NodePort
          ↓
     API Service
          ↓
     API Pod
```

A request can enter through one worker even when the destination Pod runs on another worker.

## Lab

```bash
kubectl -n devapp get services
```

Inspect endpoints:

```bash
kubectl -n devapp get endpoints
```

Test repeatedly:

```bash
for i in 1 2 3 4
do
    curl -s 192.168.56.11:30080/healthz
    echo
done
```

Observe the Pod hostname changing between replicas. `make test` runs the same checks
plus the site and the `web` edge (`http://192.168.56.20/api/healthz`).

## Knowledge Check

Why can you connect to `w1:30080` even when the API Pod handling the request is running on `w2`?

---

# Lesson 9 — Persistent Storage and PostgreSQL

## Objective

Understand how state survives Pod replacement.

A bare kubeadm cluster does not automatically provide a StorageClass.

Without one:

```text
PVC
 ↓
Pending
```

## Lab

Deploy the application before storage, on purpose:

```bash
make deploy
```

`make deploy` waits for the postgres rollout and fails after 180 s (`ROLLOUT_TIMEOUT`); that
is the point. Inspect:

```bash
kubectl -n devapp get pvc
```

Expected:

```text
Pending
```

Inspect the reason:

```bash
kubectl -n devapp describe pvc postgres-data | tail -5
```

Install storage:

```bash
make storage
```

Watch:

```bash
kubectl -n devapp get pvc -w
```

Observe:

```text
Pending
↓
Bound
```

The API pods are still not running: their image is not on the workers yet. That is
Lesson 10. Run it now (`make image`, then `make deploy` again) before the persistence test.

## Persistence Test

Create application data:

```bash
curl -s -X POST http://192.168.56.11:30080/notes \
  -H 'Content-Type: application/json' -d '{"text":"survives restarts"}'
```

Then:

```bash
kubectl -n devapp delete pod postgres-0
kubectl -n devapp get pods -w          # postgres-0 comes back with the same name
```

Retrieve the data:

```bash
curl -s http://192.168.56.11:30080/notes
```

It should still exist.

## Key Lesson

```text
Pod lifecycle
        ≠
Storage lifecycle
```

## Important Limitation

The lab's local-path storage is a directory on whichever node the pod first landed
(`/opt/local-path-provisioner/` on that worker). The pod can only ever run there.

That is useful for learning but is not equivalent to resilient production storage.

---

# Lesson 10 — Container Images and the Development Loop

## Objective

Understand the complete path from source code to a running Kubernetes workload.

The lab does not require a container registry.

Images are built locally with Docker and imported into containerd on each worker.

## Development Flow

```text
Source code (app/, web/)
    ↓
docker build
    ↓
Container image (devapp/api:dev, devapp/web:dev)
    ↓
docker save → image archive in the shared folder
    ↓
ctr -n k8s.io images import, on each worker
    ↓
Deployment (imagePullPolicy: IfNotPresent)
    ↓
Pod
```

Build and distribute:

```bash
make image                 # both images; make image IMAGES=api for one
```

Restart the API:

```bash
kubectl -n devapp rollout restart deployment/api
```

Watch:

```bash
kubectl -n devapp get pods -w
```

## Development Exercise

Add:

```text
DELETE /notes/{id}
```

to `app/main.py`.

Then:

```bash
make image IMAGES=api
```

Restart:

```bash
kubectl -n devapp rollout restart deployment/api
```

Test the endpoint through the NodePort.

## Key Lesson

Changing:

```text
app/main.py
```

does not modify containers that are already running. And because the image tag never
changes (`:dev`), even a reloaded image is ignored until the pods are restarted.

---

# Lesson 11 — Health Checks, Readiness, and Scheduling

## Objective

Understand how Kubernetes decides whether workloads should run and receive traffic.

The application provides:

```text
/healthz    liveness: returns the pod's hostname
/readyz     readiness: runs SELECT 1 against Postgres, 503 until it works
```

### Liveness

Answers:

```text
Should Kubernetes restart this container?
```

### Readiness

Answers:

```text
Should Kubernetes send traffic to this Pod?
```

## Failure Test

Scale PostgreSQL down:

```bash
kubectl -n devapp scale statefulset/postgres --replicas=0
```

Inspect API readiness (READY drops to 0/1 within a few probe periods):

```bash
kubectl -n devapp get pods -w
```

Inspect endpoints (the API pods leave the list, so `curl` to 30080 is refused rather than served a 503):

```bash
kubectl -n devapp get endpoints api
```

Restore:

```bash
kubectl -n devapp scale statefulset/postgres --replicas=1
```

## Scheduling Exercise

Identify where API Pods run:

```bash
kubectl -n devapp get pods -o wide
```

Cordon a worker:

```bash
kubectl cordon w2
```

Delete a Pod that was running there.

Observe its replacement land on w1.

Restore:

```bash
kubectl uncordon w2
```

**Lab note.** This needs both workers in the cluster. If only one is, the replacement
stays `Pending` with "0/2 nodes are available", which is its own lesson; see the Lesson 5
note on joining w1.

---

# Lesson 12 — Kubernetes Failure Engineering

## Objective

Learn Kubernetes by deliberately introducing failures.

**Lab note.** Run `make snapshot` before this lesson. Every failure below is reversible by
hand, and repairing it is part of the lesson, but `make restore` brings the whole lab back
to this point in about a minute if a repair goes wrong.

Test:

### Pod failure

```bash
kubectl -n devapp delete pod -l app=api
```

### Worker failure

```bash
vagrant halt w2            # then vagrant up w2
```

### Network failure

```bash
vagrant ssh w1 -c 'sudo ip link set eth1 down'      # restore: ... set eth1 up
```

### Memory pressure

Lower the API memory limit in `k8s/20-api.yaml` to `32Mi`, `kubectl apply -f k8s/20-api.yaml`, and observe:

```text
OOMKilled
```

Revert the file and apply again.

### Worker reset

```bash
vagrant ssh w1 -c 'sudo kubeadm reset -f'
```

Then recover the node:

```bash
vagrant provision w1 --provision-with worker
```

(If the join token has expired, `vagrant ssh cp1 -c "sudo kubeadm token create --print-join-command"` and
`vagrant provision cp1 --provision-with control-plane` rewrite `join.sh`.)

## Failure Analysis Template

For every experiment answer:

```text
What changed?

What failed?

What remained operational?

How was the failure detected?

What component performed recovery?

Did recovery require human action?

How was recovery verified?
```

---

# PART 2

# Kubernetes Security and Policy Enforcement

In Part 2 we move beyond deploying applications and start enforcing security inside the cluster.

We work through declarative Kubernetes deployments, namespaces, admission control, and OPA Gatekeeper before building policies that restrict container images to approved sources such as Chainguard.

Along the way, we troubleshoot real configuration issues, modify Gatekeeper ConstraintTemplates, inspect logs, examine policy violations, and validate that unapproved images are blocked while approved workloads deploy successfully.

This section is intentionally hands-on.

The goal is to demonstrate what Kubernetes security engineering and troubleshooting look like when things do not work perfectly the first time.

**Lab note.** The lab ships three constraints in `policy/` (installed by `make policy`) and a
worked solution for the registry policy of lessons 19–23 in `policy/examples/`, which
`make policy` does not apply. Build your own first; use the examples to compare.

---

# Lesson 13 — Declarative Kubernetes and Namespaces

## Objective

Understand the declarative Kubernetes model.

Instead of issuing a sequence of procedural instructions, we describe the desired state.

Example (from `k8s/30-web.yaml`):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: devapp
spec:
  replicas: 2
```

Kubernetes continuously attempts to reconcile the current state with the desired state.

## Mental Model

```text
Manifest
   ↓
Desired State
   ↓
API Server
   ↓
Controller
   ↓
Current State
   ↓
Reconciliation
```

## Namespace Review

Inspect:

```bash
kubectl get namespaces
```

View application resources:

```bash
kubectl -n devapp get all
```

## Security Relevance

Namespaces can provide boundaries for:

```text
RBAC
policy
resource management
admission controls
workload organization
```

They are not automatically strong security boundaries by themselves, but they are important policy-scoping mechanisms. The lab's constraints are scoped by namespace: `devapp` and `sec-*` are policed, `default` is not.

---

# Lesson 14 — Kubernetes Admission Control

## Objective

Understand where security policy can intervene before resources enter the cluster.

Request path:

```text
kubectl
   ↓
API Server
   ↓
Authentication
   ↓
Authorization
   ↓
Admission Control
   ↓
etcd
```

Admission control operates after identity and permissions have been evaluated but before the accepted resource is stored.

This allows Kubernetes to inspect an object before it becomes part of cluster state.

## Security Question

Instead of only asking:

```text
Is this user allowed to create Pods?
```

admission control can ask:

```text
Is this particular Pod acceptable?
```

Examples:

```text
Is it privileged?

Does it run as root?

Does it have resource limits?

Is its image approved?

Does it request host networking?

Does it mount a dangerous hostPath?
```

**Lab note.** Kubernetes has a built-in admission controller for the first of these,
Pod Security Admission. `make sectest ROUTINE=07` shows it in action and lists what the
lab's own workloads would violate under `restricted`.

---

# Lesson 15 — Introduction to OPA Gatekeeper

## Objective

Understand Gatekeeper's role in Kubernetes policy enforcement.

Gatekeeper operates as a validating admission webhook.

The request path becomes:

```text
Developer
    ↓
kubectl apply
    ↓
API Server
    ↓
Authentication
    ↓
Authorization
    ↓
Admission
    ↓
OPA Gatekeeper
    ↓
Policy Decision
   ↙           ↘
DENY          ALLOW
                 ↓
                etcd
```

Install the policy environment:

```bash
make policy
```

This applies the pinned Gatekeeper release, waits for it, then applies `policy/templates/`
and `policy/constraints/`. Inspect:

```bash
kubectl -n gatekeeper-system get pods
kubectl get constraints -o wide
```

## Test Existing Policy

Attempt:

```bash
kubectl -n devapp apply \
-f security/policies/privileged-pod.yaml
```

Expected:

```text
Error from server (Forbidden): ... admission webhook "validation.gatekeeper.sh" denied the request:
[no-privilege] container "shell" is privileged (securityContext.privileged: true)
[no-privilege] hostNetwork: true shares a host namespace with the node
[no-privilege] hostPID: true shares a host namespace with the node
[no-privilege] volume "host" mounts host path "/"
```

plus two `[non-root]` warnings. Now try the same file without `-n devapp`: in `default`
it is admitted, because no constraint matches that namespace. Delete it afterwards
(`kubectl delete pod sec-test-privileged`).

---

# Lesson 16 — ConstraintTemplates and Constraints

## Objective

Understand Gatekeeper's two major policy objects.

## ConstraintTemplate

Defines:

```text
WHAT the policy means
```

It contains policy logic (Rego, in this lab) and defines a new constraint type.

## Constraint

Defines:

```text
WHERE the policy applies
and
HOW it is enforced
```

Conceptually:

```text
ConstraintTemplate
        │
        │ defines rule
        ▼
Custom Constraint Type
        │
        │ instantiated by
        ▼
Constraint
        │
        ├── namespaces
        ├── resource kinds
        └── enforcementAction
```

Read the policy files: `policy/templates/10-no-privilege.yaml` and
`policy/constraints/10-no-privilege.yaml`. Then:

```bash
kubectl get constrainttemplates
```

Then:

```bash
kubectl get constraints
```

Note that each template became a CRD:

```bash
kubectl get crd | grep constraints.gatekeeper.sh
```

## Knowledge Check

What happens if you create a ConstraintTemplate but never create a corresponding Constraint?

---

# Lesson 17 — Policy Enforcement Modes

## Objective

Understand safe policy rollout.

Gatekeeper supports enforcement actions:

```text
dryrun
warn
deny
```

Recommended progression:

```text
dryrun
   ↓
observe
   ↓
warn
   ↓
remediate
   ↓
verify
   ↓
deny
```

## Why This Matters

Immediately enabling blocking policies can interrupt legitimate workloads.

A safer operational approach is:

1. discover violations
2. measure impact
3. identify owners
4. remediate workloads
5. verify compliance
6. enforce

## Lab

Inspect:

```bash
kubectl get constraints -o wide
```

Identify:

```text
ENFORCEMENT-ACTION
TOTAL-VIOLATIONS
```

The lab ships `no-privilege` as `deny` and `non-root` and `resource-limits` as `warn`,
each with 4 violations: the postgres StatefulSet and its pod, twice over. See the warnings
appear live:

```bash
kubectl -n devapp rollout restart statefulset/postgres
```

---

# Lesson 18 — Hardening the PostgreSQL Workload

## Objective

Bring an existing workload into compliance before strengthening policy enforcement.

Edit `k8s/10-postgres.yaml`. Add a Pod security context under `spec.template.spec`:

```yaml
securityContext:
  runAsUser: 70          # the postgres user in postgres:16-alpine
  runAsGroup: 70
  fsGroup: 70
  runAsNonRoot: true
```

Container security:

```yaml
securityContext:
  allowPrivilegeEscalation: false
```

Add CPU and memory constraints:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi

  limits:
    cpu: 500m
    memory: 512Mi
```

And one more container `env` entry, without which Postgres crash-loops as a non-root user:

```yaml
env:
  - name: PGDATA
    value: /var/lib/postgresql/data/pgdata
```

**Lab note (verified).** local-path-provisioner creates the volume directory as
`root:root 0777`. When the image ran as root its entrypoint chowned that directory to
uid 70 and then dropped privileges; as uid 70 from the start it cannot, and `initdb`
fails with `could not change permissions of directory`. Pointing `PGDATA` at a
subdirectory lets initdb create one it owns. `fsGroup` does not help here: kubelet does
not apply it to hostPath-backed volumes. On the lab's *existing* volume the data sits at
the volume root, so after this change Postgres starts a fresh, empty database in the
subdirectory. The notes are disposable; if you want to keep them, `pg_dump` first.

Apply:

```bash
make deploy
```

Inspect:

```bash
kubectl -n devapp get pods -w                # postgres-0 Running, API pods READY again
kubectl get constraints -o wide              # within 60 s
```

Goal:

```text
0 violations
```

Once remediation is verified, move the relevant policy toward `deny` in
`policy/constraints/20-non-root.yaml` and `30-resource-limits.yaml`:

```yaml
enforcementAction: deny
```

```bash
kubectl apply -f policy/constraints/
make sectest ROUTINE=10
```

---

# Lesson 19 — Approved Container Image Sources

## Objective

Prevent workloads from pulling container images from arbitrary sources.

This introduces an important software supply-chain control:

```text
Not every image registry should automatically be trusted.
```

Example policy objective:

```text
Allow:
cgr.dev/chainguard/*

Block:
unapproved registries
unknown registries
unexpected public images
```

## Desired Request Flow

```text
Deployment submitted
        ↓
Gatekeeper reads image
        ↓
Registry checked
       ↙ ↘
Approved   Unapproved
   ↓           ↓
ALLOW        DENY
```

## Example Approved Source

```text
cgr.dev/chainguard/
```

This demonstrates how admission control can limit the sources from which container software enters the environment.

**Lab note.** Every image the lab runs today (`devapp/api:dev`, `devapp/web:dev`,
`postgres:16-alpine`) fails this rule. That is realistic: a registry policy always
starts with an inventory of what would break.

---

# Lesson 20 — Building an Image Registry ConstraintTemplate

## Objective

Create Gatekeeper policy logic that evaluates container image names.

The rule should inspect containers and determine whether each image matches an approved registry.

Conceptual logic:

```text
FOR every container

    READ image

    IF registry NOT approved

        violation
```

Policy areas to consider:

```text
containers
initContainers
ephemeralContainers
```

The first implementation can focus on normal containers and then be expanded.

Start from `policy/templates/10-no-privilege.yaml`: keep its `pod_spec` and `containers`
rules, add a `validation.openAPIV3Schema` for an `allowedRegistries` list parameter,
and write one `violation` using `startswith(c.image, prefix)`. Apply with
`kubectl apply -f your-template.yaml` and check `kubectl get constrainttemplates`
shows it, and `kubectl get crd | grep approvedregistry` shows the new kind.

## Troubleshooting Questions

If the policy does not work:

```text
Was the ConstraintTemplate accepted?      kubectl get constrainttemplate <name> -o yaml | grep -A5 status

Was the CRD created?                      kubectl get crd | grep constraints.gatekeeper.sh

Was the Constraint accepted?              kubectl describe <kind> <name>

Does the Constraint match the namespace?

Does it match the correct resource type?

Does the Rego expression inspect the right field?

Is Gatekeeper running?                    kubectl -n gatekeeper-system get pods

Did the webhook receive the request?      kubectl -n gatekeeper-system logs deploy/gatekeeper-controller-manager
```

Reference solution: `policy/examples/registry-template.yaml`.

---

# Lesson 21 — Creating the Approved Registry Constraint

## Objective

Apply the policy to selected namespaces.

Possible configuration:

```yaml
match:
  kinds:
    - apiGroups: [""]
      kinds: ["Pod"]
    - apiGroups: ["apps"]
      kinds: ["Deployment", "StatefulSet", "DaemonSet"]

  namespaces:
    - devapp
```

Matching only `Deployment` would let a bare Pod or a StatefulSet through; match the pod
kinds and the workload kinds that create them.

Policy parameter:

```yaml
parameters:
  allowedRegistries:
    - cgr.dev/chainguard/
```

Start with:

```yaml
enforcementAction: warn
```

Verify behavior before switching to:

```yaml
enforcementAction: deny
```

Reference solution: `policy/examples/registry-constraint.yaml`.

---

# Lesson 22 — Test an Unapproved Image

## Objective

Prove that policy enforcement actually blocks unwanted workloads.

Create a workload using an image that does not meet the registry policy. It should comply
with every *other* constraint, so the only finding is the registry
(`policy/examples/unapproved-deployment.yaml` does this with `docker.io/nginxinc/nginx-unprivileged:alpine`).

In `warn` mode:

```bash
kubectl apply -f policy/examples/unapproved-deployment.yaml
```

```text
Warning: [approved-registry] container "web" uses image "docker.io/nginxinc/nginx-unprivileged:alpine", which is not from an approved registry ["cgr.dev/chainguard/"]
deployment.apps/unapproved created
```

Delete it, switch the constraint to `deny`, and apply again:

```bash
kubectl -n devapp delete deploy unapproved
kubectl patch k8slabapprovedregistry approved-registry --type merge -p '{"spec":{"enforcementAction":"deny"}}'
kubectl apply -f policy/examples/unapproved-deployment.yaml
```

Expected result:

```text
Error from server (Forbidden): ... admission webhook "validation.gatekeeper.sh" denied the request: [approved-registry] container "web" uses image ...
```

The important evidence is not merely that the deployment failed.

Verify that:

```text
Gatekeeper made the decision
```

rather than another Kubernetes failure: the message names the webhook and the constraint.

Inspect:

```bash
kubectl get deployments -n devapp
```

The denied deployment does not exist.

---

# Lesson 23 — Test an Approved Chainguard Image

## Objective

Demonstrate that the policy permits compliant workloads.

Create a workload using an approved image from:

```text
cgr.dev/chainguard/
```

`policy/examples/approved-deployment.yaml` uses `cgr.dev/chainguard/nginx:latest`, which
runs as uid 65532 and listens on 8080, so it also satisfies the lab's other constraints.

Apply:

```bash
kubectl apply -f policy/examples/approved-deployment.yaml
```

Inspect:

```bash
kubectl -n devapp get deployments
```

Then:

```bash
kubectl -n devapp get pods -l app=approved -o wide
```

Expected:

```text
Deployment admitted
Pod scheduled
Container running
```

Prove which image is running, by digest:

```bash
kubectl -n devapp get pod -l app=approved -o jsonpath='{.items[0].status.containerStatuses[0].imageID}{"\n"}'
```

**Lab note (verified).** `kubectl exec` into this pod fails with `exec: "id": executable
file not found`: Chainguard images are distroless, with no shell. That is a feature. Test
it from outside instead: `kubectl -n devapp port-forward deploy/approved 8080:8080` and
`curl -s localhost:8080 | head -3`. Note also that only the `:latest` tag is free on
cgr.dev, which Lesson 28 turns into an exercise.

## Security Lesson

Successful policy enforcement requires both tests:

```text
Negative test
Unapproved workload → blocked

Positive test
Approved workload → allowed
```

A security policy that only blocks things has not been fully validated.

Clean up when done: `kubectl delete -f policy/examples/` removes both deployments, the
constraint and the template.

---

# Lesson 24 — Troubleshooting Gatekeeper

## Objective

Learn how to diagnose policy failures when the result is not what you expected.

Security policy troubleshooting should follow evidence.

## Step 1 — Gatekeeper Components

```bash
kubectl -n gatekeeper-system get pods
```

(One `Running` restart on `gatekeeper-audit` right after install is a known startup race
on the webhook certificate; anything else deserves `kubectl -n gatekeeper-system logs`.)

## Step 2 — ConstraintTemplates

```bash
kubectl get constrainttemplates
kubectl get constrainttemplate k8slabnoprivilege -o jsonpath='{.status}' | jq .   # created: true, no errors
```

## Step 3 — Constraints

```bash
kubectl get constraints
```

## Step 4 — Inspect the Constraint

```bash
kubectl describe k8slabnoprivilege no-privilege
```

## Step 5 — Logs

Inspect controller logs:

```bash
kubectl -n gatekeeper-system logs \
deployment/gatekeeper-controller-manager
```

## Step 6 — Webhook

Inspect:

```bash
kubectl get validatingwebhookconfiguration
```

## Step 7 — The lab's own check

```bash
make sectest ROUTINE=10
```

## Troubleshooting Model

```text
Workload failed
      ↓
Was failure Kubernetes or Gatekeeper?
      ↓
Did webhook run?
      ↓
Did Constraint match?
      ↓
Did template evaluate correctly?
      ↓
Did policy parameters match?
      ↓
Was expected registry detected?
```

---

# Lesson 25 — Modify and Debug a ConstraintTemplate

## Objective

Learn that policy development is software development.

A ConstraintTemplate may contain:

```text
syntax problems
incorrect field references
incorrect assumptions
bad string matching
namespace mismatches
unexpected workload structures
```

Modify the template.

Reapply:

```bash
kubectl apply -f policy/templates/
```

Inspect (a Rego error shows up in the template's `status`, not on apply):

```bash
kubectl get constrainttemplates
kubectl get constrainttemplate <name> -o jsonpath='{.status.byPod[*].errors}'
```

Then retest both:

```text
approved image
unapproved image
```

Try it deliberately: change `startswith` to `endswith` in your registry template, re-apply,
and watch the approved image get denied.

## Key Lesson

Policy development should follow:

```text
write
↓
deploy
↓
test
↓
inspect
↓
debug
↓
retest
```

not:

```text
write
↓
assume secure
```

---

# Lesson 26 — Gatekeeper Audit

## Objective

Understand the difference between admission enforcement and audit.

Admission control evaluates:

```text
new or updated requests
```

But workloads may already exist before a new policy is introduced.

Gatekeeper's audit capability evaluates existing resources every 60 seconds and reports violations.

Inspect:

```bash
kubectl get constraints -o wide
```

Look at:

```text
TOTAL-VIOLATIONS
```

Inspect violations:

```bash
kubectl get k8slabnonroot non-root \
-o jsonpath='{.status.violations}' | jq .
```

## Mental Model

```text
Admission
→ Can this new request enter?

Audit
→ What already exists that violates policy?
```

---

# Lesson 27 — What Happens When Gatekeeper Fails?

## Objective

Understand security-control failure behavior.

Scale Gatekeeper down:

```bash
kubectl -n gatekeeper-system scale \
deployment gatekeeper-controller-manager \
--replicas=0
```

Attempt to create a workload that should be denied:

```bash
kubectl -n devapp apply -f security/policies/privileged-pod.yaml
```

It is admitted. Inspect the webhook configuration:

```bash
kubectl get validatingwebhookconfiguration \
gatekeeper-validating-webhook-configuration -o yaml | grep failurePolicy
```

Look for:

```text
failurePolicy: Ignore
```

Restore:

```bash
kubectl -n devapp delete pod sec-test-privileged
kubectl -n gatekeeper-system scale \
deployment gatekeeper-controller-manager \
--replicas=1
```

## Security Question

What should happen if the policy engine becomes unavailable?

This introduces:

```text
fail-open
vs.
fail-closed
```

and the operational tradeoffs associated with each. Gatekeeper's upstream default is
fail-open (`Ignore`), which `make sectest ROUTINE=10` flags as a WARN; `Fail` is safer and
can lock you out of your own cluster if Gatekeeper never comes back.

---

# Lesson 28 — Write Your Own Kubernetes Policy

## Objective

Move from modifying existing policies to creating one independently.

Create a policy that rejects:

```text
untagged images
```

or:

```text
:latest
```

Conceptual rules:

```text
image ends with ":latest"          endswith(c.image, ":latest")
```

or:

```text
image contains no tag              not contains(c.image, ":")   (mind digests: "@sha256:")
```

Begin with:

```yaml
enforcementAction: warn
```

Then test:

```text
nginx:latest
```

versus a versioned image. The approved Chainguard deployment from Lesson 23 uses
`:latest`; your new policy and the registry policy now disagree about it. Which wins,
and what would a real organisation do?

## Improvement Challenge

Extend the policy to require:

```text
approved registry
AND
explicit image tag
```

Advanced challenge:

```text
require digest pinning
```

---

# Lesson 29 — Kubernetes Security Testing

## Objective

Treat Kubernetes security as a system rather than a collection of YAML files.

Validate:

```text
Pod security
RBAC
Secrets
resource limits
network exposure
container images
admission controls
policy violations
```

Useful questions:

```text
Can a privileged Pod enter?

Can an unapproved image enter?

Can a workload run as root?

Are resource limits required?

What can workloads access?

What happens if a worker fails?

What happens if Gatekeeper fails?

Can existing violations be detected?

Can remediation be verified?
```

The lab automates most of this:

```bash
make sectest                 # all ten routines in security/
SKIP_SLOW=1 make sectest     # skip Trivy and kube-bench
```

Read [security/README.md](../security/README.md) for what each routine checks and what
the stock lab is expected to fail.

---

# Lesson 30 — Final Kubernetes Security Capstone

## Scenario

You have inherited a Kubernetes environment containing:

```text
FastAPI
PostgreSQL
three Kubernetes nodes
Flannel
containerd
local persistent storage
OPA Gatekeeper
```

Your assignment is to make the environment:

```text
operational
secure
policy-enforced
observable
recoverable
verifiable
```

---

## Phase 1 — Build the Cluster

```bash
make up
```

Verify:

```bash
kubectl get nodes
```

All expected nodes must become:

```text
Ready
```

---

## Phase 2 — Deploy the Application

```bash
make storage
make image
make deploy
```

Inspect:

```bash
kubectl -n devapp get all
```

Verify API access (`make test`).

Verify PostgreSQL.

Create test data.

---

## Phase 3 — Verify Persistence

Delete PostgreSQL:

```bash
kubectl -n devapp delete pod postgres-0
```

Verify:

```text
Pod recreated
Data remains
```

---

## Phase 4 — Harden the Workloads

Implement:

```text
runAsNonRoot
allowPrivilegeEscalation: false
resource requests
resource limits
appropriate user/group IDs
```

(Lesson 18 for Postgres, including `PGDATA`.) Verify application functionality.

---

## Phase 5 — Deploy Gatekeeper

```bash
make policy
```

Inspect:

```bash
kubectl get constraints -o wide
```

---

## Phase 6 — Implement Approved Registry Policy

Create policy that allows approved sources such as:

```text
cgr.dev/chainguard/
```

Begin in:

```text
warn
```

then progress toward:

```text
deny
```

after testing.

---

## Phase 7 — Negative Security Test

Attempt to deploy an unapproved image.

Expected:

```text
DENIED
```

Capture the policy error as evidence.

---

## Phase 8 — Positive Security Test

Deploy an approved image.

Expected:

```text
ADMITTED
↓
SCHEDULED
↓
RUNNING
```

---

## Phase 9 — Failure Testing

Test at least three failures.

### Failure 1

Delete an API Pod.

### Failure 2

Shut down a worker.

### Failure 3

Break node networking.

For each test document:

```text
Failure introduced
Detection
Impact
Recovery behavior
Human intervention
Verification
```

---

## Phase 10 — Security Control Failure

Stop Gatekeeper.

Determine:

```text
Does Kubernetes fail open or fail closed?
```

Restore Gatekeeper.

Retest policy enforcement.

---

# Capstone Evidence Package

The learner submits:

## Architecture

```text
Cluster diagram
Network diagram
Application request path
Admission-control request path
```

## Kubernetes Evidence

```bash
kubectl get nodes
kubectl -n devapp get pods -o wide
kubectl -n devapp get deployments
kubectl -n devapp get statefulsets
kubectl -n devapp get services
kubectl -n devapp get pvc
```

## Security Evidence

```bash
kubectl get constrainttemplates
kubectl get constraints -o wide
make sectest
```

Include:

```text
unapproved-image denial
approved-image deployment
policy violations
policy remediation
```

## Failure Evidence

Document:

```text
Pod failure
Worker failure
Network failure
Gatekeeper failure
```

---

# Final Mental Model

A learner should understand the entire path:

```text
Virtual Machine
      ↓
Linux
      ↓
containerd
      ↓
kubelet
      ↓
Kubernetes Control Plane
      ↓
CNI
      ↓
Scheduler
      ↓
Pod
      ↓
Service
      ↓
Persistent Storage
      ↓
Application
```

and the security path:

```text
Developer
    ↓
kubectl
    ↓
API Server
    ↓
Authentication
    ↓
Authorization
    ↓
Admission Control
    ↓
OPA Gatekeeper
    ↓
Policy Evaluation
   ↙           ↘
DENY          ALLOW
                 ↓
                etcd
                 ↓
             Scheduler
                 ↓
                Pod
```

---

# Final Knowledge Check

A learner completing the course should be able to answer the following without looking at the lab documentation.

1. Why does a Kubernetes node initially show `NotReady` after `kubeadm init`?

2. What role does the CNI perform?

3. Why must the lab pin Kubernetes to the host-only IP?

4. What can happen if Flannel chooses the NAT interface?

5. Why must Linux IP forwarding be enabled?

6. Why is swap disabled?

7. What is containerd's role?

8. What is kubelet's role?

9. What is the difference between a Pod and a Deployment?

10. What does a ReplicaSet do?

11. Why is PostgreSQL deployed as a StatefulSet?

12. Why can a NodePort be reached through a node that is not hosting the destination Pod?

13. Why does the PostgreSQL PVC initially remain `Pending`?

14. What changes when the StorageClass is installed?

15. Why does deleting PostgreSQL not automatically delete its data?

16. Why doesn't rebuilding an image automatically update running Pods?

17. What is the difference between liveness and readiness?

18. What happens after a Deployment-managed Pod is deleted?

19. What does cordoning a node do?

20. Where does admission control occur in the Kubernetes request path?

21. What is the difference between authentication and authorization?

22. What additional decision can admission control make after authorization succeeds?

23. What does OPA Gatekeeper do?

24. What is the difference between a ConstraintTemplate and a Constraint?

25. What is the purpose of `dryrun`?

26. When would `warn` be preferable to `deny`?

27. Why should workloads be remediated before a policy is moved to `deny`?

28. How can Gatekeeper restrict container registries?

29. Why should an image policy test both approved and unapproved workloads?

30. What is the difference between Gatekeeper admission enforcement and Gatekeeper audit?

31. Why should the Gatekeeper webhook's `failurePolicy` be understood?

32. What is the difference between fail-open and fail-closed?

33. Why is `:latest` a poor production image practice?

34. Why is image registry restriction useful for software supply-chain security?

35. What evidence proves that a Kubernetes security control actually works?

---

# Recommended Next Stage

After completing this series, extend the environment with:

## Networking

Replace Flannel with:

```text
Calico
```

Then implement Kubernetes:

```text
NetworkPolicy
```

Example objective:

```text
Only API Pods may communicate with PostgreSQL.
```

(`security/policies/netpol-postgres-only-from-api.yaml` is that policy; `make sectest ROUTINE=04`
proves Flannel ignores it today.)

## Container Registry

Replace manual containerd imports with a private or local registry.

Use versioned images:

```text
devapp/api:v1.0.0
devapp/api:v1.1.0
```

## Secrets

Move away from plaintext Kubernetes Secrets toward technologies such as:

```text
External Secrets
Sealed Secrets
```

## Ingress

Deploy an Ingress controller.

Move from:

```text
NodePort
```

toward:

```text
Ingress
TLS
hostname-based routing
```

## High Availability

Add:

```text
second control-plane node
stable API endpoint
load balancer
```

## Supply-Chain Security

Progress from:

```text
approved registry
```

to controls such as:

```text
versioned image tags
digest pinning
image scanning (make sectest ROUTINE=06 runs Trivy)
SBOM verification
image signing
signature verification
trusted build pipelines
```

## Policy Evolution

Compare:

```text
OPA Gatekeeper with Rego
Gatekeeper native validation (CEL)
Kubernetes ValidatingAdmissionPolicy
```

---

# Core Course Philosophy

This series is not built around memorizing `kubectl` commands.

The goal is to understand the system.

The learning cycle is:

```text
Build
  ↓
Observe
  ↓
Change
  ↓
Break
  ↓
Investigate
  ↓
Repair
  ↓
Secure
  ↓
Test
  ↓
Verify
```

That is what working with Kubernetes looks like in practice.

Things will not always work correctly on the first attempt.

That is part of the lesson.

A Kubernetes engineer should be able to move from:

```text
"It failed."
```

to:

```text
"What layer failed?"
```

then:

```text
"What evidence tells me why?"
```

and finally:

```text
"How do I verify that the fix actually worked?"
```

That same approach applies to Kubernetes operations, DevSecOps, security policy, incident response, and production troubleshooting.

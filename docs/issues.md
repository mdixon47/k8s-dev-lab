# Known issues and open work

Everything found while reviewing the lab, with its status. Update an entry when it is
resolved rather than deleting it; the history is useful. Dates are when the entry was
written. Reviewed on 2026-09-17 and 2026-09-20 against the repository only: no VM was
running, so anything marked **unverified** needs one pass of the lab to confirm.

Status key: **open** (needs work), **unverified** (change made, not yet exercised on a live
lab), **future** (deliberately not done), **resolved**.

---

## 1. Needs a running lab

| # | Status | Item |
|---|--------|------|
| 1.1 | unverified | **Kubernetes 1.36.** `K8S_VERSION` moved from 1.30 (end-of-life June 2025) to 1.36 (supported until 2027-06-28) on 2026-09-20. The pkgs.k8s.io `v1.36` deb repository exists (checked), but no cluster has been built with it yet. Also unverified against 1.36: local-path-provisioner v0.0.28, Gatekeeper v3.23.1, kube-bench in routine 08. Run `make clean && make all && make policy && make sectest`, then read `kubectl version` and `kubectl -n kube-system get pods`. 2026-09-20: the lab currently running was built before the bump and reports `Server Version: v1.30.14`; the host kubectl is 1.28–1.30 (Kustomize `v5.0.4-0.20230601165947`) and must be upgraded to 1.35–1.37 before the rebuild, or every `kubectl` call is outside the supported version skew. |
| 1.2 | resolved 2026-09-20 | **Flannel pinned to v0.28.9** instead of `master`. Verified on the live (1.30.14) cluster: `vagrant provision cp1 --provision-with control-plane` applied `ghcr.io/flannel-io/flannel:v0.28.9` on all three nodes, the `--iface` injection landed, and every node's `public-ip` annotation is its 192.168.56.x address. Still to see once: a fresh `make all` (1.1). |
| 1.3 | unverified | **`make snapshot` / `make restore`.** `vagrant snapshot save --force` on four running VirtualBox VMs takes online snapshots; `restore --no-provision` should bring the cluster back with its pods. Confirm that `kubeconfig` on the host still works afterwards, that a snapshot taken while the desktop window is open restores cleanly, and how much disk four snapshots use (VirtualBox differencing disks grow with every write after the snapshot). |
| 1.4 | unverified | **Rollout timeouts.** `make deploy` now passes `--timeout=180s` to each `rollout status`. 180 s should cover a cold `postgres:16-alpine` pull on a slow link; if the first `make all` on a fresh clone fails at `deploy` with `timed out waiting for the condition` while the pods are merely slow, raise `ROLLOUT_TIMEOUT`. |
| 1.5 | open | **First-run time.** README, learn.md and the course say 15–20 min; the Makefile and CLAUDE.md said 10–15 until 2026-09-20 (now aligned to 15–20). Nobody has timed a fresh `make all` with the desktop install on the current box. Time it and put one number everywhere. |
| 1.6 | open | **README: "The screen is fixed at 1280x800."** Nothing in the repo sets a resolution; it is presumably VirtualBox's EFI default for the ramfb device on ARM64. Confirm with `xrandr` (or `cat /sys/class/drm/card0-*/modes`) on cp1, and say whether amd64 hosts differ. |
| 1.7 | open | **learn.md exercise 12 and CLAUDE.md troubleshooting: `xrandr --output None-1`.** The output name comes from XWayland under GNOME 50 (Wayland session). `None-1` was observed on an earlier XFCE/Xorg build; on XWayland it may be `XWAYLAND0` or similar, and `xrandr --off` through XWayland may not blank the display at all. `scripts/desktop.sh` avoids the name by looping over `xrandr | awk '/ connected/'`. Verify the exercise still does what it says, or rewrite it around `vbox-display-fix`. |
| 1.8 | resolved 2026-09-20 | **The `/swap.img` fstab line.** Confirmed on w1: `#/swap.img<tab>none<tab>swap<tab>sw<tab>0<tab>0`. The exercise text is right. |
| 1.9 | open | **Course commands after the 2026-09-20 changes.** `docs/course.md` claims every command was verified. Lesson 9's `make deploy` now fails on the timeout instead of hanging (text updated), and lesson 12 gained a `make snapshot` note. Neither has been run through. |

## 2. Open

| # | Status | Item |
|---|--------|------|
| 2.1 | open | **Gator suite coverage.** `policy/tests/suite.yaml` covers `containers` only. The templates also walk `initContainers` and `ephemeralContainers`; add a fixture with an init container that violates each rule so that code path is tested. `dryrun` enforcement is untested too. |
| 2.2 | open | **kubeconform schema version.** `scripts/check.sh` validates against the schema store's default (`master`), not `-kubernetes-version 1.36.0`. Pin it once the schema repository (yannh/kubernetes-json-schema) carries 1.36; until then the check is slightly newer than the cluster. |
| 2.3 | resolved 2026-09-20 | **`make check` in CI.** `.github/workflows/check.yml` runs `make check` and `make policy-test` on every push and pull request (ubuntu-24.04, actions/checkout@v7; shellcheck and yamllint from apt, kubeconform and gator from their Docker images). |
| 2.4 | open | **Docs are hand-synchronised.** README, learn.md, course.md and CLAUDE.md all describe the same behaviour; the 2026-09-17 review found the README contradicting itself about `K8S_GUI`, a wrong violation count in learn.md, and three different RAM/time figures. The link check catches dead links only. Consider a short "facts" list (RAM, first-run time, node IPs, versions) that the other files quote, or at least re-run the review after each behaviour change. |
| 2.5 | open | **`make test` still uses one worker.** It now derives the address from the Vagrantfile (first `worker` node) instead of a literal, but still tests through one NodePort. A loop over every worker would show NodePort really opens on all of them. |
| 2.7 | open | **`make deploy` timed out on a real lab (2026-09-20)** because w1 had been reset (exercise 16) and never rejoined, and Gatekeeper's controller was back at 3 replicas (1536 Mi requested), which filled w2 to 96% so the api pods stayed `Pending: Insufficient memory`. Fixed by hand (scale to 1, `vagrant provision cp1 --provision-with control-plane` for a fresh token, `vagrant provision w1 --provision-with worker`). Root cause of the missing worker (from w1's and cp1's journals): w1 had **never** joined. During the 2026-09-16 build, cp1 went down at 14:43:27 UTC and came back at 14:47:11 (a "Power off" from the VM window plus `vagrant up cp1`, by the look of the gap) while w1's `kubeadm join` was running; kubeadm's 5-minute discovery timeout expired against the rebooting API server, Vagrant reported the failure and moved on to w2, and nothing retried. Fixed 2026-09-20: `scripts/worker.sh` now waits for the API server named in `join.sh` to answer `/healthz`, then tries the join up to three times with `kubeadm reset -f` between attempts (untested on a fresh VM; the idempotency path was exercised on the joined w1). Both follow-ups done 2026-09-20: (a) `make status` warns when `kubectl get nodes` lists fewer nodes than the Vagrantfile's control-plane + worker entries; (b) the Deployment's `managedFields` show `spec.replicas` owned by `kubectl scale`, and the last `kubectl apply` (Sep 17 01:06 UTC) did not touch it, so a `make policy` re-run was not the cause; the likeliest is a hand-typed `--replicas=3` that evening. `scripts/gatekeeper.sh` now sets `replicas: 1` in the manifest before applying (verified live: spec and last-applied both 1), so the next `make policy` undoes any stray scale. Status: resolved. |
| 2.6 | open | **Snapshots and `make image`.** A restore rolls back containerd's image store, so images imported after the snapshot vanish and pods go `ErrImageNeverPull` until `make image` is re-run. The README says so; the `restore` target could print the reminder. |

## 3. Future work (deliberately not done)

| # | Status | Item |
|---|--------|------|
| 3.1 | future | **CNI as a Vagrantfile constant (`flannel` \| `calico`).** Calico is the stated "next step" in learn.md and the course, and the only way security routine 04 (NetworkPolicy) ever passes. Needs the Calico manifest pinned, `POD_CIDR` passed through, the NAT-trap pin expressed the Calico way (`IP_AUTODETECTION_METHOD=interface=eth1`), and both paths tested. |
| 3.2 | future | **Local registry instead of `ctr import`.** Would let versioned tags and rolling updates work without `rollout restart`; already listed under "Where to go next" in learn.md. |
| 3.3 | future | **Secrets.** `k8s/10-postgres.yaml` and the literal `DATABASE_URL` in `20-api.yaml` are deliberate teaching material (security routines 01/02/05, exercise 1 in `security/README.md`). Leave them; a Sealed Secrets or External Secrets variant belongs in the course, not the default deploy. |
| 3.4 | future | **CEL / ValidatingAdmissionPolicy port of `policy/`.** Listed in learn.md §6. Would remove the webhook dependency and make a good comparison lesson. |

## 4. Resolved

| # | Date | Item |
|---|------|------|
| 4.1 | 2026-09-17 | README said VMs start headless unless `K8S_GUI` is set; the default (`K8S_GUI=1`) opens the desktop node's window. Text fixed. |
| 4.2 | 2026-09-17 | README's "`make all` runs those five steps" followed a six-line list (`make policy` had been added). Now says the first five. |
| 4.3 | 2026-09-17 | learn.md said the privileged pod is denied "five reasons"; the template yields four `[no-privilege]` messages (privileged, hostPID, hostNetwork, hostPath) plus `[non-root]` warnings. Fixed, and now asserted by `policy/tests/suite.yaml`. |
| 4.4 | 2026-09-17 | learn.md's big-picture diagram and layer table had no web image, web pods or edge VM. Added. |
| 4.5 | 2026-09-17 | learn.md walkthrough restarted only `deployment/api` after `make image`; web pods needed it too. Fixed. |
| 4.6 | 2026-09-17 | Neither README nor learn.md described `policy/examples/`. Both do now, with the course lesson numbers. |
| 4.7 | 2026-09-17 | RAM figure: CLAUDE.md said ~8 GB (~6 without desktop); the Vagrantfile adds up to 9 GB (7). Fixed. First-run time aligned to 15–20 min in Makefile and CLAUDE.md. Vagrantfile comment still said "XFCE desktop". `security/README.md` numbered two exercises "4.". All fixed. |
| 4.8 | 2026-09-17 | learn.md checklist asked why the console shows only EFI messages "on the stock kernel", which was true of 22.04 only. Reworded. |
| 4.9 | 2026-09-20 | `make deploy` hung forever when the StorageClass or an image was missing (`rollout status` has no default timeout), so `make all` never failed at the right step. Added `ROLLOUT_TIMEOUT` (180 s). learn.md and course lesson 9 updated (no more "Ctrl-C it"). |
| 4.10 | 2026-09-20 | Flannel manifest was fetched from the `master` branch, the one unpinned component; the `sed` guard in `control-plane.sh` exists because that once broke silently. Now `FLANNEL_VERSION` (Vagrantfile) → release tag. See 1.2. |
| 4.11 | 2026-09-20 | `K8S_VERSION` 1.30 was end-of-life. Bumped to 1.36. See 1.1. |
| 4.12 | 2026-09-20 | No way to undo an exercise short of re-provisioning. Added `make snapshot` / `make restore` (`SNAP=name`). See 1.3. |
| 4.13 | 2026-09-20 | No policy tests. Added `policy/tests/suite.yaml` (17 cases across the three lab templates and the example registry policy), `scripts/policy-test.sh` and `make policy-test`; gator needs one object per file, so the script extracts the lab workloads from `k8s/` into `policy/tests/fixtures/lab/` (git-ignored) each run. Docker fallback copies the tree to a temp dir because Docker Desktop cannot mount this external-drive path. Verified: suite passes, and fails correctly when an expected count is changed. |
| 4.14 | 2026-09-20 | No static checks. Added `scripts/check.sh` / `make check` (ShellCheck, yamllint with `.yamllint`, kubeconform with Docker fallback, Markdown relative-link check). ShellCheck found three warnings (unused loop variables in `control-plane.sh` and `worker.sh`, unguarded `cd` in `security/run-all.sh`), all fixed. kubeconform: 19 resources valid, 2 skipped (CRD kinds). |
| 4.15 | 2026-09-20 | `make test` hardcoded `192.168.56.11` and `.20`; now read from the Vagrantfile (`NET_PREFIX`, first `worker` and `web` node). `make clean` removed only `api-image.tar`; now `*-image.tar`. A 67 MB leftover `api-image.tar` from an interrupted `make image` was deleted from the checkout. |

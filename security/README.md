# Security testing routines

A set of small, readable checks you can run against the lab cluster to see how a
"works fine" Kubernetes setup looks from an attacker's or auditor's point of view.
Every routine prints PASS / FAIL / WARN lines with a one-line reason and, where it
matters, the fix. They are meant to be read as much as run.

```bash
make sectest                 # everything (Trivy + kube-bench add a few minutes)
make sectest ROUTINE=04      # one routine
SKIP_SLOW=1 make sectest     # skip Trivy and kube-bench
```

Only `kubectl`, `jq`, `curl`, and `nc` are required. `06` needs [Trivy](https://trivy.dev)
(`brew install trivy`) and Docker; `08` pulls the kube-bench image onto the nodes.
All routines clean up after themselves (temporary namespaces `sec-probe`, `sec-psa`,
and the kube-bench Jobs).

| Routine | What it checks | Expected on the stock lab |
|---------|----------------|---------------------------|
| `01-pod-spec-audit` | Pod specs in `devapp`: privileged, host namespaces, hostPath, runAsNonRoot, privilege escalation, read-only root, dropped capabilities, seccomp, limits, image tags, literal credentials in env, SA token automount | FAIL: `DATABASE_URL` embeds the password. WARN: writable root fs, no `drop: [ALL]`, no seccomp, token auto-mounted |
| `02-runtime-probe` | Exec into the API pod: uid, capability mask, writable fs, setuid binaries, SA token and what it can do against the API, credentials in `env`, egress to the internet, tools an attacker would find | FAIL: credentials in env. PASS: non-root, token cannot list secrets |
| `03-rbac-audit` | What the default SA can do, anonymous access, cluster-admin bindings, SAs with admin/edit | All PASS; note that the repo's `kubeconfig` is `system:masters` |
| `04-network-policy` | Reach `postgres:5432` from another namespace, then apply a deny policy and retry | FAIL: Flannel does not enforce NetworkPolicy, so the policy is silently ignored |
| `05-secrets-audit` | Secrets at rest: reads the raw etcd key, checks for `--encryption-provider-config`, credentials in git and in the Deployment, kubeconfig perms | FAIL: password readable verbatim from etcd; FAIL: literal connection string |
| `06-image-scan` | Trivy CVE scan of `devapp/api:dev` and `postgres:16-alpine`, plus misconfig scan of `app/` (Dockerfile) and `k8s/` | Varies with the day's CVE feed |
| `07-pod-security-admission` | Namespace PSA labels; proves `enforce=restricted` blocks a privileged pod; dry-runs the lab workloads against `restricted` to list what they violate | WARN: no labels; WARN: api and postgres violate restricted (capabilities, seccomp) |
| `08-kube-bench` | CIS Kubernetes Benchmark on the control plane and a worker | A few FAILs typical for kubeadm defaults (audit logging, file permissions) |
| `09-exposure` | From the host: open ports per node, kubelet anonymous access, API server anonymous access, Swagger UI exposure | WARN: etcd and controller ports reachable on the LAN; WARN: `/docs` public |

## Turning findings into exercises

1. **Move the password out of the pod spec.** Replace the literal `DATABASE_URL` in
   `k8s/20-api.yaml` with `valueFrom.secretKeyRef` entries. Re-run `01` and `05`.
2. **Pass `restricted`.** Add `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`,
   `readOnlyRootFilesystem: true` (with an `emptyDir` on `/tmp`), and
   `automountServiceAccountToken: false` to the API Deployment. Re-run `07` until it passes,
   then label the namespace with `enforce=restricted`.
3. **Make NetworkPolicy real.** Replace Flannel with Calico, re-run `04`, and watch the deny
   policy start working. This is the single biggest security difference between CNIs.
4. **Encrypt Secrets at rest.** Write an `EncryptionConfiguration`, add
   `--encryption-provider-config` to the kube-apiserver static pod manifest on cp1, and
   rewrite the secrets (`kubectl get secrets -A -o json | kubectl replace -f -`). Re-run `05`.
5. **Close the LAN exposure.** Bind the scheduler and controller-manager to 127.0.0.1 in their
   static pod manifests and add `ufw` rules on the nodes for 2379/2380. Re-run `09`.
6. **Fix a kube-bench item** from the `08` report and re-run it.

Everything here targets your own lab VMs. The same probes against a cluster you do not
own are an attack, not a test.

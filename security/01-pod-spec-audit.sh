#!/usr/bin/env bash
# Static audit of the running pod specs in the app namespace: the settings an attacker
# who lands in a container would love to find missing.
set -uo pipefail
. "$(dirname "$0")/lib.sh"; cluster_ok

section "Pod spec audit in namespace $NS"
PODS="$(kubectl -n "$NS" get pods -o json)"
for pod in $(jq -r '.items[].metadata.name' <<<"$PODS"); do
  P="$(jq --arg p "$pod" '.items[] | select(.metadata.name==$p)' <<<"$PODS")"
  echo "$B$pod$N"
  for flag in hostNetwork hostPID hostIPC; do
    [ "$(jq -r ".spec.$flag // false" <<<"$P")" = "true" ] && fail "$flag: true" || pass "$flag not set"
  done
  if [ "$(jq -r '[.spec.volumes[]? | select(.hostPath)] | length' <<<"$P")" -gt 0 ]; then
    fail "hostPath volume mounted: $(jq -r '[.spec.volumes[] | select(.hostPath) | .hostPath.path] | join(", ")' <<<"$P")"
  else pass "no hostPath volumes"; fi
  sa="$(jq -r '.spec.serviceAccountName // "default"' <<<"$P")"
  automount="$(jq -r 'if .spec.automountServiceAccountToken == null then true else .spec.automountServiceAccountToken end' <<<"$P")"
  if [ "$automount" = "true" ]; then
    warn "service account token ($sa) auto-mounted; the app never calls the API, set automountServiceAccountToken: false"
  else pass "service account token not mounted"; fi
  podSeccomp="$(jq -r '.spec.securityContext.seccompProfile.type // ""' <<<"$P")"

  for c in $(jq -r '.spec.containers[].name' <<<"$P"); do
    C="$(jq --arg c "$c" '.spec.containers[] | select(.name==$c)' <<<"$P")"
    echo "  container $B$c$N ($(jq -r .image <<<"$C"))"
    sc="$(jq '.securityContext // {}' <<<"$C")"
    [ "$(jq -r '.privileged // false' <<<"$sc")" = "true" ] && fail "privileged: true" || pass "not privileged"
    [ "$(jq -r 'if .allowPrivilegeEscalation == null then true else .allowPrivilegeEscalation end' <<<"$sc")" = "false" ] && pass "allowPrivilegeEscalation: false" || fail "allowPrivilegeEscalation not false (setuid binaries can escalate)"
    ranNonRoot="$(jq -r --argjson pod "$(jq '.spec.securityContext // {}' <<<"$P")" 'if .runAsNonRoot != null then .runAsNonRoot elif $pod.runAsNonRoot != null then $pod.runAsNonRoot else false end' <<<"$sc")"
    [ "$ranNonRoot" = "true" ] && pass "runAsNonRoot: true" || fail "runAsNonRoot not set"
    [ "$(jq -r '.readOnlyRootFilesystem // false' <<<"$sc")" = "true" ] && pass "readOnlyRootFilesystem: true" || warn "root filesystem writable (readOnlyRootFilesystem not set)"
    if jq -e '.capabilities.drop // [] | index("ALL")' <<<"$sc" >/dev/null; then pass "capabilities drop ALL"
    else warn "capabilities not dropped (add securityContext.capabilities.drop: [ALL])"; fi
    seccomp="$(jq -r --arg p "$podSeccomp" '.seccompProfile.type // $p' <<<"$sc")"
    case "$seccomp" in RuntimeDefault|Localhost) pass "seccomp profile: $seccomp" ;; *) warn "no seccomp profile (add seccompProfile.type: RuntimeDefault)" ;; esac
    for r in cpu memory; do
      [ "$(jq -r ".resources.limits.$r // empty" <<<"$C")" ] && pass "$r limit set" || fail "no $r limit (a runaway container can starve the node)"
    done
    img="$(jq -r .image <<<"$C")"
    case "$img" in *@sha256:*) pass "image pinned by digest" ;; *:latest|*[!:]*) [[ "$img" == *:* ]] && warn "image tag '${img##*:}' is mutable; pin a digest for anything shared" || fail "image has no tag (implicit :latest)" ;; esac
    # Plaintext credentials handed to the container as literal env values
    leaks="$(jq -r '[.env[]? | select(.value != null) | select(.name | test("PASS|SECRET|TOKEN|KEY|DATABASE_URL"; "i")) | .name] | join(", ")' <<<"$C")"
    [ -n "$leaks" ] && fail "credential in literal env value: $leaks (visible in the pod spec, kubectl describe, and audit logs)" || pass "no literal credentials in env"
    fromSecret="$(jq -r '[.env[]? | select(.valueFrom.secretKeyRef)] + [.envFrom[]? | select(.secretRef)] | length' <<<"$C")"
    [ "$fromSecret" -gt 0 ] && info "$fromSecret secret-backed env entries: readable by anyone who can exec into the pod"
  done
done

section "Cluster-wide: privileged / host-namespace pods (system components are expected)"
kubectl get pods -A -o json | jq -r '
  .items[] | select(
    (.spec.hostNetwork // false) or (.spec.hostPID // false) or
    ([.spec.containers[].securityContext.privileged // false] | any) or
    ([.spec.volumes[]? | select(.hostPath)] | length > 0))
  | "  \(.metadata.namespace)/\(.metadata.name)\thostNet=\(.spec.hostNetwork // false) priv=\([.spec.containers[].securityContext.privileged // false] | any) hostPath=\([.spec.volumes[]? | select(.hostPath)] | length)"' | column -t -s $'\t'
info "Anything outside kube-system / kube-flannel / local-path-storage here deserves a look."

summary

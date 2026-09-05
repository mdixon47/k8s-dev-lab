#!/usr/bin/env bash
# What can a process inside the API container actually do? Exec in and look around.
set -uo pipefail
. "$(dirname "$0")/lib.sh"; cluster_ok

POD="$(kubectl -n "$NS" get pods -l app=api -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
[ -n "$POD" ] || { echo "no api pod found in $NS"; exit 2; }
x() { kubectl -n "$NS" exec "$POD" -c api -- sh -c "$1" 2>/dev/null; }

section "Runtime probe inside $NS/$POD"
uid="$(x 'id -u')"; [ "$uid" != "0" ] && pass "process runs as uid $uid" || fail "process runs as root"

caps="$(x 'grep CapEff /proc/1/status' | awk '{print $2}')"
if [ "$caps" = "0000000000000000" ]; then pass "effective capabilities: none"
else warn "effective capabilities mask $caps (non-root default set; drop ALL to clear it)"; fi

if x 'touch /probe-write-test && rm /probe-write-test'; then warn "root filesystem is writable (malware can persist binaries)"; else pass "root filesystem read-only"; fi
if x 'touch /tmp/probe && rm /tmp/probe'; then info "/tmp writable (fine; use an emptyDir when the root fs is read-only)"; fi

setuid_list="$(x 'find / -xdev -perm -4000 -type f 2>/dev/null' | head -4 | tr '\n' ' ')"
setuid="$(x 'find / -xdev -perm -4000 -type f 2>/dev/null | wc -l' | tr -d ' ')"
[ "${setuid:-0}" -eq 0 ] && pass "no setuid binaries" || warn "$setuid setuid binaries present ($setuid_list)"

if x 'test -r /var/run/secrets/kubernetes.io/serviceaccount/token'; then
  warn "service account token readable at /var/run/secrets/kubernetes.io/serviceaccount/token"
  code="$(x 'python3 - <<"PY"
import ssl,urllib.request
t=open("/var/run/secrets/kubernetes.io/serviceaccount/token").read()
ctx=ssl.create_default_context(cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
req=urllib.request.Request("https://kubernetes.default.svc/api/v1/namespaces/devapp/secrets",headers={"Authorization":"Bearer "+t})
try: print(urllib.request.urlopen(req,context=ctx).status)
except urllib.error.HTTPError as e: print(e.code)
PY')"
  case "$code" in 200) fail "token can list secrets in $NS (HTTP 200)" ;; 403) pass "token cannot list secrets (HTTP 403): RBAC holds even though the token is exposed" ;; *) info "API probe returned '$code'" ;; esac
else pass "no service account token mounted"; fi

envleak="$(x 'env' | grep -iE 'pass|secret|token|database_url' | cut -d= -f1 | tr '\n' ' ')"
[ -n "$envleak" ] && fail "credentials readable from the environment: $envleak" || pass "no credentials in environment"

if x "python3 -c \"import socket; socket.create_connection(('postgres.$NS.svc.cluster.local',5432),3)\""; then info "postgres:5432 reachable from the API pod (expected)"; fi
if x "python3 -c \"import socket; socket.create_connection(('1.1.1.1',443),3)\""; then warn "egress to the internet allowed (no egress NetworkPolicy); fine for a lab, worth restricting in prod"; else pass "no egress to the internet"; fi
NODEIP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')"
if x "python3 -c \"import socket; socket.create_connection(('$NODEIP',10250),3)\""; then
  warn "kubelet port 10250 on node $NODEIP is reachable from the pod (auth still required; see 09-exposure)"; fi

tools="$(x 'for t in curl wget nc nmap python3 gcc; do command -v $t >/dev/null && printf "%s " $t; done')"
info "tooling available to an attacker in the image: ${tools:-none}"

summary

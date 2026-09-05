#!/usr/bin/env bash
# Known CVEs in the images, and misconfigurations in the Dockerfile and manifests (Trivy).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
need trivy "brew install trivy" || { summary; exit; }

section "Image vulnerabilities (HIGH/CRITICAL)"
for img in devapp/api:dev postgres:16-alpine; do
  out="$(trivy image --quiet --scanners vuln --severity HIGH,CRITICAL --format json "$img" 2>/dev/null)" || { skip "$img: scan failed (is the image present in Docker? run make image)"; continue; }
  crit="$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' <<<"$out")"
  high="$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' <<<"$out")"
  if [ "$crit" -gt 0 ]; then fail "$img: $crit CRITICAL, $high HIGH"
  elif [ "$high" -gt 0 ]; then warn "$img: $high HIGH, 0 CRITICAL"
  else pass "$img: no HIGH/CRITICAL vulnerabilities"; fi
  jq -r '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL" or .Severity=="HIGH")] | sort_by(.Severity) | .[:5][] | "        \(.Severity) \(.VulnerabilityID) \(.PkgName) \(.InstalledVersion) -> \(.FixedVersion // "no fix")"' <<<"$out"
done
info "Rebuild with a newer base (python:3.12-slim / postgres:16-alpine are rolling tags) to pick up fixes."

section "Dockerfile and manifest misconfigurations"
for path in app k8s; do
  out="$(trivy config --quiet --severity HIGH,CRITICAL --format json "$ROOT/$path" 2>/dev/null)"
  n="$(jq '[.Results[]?.Misconfigurations[]?] | length' <<<"$out")"
  [ "$n" -eq 0 ] && pass "$path/: no HIGH/CRITICAL misconfigurations" || warn "$path/: $n HIGH/CRITICAL misconfigurations"
  jq -r '.Results[]? | .Target as $t | .Misconfigurations[]? | "        \(.Severity) \(.ID) \($t): \(.Title)"' <<<"$out" | head -12
done

summary

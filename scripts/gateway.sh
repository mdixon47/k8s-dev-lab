#!/usr/bin/env bash
# Gateway training stack (make gateway): MetalLB (so LoadBalancer Services get an address
# on the host-only network), Envoy Gateway and Istio (both driven through the Kubernetes
# Gateway API), then the lab's Gateways and HTTPRoutes from gateway/. Everything comes from
# pinned Helm charts and is re-runnable (helm upgrade --install).
# Uninstall: scripts/gateway.sh uninstall
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-$ROOT/kubeconfig}"
METALLB_VERSION="${METALLB_VERSION:-0.16.1}"
ENVOY_GATEWAY_VERSION="${ENVOY_GATEWAY_VERSION:-v1.9.1}"
ISTIO_VERSION="${ISTIO_VERSION:-1.30.5}"

if [ "${1:-}" = "uninstall" ]; then
  kubectl delete -f "$ROOT/gateway/40-routes.yaml" -f "$ROOT/gateway/30-istio-gateway.yaml" \
    -f "$ROOT/gateway/20-envoy-gateway.yaml" --ignore-not-found
  helm uninstall istiod -n istio-system 2>/dev/null || true
  helm uninstall istio-base -n istio-system 2>/dev/null || true
  helm uninstall eg -n envoy-gateway-system 2>/dev/null || true
  kubectl delete -f "$ROOT/gateway/10-metallb-pool.yaml" --ignore-not-found
  helm uninstall metallb -n metallb-system 2>/dev/null || true
  kubectl delete -f "$ROOT/gateway/00-namespaces.yaml" --ignore-not-found --wait=false
  echo "Gateway stack removed (CRDs from the charts are left in place; kubectl get crd | grep -E 'gateway|istio|metallb' to see them)"
  exit 0
fi

command -v helm >/dev/null || { echo "ERROR: helm is required (brew install helm)" >&2; exit 1; }

echo "==> Namespaces"
kubectl apply -f "$ROOT/gateway/00-namespaces.yaml"

echo "==> MetalLB ${METALLB_VERSION} (layer 2 on 192.168.56.100-110)"
helm repo add metallb https://metallb.github.io/metallb >/dev/null
helm repo update metallb >/dev/null
helm upgrade --install metallb metallb/metallb --version "$METALLB_VERSION" -n metallb-system --wait --timeout 5m
# The pool goes through MetalLB's validating webhook, which needs the controller up
kubectl apply -f "$ROOT/gateway/10-metallb-pool.yaml"

echo "==> Gateway API CRDs (standard channel) + Envoy Gateway CRDs, from the ${ENVOY_GATEWAY_VERSION} crds chart"
# The CRDs are applied separately from the controller chart so the training can show them
# and so they can be adjusted: Gateway API v1.6 validates TLSRoute hostnames with CEL's
# isIP(), which API servers before 1.31 do not have and reject. The rule is dropped on
# those servers; TLSRoute is not used here. (Kubernetes 1.36 in the Vagrantfile has it.)
CRDS="$(mktemp)"
helm template eg oci://docker.io/envoyproxy/gateway-crds-helm --version "$ENVOY_GATEWAY_VERSION" \
  --set crds.gatewayAPI.enabled=true --set crds.gatewayAPI.channel=standard \
  --set crds.envoyGateway.enabled=true >"$CRDS"
SERVER_MINOR="$(kubectl version -o json 2>/dev/null | sed -nE 's/.*"minor": *"([0-9]+).*/\1/p' | tail -1)"
if [ "${SERVER_MINOR:-0}" -lt 31 ]; then
  echo "    API server 1.${SERVER_MINOR} lacks CEL isIP(); dropping that TLSRoute hostname rule"
  sed -i.bak '/message: Hostnames cannot contain an IP/{N;d;}' "$CRDS"
fi
kubectl apply --server-side --force-conflicts -f "$CRDS" >/dev/null
rm -f "$CRDS" "$CRDS.bak"
kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='    Gateway API bundle {.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'

echo "==> Envoy Gateway ${ENVOY_GATEWAY_VERSION}"
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version "$ENVOY_GATEWAY_VERSION" \
  -n envoy-gateway-system --set crds.enabled=false --wait --timeout 5m

echo "==> Istio ${ISTIO_VERSION} (istiod only; the ingress gateway is deployed from the Gateway object)"
helm repo add istio https://istio-release.storage.googleapis.com/charts >/dev/null
helm repo update istio >/dev/null
helm upgrade --install istio-base istio/base --version "$ISTIO_VERSION" -n istio-system --set defaultRevision=default
# istiod asks for 2 GB of memory by default, more than a lab worker has; 256Mi is plenty
# for one gateway and no sidecars.
helm upgrade --install istiod istio/istiod --version "$ISTIO_VERSION" -n istio-system \
  --set pilot.resources.requests.cpu=100m --set pilot.resources.requests.memory=256Mi \
  --wait --timeout 5m

echo "==> Gateways and routes"
kubectl apply -f "$ROOT/gateway/20-envoy-gateway.yaml" -f "$ROOT/gateway/30-istio-gateway.yaml"
kubectl apply -f "$ROOT/gateway/40-routes.yaml"
for gw in eg istio; do
  kubectl -n gateways wait gateway/"$gw" --for=condition=Programmed --timeout=180s
done
kubectl -n gateways get gateway
echo "Envoy Gateway: http://192.168.56.100/   Istio: http://192.168.56.101/   (routes: kubectl -n devapp get httproute)"

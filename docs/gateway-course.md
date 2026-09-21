# Gateway Training: Envoy Gateway and Istio Ingress Gateway

## Ten lessons on the Kubernetes Gateway API, run twice

Every lesson runs on the lab from [README.md](../README.md) with the sample app deployed
(`make all`). It installs two ingress implementations side by side, **Envoy Gateway** and
**Istio's ingress gateway**, drives both through the same Kubernetes **Gateway API**
objects, and puts one `HTTPRoute` in front of the lab's `api` and `web` Services on each.
That is the method of the course: the same routing served by two implementations, so what
is portable (the API) and what is not (rate limits, authorization, where the proxy pods
live) shows up as a difference you can `curl`.

Every command was run against the lab on 2026-09-21 and the outputs shown are what came
back. **Lab note** blocks mark where the lab differs from a production cluster.

Read [learn.md](learn.md) §2.6 (Services, NodePort) and the README's "The web edge" first;
this course starts where they stop.

```
Mac ──▶ 192.168.56.100 ──▶ Envoy Gateway proxy (envoy-gateway-system) ─┐
                                                                      ├──▶ HTTPRoute api ──▶ Service api ──▶ api pods
Mac ──▶ 192.168.56.101 ──▶ Istio gateway pod (gateways) ───────────────┘    HTTPRoute web ──▶ Service web ──▶ web pods
                 ▲
        MetalLB answers ARP for both addresses from one worker each
```

**Cost.** The stack requests about 1.2 GB of memory across the two workers (Envoy Gateway
800 Mi, istiod 256 Mi, the Istio gateway 128 Mi, MetalLB none). With the app and Gatekeeper
already running, w1 and w2 sit at roughly 70–80 % of requests. Run `make snapshot` before
starting; `make gateway-uninstall` also takes everything out again.

---

# Lesson 1 — Why a Gateway

## Objective

Understand what the lab exposes today and what the Gateway API replaces.

Today the app is reachable three ways: the `api` and `web` NodePorts on every worker
(30080, 30081), and the `web` VM's nginx that proxies to those NodePorts with failover.
NodePorts are the Service's own escape hatch: a high port on every node, no hostnames, no
paths, no TLS, one Service each. The nginx VM adds all of that, by hand, outside the
cluster, in a config file nobody in Kubernetes can see.

`Ingress` was Kubernetes' first answer: one object, one controller, and an
`annotations:` block per controller for everything the spec left out. The **Gateway API**
is its replacement, and it is built around who owns what:

| Object | Owner | Says |
|--------|-------|------|
| `GatewayClass` | the implementation (installed with it) | "this controller exists": `gateway.envoyproxy.io/...`, `istio.io/gateway-controller` |
| `Gateway` | cluster operator | listeners: ports, protocols, TLS, which namespaces may attach routes |
| `HTTPRoute` | application team | hostnames, paths, headers, rewrites, which Services get the traffic |

A route names the Gateways it wants (`parentRefs`); a Gateway says which routes it accepts
(`allowedRoutes`). Both sides must agree. That handshake is most of what makes the API
safe to hand to several teams.

## Lab

```bash
export KUBECONFIG="$PWD/kubeconfig"
kubectl -n devapp get svc                      # NodePort 30080 and 30081
curl -s http://192.168.56.11:30080/healthz     # a worker's NodePort
curl -s http://192.168.56.20/api/healthz       # the edge VM in front of it
kubectl get crd | grep gateway.networking      # nothing yet: the API is not part of Kubernetes
```

The last line is the point: the Gateway API is CRDs. Something has to install them.

---

# Lesson 2 — Install the Stack

## Objective

Install MetalLB, Envoy Gateway and Istio from pinned Helm charts, and read what arrived.

```bash
make gateway          # 3-5 minutes; needs helm on the host (brew install helm)
```

What `scripts/gateway.sh` does, in order:

1. Creates four namespaces from `gateway/00-namespaces.yaml`, each labelled `owner: lab`.
2. MetalLB 0.16.1 (chart), then the address pool `192.168.56.100-110` (lesson 3).
3. The Gateway API CRDs (standard channel) and Envoy Gateway's own CRDs, from Envoy
   Gateway's `gateway-crds-helm` chart, applied server-side.
4. Envoy Gateway v1.9.1 (chart, with its CRD install switched off since step 3 did it).
5. Istio 1.30.5: the `base` chart (Istio CRDs) and `istiod` with its memory request cut
   from 2 GB to 256 Mi. No sidecars, no ambient mesh; only the control plane, which is all
   an ingress gateway needs.
6. `gateway/20-envoy-gateway.yaml`, `30-istio-gateway.yaml`, `40-routes.yaml`, then waits
   for both Gateways to report `Programmed`.

**Lab note (why the namespaces come first).** Both charts can `--create-namespace`, but a
namespace created that way carries no labels. The course's `K8sRequiredLabels` constraint
(lesson 25 of [course.md](course.md)), if you left it in `deny`, rejects that. Creating
namespaces yourself, labelled, is the habit anyway.

**Lab note (Kubernetes 1.30).** Gateway API v1.6 validates `TLSRoute` hostnames with the
CEL function `isIP()`, which API servers older than 1.31 do not have; they reject the CRD
outright. On such a server the script drops that one rule (the course never uses
`TLSRoute`). The Vagrantfile now builds 1.36 clusters, where nothing is dropped. This is
what a "supported Kubernetes versions" line in a project's docs is about.

## Inspect

```bash
kubectl get crd | grep -E 'gateway|istio|metallb' | wc -l       # ~50
kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'   # v1.6.1
kubectl get gatewayclass
```

```text
NAME           CONTROLLER                                      ACCEPTED   AGE
eg             gateway.envoyproxy.io/gatewayclass-controller   True       59s
istio          istio.io/gateway-controller                     True       61s
istio-remote   istio.io/unmanaged-gateway                      True       61s
```

`eg` came from `gateway/20-envoy-gateway.yaml`; the two `istio*` classes were created by
istiod itself the moment it found the Gateway API CRDs. (`istio-remote` is for gateways
Istio does not deploy; ignore it.)

```bash
kubectl get pods -A -o wide | grep -E 'envoy-gateway|istio|metallb|^gateways'
kubectl -n gateways get gateway
```

```text
NAME    CLASS   ADDRESS          PROGRAMMED   AGE
eg      eg      192.168.56.100   True         13s
istio   istio   192.168.56.101   True         13s
```

Two gateways, two addresses, both programmed. Lessons 3 to 6 explain each column.

---

# Lesson 3 — Where Does the Address Come From? (MetalLB)

## Objective

Understand why `type: LoadBalancer` does nothing on a bare cluster and what MetalLB does
about it.

Both gateways expose their proxy through a Service of `type: LoadBalancer`:

```bash
kubectl get svc -A | grep LoadBalancer
```

```text
envoy-gateway-system  envoy-gateways-eg-ebce27fe  LoadBalancer  ...  192.168.56.100  80:31098/TCP
gateways              istio-istio                 LoadBalancer  ...  192.168.56.101  15021:30711/TCP,80:31282/TCP
```

On a cloud cluster the provider's controller sees that Service and provisions a load
balancer; `EXTERNAL-IP` fills in a minute later. This cluster has no such controller, so
without MetalLB the column reads `<pending>` forever and the gateways are reachable only
through the NodePorts you can see after the colon (31098, 31282).

**MetalLB in layer-2 mode** takes an address from its pool, writes it into the Service,
and elects one node to answer ARP for it. Traffic for `.100` arrives at that node's NIC
and kube-proxy forwards it to the proxy pod, wherever it runs. No routing protocol, no
cloud: it works on the VirtualBox host-only network.

## Lab

```bash
kubectl -n metallb-system get ipaddresspool,l2advertisement
kubectl -n metallb-system get servicel2status \
  -o custom-columns='SVC:.status.serviceName,NODE:.status.node'
```

```text
SVC                          NODE
istio-istio                  w2
envoy-gateways-eg-ebce27fe   w1
```

Prove it from the Mac. ARP resolves each address to the MAC of the node that owns it:

```bash
curl -s http://192.168.56.100/api/healthz >/dev/null
arp -n 192.168.56.100                                    # ... at 8:0:27:61:fd:f4 ...
vagrant ssh w1 -c "ip -o link show eth1 | awk '{print \$17}'"   # 08:00:27:61:fd:f4, the same MAC
```

The Gateway asked for its exact address (`spec.addresses` in the manifests), which is
standard Gateway API and honoured by MetalLB through both implementations. Without it the
pool hands out addresses in order, which is fine until you rebuild and the numbers swap.

## Exercise

`vagrant halt w1`, then poll `servicel2status` and `curl` `.100`. MetalLB moves the
address to another node once w1 is NotReady (about a minute); clients' ARP caches take a
few seconds more. `vagrant up w1` afterwards. (This one is not in the verified set; write
down what you observe.)

---

# Lesson 4 — Envoy Gateway

## Objective

Follow one Gateway object through to a running Envoy.

`gateway/20-envoy-gateway.yaml` has two objects. The `GatewayClass` names a controller.
The `Gateway` is a listener set: here one HTTP listener on port 80 that accepts routes
from any namespace.

Envoy Gateway watches Gateways of its class and, for each, creates a **Deployment and a
Service in its own namespace**:

```bash
kubectl -n envoy-gateway-system get deploy,svc
```

```text
deployment.apps/envoy-gateway                 1/1     # the controller
deployment.apps/envoy-gateways-eg-ebce27fe    1/1     # the data plane for Gateway gateways/eg
service/envoy-gateways-eg-ebce27fe   LoadBalancer   192.168.56.100
```

Control plane and data plane are separate pods. The controller translates Gateway API
objects into Envoy configuration and pushes it over xDS; the proxy pod is a stock Envoy
that would keep serving if the controller died (lesson 9 proves it).

`Programmed=True` on the Gateway means the proxy is up and configured. Read the whole
status, it is verbose on purpose:

```bash
kubectl -n gateways describe gateway eg | sed -n '/^Status/,$p'
```

Note `Attached Routes: 2` under the listener. Then:

```bash
curl -s http://192.168.56.100/api/healthz     # {"status":"ok","pod":"api-..."}
curl -sI http://192.168.56.100/api/healthz | grep -i server    # server: uvicorn
```

Envoy Gateway passes the backend's `Server` header through untouched. Remember that for
lesson 6.

---

# Lesson 5 — HTTPRoute: The Application Team's Object

## Objective

Read `gateway/40-routes.yaml` and understand attachment, matching and rewriting.

Two routes live in `devapp`, next to the Services they point at. Each lists **both**
Gateways in `parentRefs`. The `api` route:

| Rule | Match | Filter | Backend |
|------|-------|--------|---------|
| 0 | `PathPrefix /api/` | `URLRewrite` replaces the prefix with `/` | `api:80` |
| 1 | `Exact /docs`, `Exact /openapi.json` | none | `api:80` |

The `web` route sends `PathPrefix /` to `web:80`. Longer prefixes win, so `/api/notes`
goes to rule 0 of `api` and everything unmatched to `web`. This is exactly what
`web/nginx.conf` does inside the site container, expressed in the API instead of a
config file.

## Status is per parent

```bash
kubectl -n devapp get httproute api -o jsonpath='{range .status.parents[*]}{.controllerName}{" -> "}{.parentRef.name}{": "}{.conditions[?(@.type=="Accepted")].status}{"\n"}{end}'
```

```text
istio.io/gateway-controller -> istio: True
gateway.envoyproxy.io/gatewayclass-controller -> eg: True
```

Each implementation writes its own entry. A route can be accepted by one gateway and
rejected by another, and you find out here, not from a 404.

## Lab: the handshake

Tighten the Envoy listener so only routes from the `gateways` namespace may attach:

```bash
kubectl -n gateways patch gateway eg --type json \
  -p '[{"op":"replace","path":"/spec/listeners/0/allowedRoutes/namespaces/from","value":"Same"}]'
sleep 15
kubectl -n devapp get httproute api -o jsonpath='{range .status.parents[?(@.parentRef.name=="eg")]}{range .conditions[*]}{.type}={.status} ({.reason}) {end}{"\n"}{end}'
kubectl -n gateways get gateway eg -o jsonpath='{range .status.listeners[*]}{.name}: attachedRoutes={.attachedRoutes}{"\n"}{end}'
curl -s -o /dev/null -w '%{http_code}\n' http://192.168.56.100/api/healthz
```

```text
Accepted=False (NotAllowedByListeners) ResolvedRefs=True (ResolvedRefs)
http: attachedRoutes=0
404
```

The route did nothing wrong; the Gateway stopped consenting. Istio on `.101` is
untouched. Restore with `kubectl apply -f gateway/20-envoy-gateway.yaml`.

Production uses a `Selector` between these extremes: `from: Selector` with a namespace
label such as `gateway-access: "true"`, so a namespace has to be admitted before its routes
count.

---

# Lesson 6 — Istio Ingress Gateway

## Objective

Run the same Gateway object on Istio and see what is different.

`gateway/30-istio-gateway.yaml` is the Envoy one with `gatewayClassName: istio` and the
next address. istiod handles it with **automated deployment**: it creates a Deployment
and Service named `istio-<gateway>` **in the Gateway's own namespace**:

```bash
kubectl -n gateways get deploy,svc,pod
```

```text
deployment.apps/istio-istio   1/1
service/istio-istio   LoadBalancer   192.168.56.101   15021:30711/TCP,80:31282/TCP
pod/istio-istio-cd75f58d4-smb6d   1/1   Running
```

Compare with lesson 4: Envoy Gateway centralises proxies in its namespace; Istio puts the
proxy where the Gateway is. Port 15021 is the gateway's health endpoint, the same one a
sidecar has: this pod *is* an Istio proxy (`pilot-agent` + Envoy), just with no
application next to it.

Both implementations serve the routes identically:

```bash
for ip in 100 101; do
  for p in /api/healthz /api/notes /docs /; do
    printf '%s %-13s ' $ip $p; curl -s -o /dev/null -w '%{http_code}\n' http://192.168.56.$ip$p
  done
done
```

All eight return `200`. The tell is in the headers:

```bash
curl -sI http://192.168.56.101/api/healthz | grep -iE '^(server|x-envoy)'
```

```text
server: istio-envoy
x-envoy-upstream-service-time: 0
```

Istio rewrites `Server` and adds timing headers; Envoy Gateway leaves them alone. Same
Envoy underneath, different defaults, and a header-based fingerprint an attacker reads
first (security routine 09 is about exactly this kind of exposure).

**Lab note.** Istio also has its own older objects, `Gateway` (`networking.istio.io`) and
`VirtualService`. They still work and much documentation uses them, but Istio's own
recommendation for ingress is the Gateway API, and everything in this course would need
rewriting to move to them. Prefer the portable objects.

---

# Lesson 7 — TLS Termination, Once for Both

## Objective

Add an HTTPS listener with the standard API and watch it work on both implementations.

A `Gateway` listener with `protocol: HTTPS` and `tls.mode: Terminate` references a
`kubernetes.io/tls` Secret **in the Gateway's namespace** (a Secret elsewhere needs a
`ReferenceGrant`, the same consent pattern as lesson 5, for Secrets).

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj '/CN=lab.local' \
  -addext 'subjectAltName=DNS:lab.local,IP:192.168.56.100,IP:192.168.56.101' \
  -keyout /tmp/tls.key -out /tmp/tls.crt
kubectl -n gateways create secret tls lab-tls --cert=/tmp/tls.crt --key=/tmp/tls.key
for gw in eg istio; do
  kubectl -n gateways patch gateway $gw --type json -p '[{"op":"add","path":"/spec/listeners/-","value":
    {"name":"https","port":443,"protocol":"HTTPS","tls":{"mode":"Terminate","certificateRefs":[{"name":"lab-tls"}]},
     "allowedRoutes":{"namespaces":{"from":"All"}}}}]'
done
sleep 15
for ip in 100 101; do curl -sk -o /dev/null -w "$ip -> %{http_code}\n" https://192.168.56.$ip/api/healthz; done
echo | openssl s_client -connect 192.168.56.101:443 2>/dev/null | grep -E 'subject=|issuer='
```

```text
100 -> 200
101 -> 200
subject=CN=lab.local
issuer=CN=lab.local
```

The routes did not change: they attach to listeners by name/port only when they say so,
and these say nothing, so they attach to both. One certificate rotation is now a Secret
update, on both gateways, with no proxy restart.

**Lab note.** `kubectl apply -f gateway/20-envoy-gateway.yaml` (as lesson 5's restore does)
removes the listener again, because the file does not have it. Make it permanent by adding
the listener to the file, which is the exercise: do it and re-apply.

---

# Lesson 8 — Where Portability Ends: Implementation Policies

## Objective

Use each implementation's own extension and see the other one ignore it.

The Gateway API deliberately covers only what every implementation can do. Everything
else is **policy attachment**: an implementation-specific object that points at a
standard one (`targetRefs`) and adds behaviour, so the route's owner never has to edit
the route. `gateway/examples/` has one for each side.

**Envoy Gateway: a local rate limit** (`BackendTrafficPolicy`, 5 requests/second on the
`api` route):

```bash
kubectl apply -f gateway/examples/envoy-ratelimit.yaml
sleep 5
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} ' http://192.168.56.100/api/healthz; done; echo
for i in $(seq 1 10); do curl -s -o /dev/null -w '%{http_code} ' http://192.168.56.101/api/healthz; done; echo
```

```text
200 200 200 200 200 429 429 429 429 429      # Envoy Gateway
200 200 200 200 200 200 200 200 200 200      # Istio: same route, no policy
```

**Istio: an `AuthorizationPolicy` on the Gateway** that denies `/docs` and
`/openapi.json` at the edge (security routine 09 flags the public Swagger UI):

```bash
kubectl apply -f gateway/examples/istio-authz.yaml
sleep 5
for ip in 100 101; do curl -s -o /dev/null -w "$ip /docs -> %{http_code}\n" http://192.168.56.$ip/docs; done
```

```text
100 /docs -> 200      # Envoy Gateway does not know the kind
101 /docs -> 403      # Istio enforces it, on HTTPS too
```

Read both files. Each names the standard object it attaches to, and each has a `status`
block the implementation fills (`kubectl -n devapp describe backendtrafficpolicy`). The
lesson: moving from one implementation to the other moves the Gateways and routes as they
are, and every policy has to be rewritten. Keep the count of those objects low and their
intent documented.

---

# Lesson 9 — Under the Hood: Two Envoys

## Objective

Read the running proxy configuration and break the control planes.

Both data planes are Envoy, and every Envoy has an admin API. Port-forward to each:

```bash
EGDEP=$(kubectl -n envoy-gateway-system get deploy -l gateway.envoyproxy.io/owning-gateway-name=eg -o name)
kubectl -n envoy-gateway-system port-forward $EGDEP 19000:19000 &
kubectl -n gateways port-forward deploy/istio-istio 15000:15000 &
sleep 4
curl -s localhost:19000/clusters | cut -d: -f1 | grep devapp | sort -u
curl -s localhost:15000/clusters | grep -oE '^outbound\|80\|\|[a-z]+\.devapp[^:]*' | sort -u
```

```text
httproute/devapp/api/rule/0                    # Envoy Gateway names clusters after the route rule
httproute/devapp/api/rule/1
httproute/devapp/web/rule/0
outbound|80||api.devapp.svc.cluster.local       # Istio names them after the Service
outbound|80||web.devapp.svc.cluster.local
```

Same Envoy concept (a *cluster* is a set of upstream endpoints), different naming, which
is what you grep for when a route misbehaves. The rate limiter from lesson 8 has counters:

```bash
curl -s 'localhost:19000/stats?filter=local_rate_limit' | grep -E 'enforced|rate_limited'
kill %1 %2
```

## Failure drills

1. **Delete a route.** `kubectl -n devapp delete httproute web`; `/` returns `404` on both
   within seconds. `kubectl apply -f gateway/40-routes.yaml` brings it back. The proxies
   reconfigure live; no pod restarts.
2. **Stop the Envoy Gateway data plane.**
   `kubectl -n envoy-gateway-system scale $EGDEP --replicas=0`. `.100` stops answering
   (`curl` exits 28, timeout: MetalLB still advertises the address, there is just nothing
   behind it) while `.101` serves. Scale back to 1.
3. **Stop Istio's control plane.** `kubectl -n istio-system scale deploy istiod --replicas=0`.
   `.101` keeps returning `200`: the gateway pod already has its configuration and needs
   istiod only for changes. Apply a route change now and it will not take effect until
   istiod is back. Scale it to 1.

Drill 3 is the most important operational fact about both products: the control plane
being down is an outage for *changes*, not for *traffic*. It is also why a gateway pod
restart during a control-plane outage is the thing to avoid.

---

# Lesson 10 — Capstone: The Edge Talks to the Gateways

## Scenario

The `web` VM's nginx still proxies to the NodePorts. Move it to the gateways, so the lab's
entry point is the same object model as the cluster, with the two implementations as a
failover pair.

`gateway/examples/edge-gateway.conf` is a complete replacement for the edge's site config.
Install it and test:

```bash
vagrant ssh web -c 'sudo cp /vagrant/gateway/examples/edge-gateway.conf /etc/nginx/sites-available/edge && sudo nginx -t && sudo systemctl reload nginx'
for p in /api/healthz /docs /; do curl -s -o /dev/null -w "edge $p -> %{http_code}\n" http://192.168.56.20$p; done
curl -sk -o /dev/null -w "edge https / -> %{http_code}\n" https://192.168.56.20/
```

All `200`. Now read the file, because two lines in it were found the hard way:

- **`proxy_http_version 1.1;`** nginx proxies with HTTP/1.0 unless told otherwise, and
  Envoy (both gateways) answers HTTP/1.0 with **`426 Upgrade Required`**. Try it:
  `curl -0 -s -o /dev/null -w '%{http_code}\n' http://192.168.56.100/` → `426`. Without
  the directive the edge served `/api/healthz` (by accident, through the *web* route) and
  failed `/`.
- **`proxy_pass http://gateway;`** with no trailing slash. The NodePort config used
  `http://api/` to strip `/api/`; the HTTPRoute now does that rewrite, and stripping it
  twice sends `/healthz` to the wrong route.

## Failover between implementations

```bash
kubectl -n envoy-gateway-system scale $EGDEP --replicas=0
for i in 1 2 3; do curl -s -o /dev/null -w 'edge -> %{http_code} in %{time_total}s\n' http://192.168.56.20/api/healthz; done
```

```text
edge -> 200 in 3.010298s      # tried .100, 3 s connect timeout, then .101
edge -> 200 in 0.004617s      # round-robin sent this one to .101 directly
edge -> 200 in 3.009521s
```

After two failures within `fail_timeout` nginx marks `.100` down for 10 s and the delay
disappears. Scale the proxy back to 1, then put the edge back on NodePorts:

```bash
kubectl -n envoy-gateway-system scale $EGDEP --replicas=1
vagrant provision web --provision-with web
```

## Evidence to keep

`kubectl -n gateways get gateway`, `kubectl -n devapp get httproute -o wide`, the ARP line
from lesson 3, the two header sets from lesson 6, the `429`/`403` lines from lesson 8, the
cluster names from lesson 9, and the three failover timings.

---

# Comparison

| | Envoy Gateway | Istio ingress gateway |
|---|---|---|
| Installs | one controller; proxies created per Gateway | istiod; proxies created per Gateway |
| Proxy pods live in | `envoy-gateway-system` | the Gateway's namespace |
| Gateway API support | native, the project's only API | native, plus Istio's own `Gateway`/`VirtualService` |
| Extensions | `BackendTrafficPolicy`, `SecurityPolicy`, `ClientTrafficPolicy`, `EnvoyPatchPolicy` | `AuthorizationPolicy`, `RequestAuthentication`, `Telemetry`, `EnvoyFilter` |
| Also gives you | an API gateway (rate limits, JWT, OIDC, ext-auth) | a service mesh when you want one (sidecars or ambient), mTLS to backends |
| Memory here | ~800 Mi requested | ~384 Mi requested (istiod + one gateway) |
| Pick it when | ingress/API gateway is the whole job | the cluster runs (or will run) Istio anyway |

Both are CNCF projects built on Envoy. The Gateway API is what keeps the choice cheap to
revisit: lessons 4 to 7 and 10 apply to either without edits, lesson 8 does not.

---

# Cleanup

```bash
kubectl delete -f gateway/examples/envoy-ratelimit.yaml -f gateway/examples/istio-authz.yaml
kubectl -n gateways delete secret lab-tls
make gateway-uninstall        # Helm releases, Gateways, routes, namespaces; CRDs stay
```

Or `make restore` to the snapshot from before lesson 2.

---

# Knowledge Check

1. Which object does the application team own, and what stops it from attaching to a
   Gateway it should not use?
2. `kubectl get svc` shows `EXTERNAL-IP <pending>` for a gateway Service. Name the missing
   component and what it does at layer 2.
3. A route reports `Accepted=True` for Istio and `Accepted=False (NotAllowedByListeners)`
   for Envoy Gateway. Who has to change what?
4. Where does an Istio-deployed gateway pod run, and where does an Envoy Gateway one?
5. Which of these move unchanged between the two implementations: an HTTPS listener, a
   `URLRewrite` filter, a rate limit, a path-based deny rule?
6. istiod is down. Which of these still work: serving existing routes, applying a new
   route, a gateway pod restart?
7. The edge returns `426`. What is wrong and where?
8. Both proxies are Envoy. Give the admin-API port of each and the name of the cluster
   that serves `api.devapp` on each.
9. Why did `make gateway` create the namespaces itself instead of letting Helm do it?
10. What would you have to rewrite to switch this cluster from Envoy Gateway to Istio, and
    what would you not?

KUBECONFIG ?= $(CURDIR)/kubeconfig
KUBECTL     = KUBECONFIG="$(KUBECONFIG)" kubectl

# make up VBOX_APP=0 leaves the VirtualBox Manager closed (CI, ssh sessions)
VBOX_APP   ?= 1
GATEKEEPER_VERSION ?= v3.23.1
# Rollout waits in `deploy`: without one a missing StorageClass or image blocks forever
ROLLOUT_TIMEOUT ?= 180s
# Name used by `snapshot` / `restore` (make snapshot SNAP=before-calico)
SNAP ?= base
# Node addresses used by `test`, read from the Vagrantfile so renumbering NODES is enough
NET_PREFIX := $(shell sed -nE 's/^NET_PREFIX *= *"([^"]+)".*/\1/p' Vagrantfile)
WORKER_IP  := $(NET_PREFIX).$(shell grep -m1 'role: "worker"' Vagrantfile | sed -E 's/.*NET_PREFIX\}\.([0-9]+)".*/\1/')
EDGE_IP    := $(NET_PREFIX).$(shell grep -m1 'role: "web"' Vagrantfile | sed -E 's/.*NET_PREFIX\}\.([0-9]+)".*/\1/')
# Cluster members according to the Vagrantfile; `status` warns when the cluster has fewer
CLUSTER_NODES := $(shell grep -cE 'role: "(control-plane|worker)"' Vagrantfile)

.PHONY: all up vbox down storage image deploy policy policy-test check status logs test sectest snapshot restore clean

all: up storage image deploy test   ## Fresh clone to running app in one command

up: vbox       ## Open VirtualBox, then create the 3-node cluster (15-20 min first run)
	vagrant up

vbox:          ## Launch and bring the VirtualBox Manager to the front so the VMs are visible as they boot
	@if [ "$(VBOX_APP)" = "1" ]; then \
	  case "$$(uname -s)" in \
	    Darwin) open -a VirtualBox 2>/dev/null || echo "VirtualBox.app not found; VMs still boot headless" ;; \
	    Linux)  if [ -n "$$DISPLAY$$WAYLAND_DISPLAY" ] && command -v VirtualBox >/dev/null 2>&1; then \
	              pgrep -x VirtualBox >/dev/null || (VirtualBox >/dev/null 2>&1 &); \
	            fi ;; \
	  esac; \
	fi

down:          ## Stop VMs, keep state
	vagrant halt

storage:       ## Install local-path storage provisioner and make it default
	$(KUBECTL) apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml
	$(KUBECTL) patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

image:         ## Build the api and web images and load them onto the workers (make image IMAGES=web)
	./scripts/load-image.sh $(IMAGES)

deploy:        ## Apply all manifests
	$(KUBECTL) apply -f k8s/
	$(KUBECTL) -n devapp rollout status statefulset/postgres --timeout=$(ROLLOUT_TIMEOUT)
	$(KUBECTL) -n devapp rollout status deployment/api --timeout=$(ROLLOUT_TIMEOUT)
	$(KUBECTL) -n devapp rollout status deployment/web --timeout=$(ROLLOUT_TIMEOUT)

policy:        ## Install OPA Gatekeeper and the lab's constraints (policy/); GATEKEEPER_VERSION=vX.Y.Z to pin
	KUBECONFIG="$(KUBECONFIG)" GATEKEEPER_VERSION="$(GATEKEEPER_VERSION)" ./scripts/gatekeeper.sh

policy-test:   ## Unit-test the Rego in policy/ with gator (no cluster needed; docker fallback)
	./scripts/policy-test.sh

check:         ## Lint: shellcheck, yamllint, kubeconform on the manifests, doc links
	./scripts/check.sh

status:
	$(KUBECTL) get nodes -o wide
	@n=$$($(KUBECTL) get nodes --no-headers 2>/dev/null | wc -l | tr -d ' '); \
	  [ "$$n" -ge $(CLUSTER_NODES) ] || echo "WARNING: $$n of $(CLUSTER_NODES) cluster nodes present; rejoin with: vagrant provision <node> --provision-with worker"
	$(KUBECTL) -n devapp get pods,svc,pvc
	@$(KUBECTL) get constraints -o wide 2>/dev/null || true

logs:
	$(KUBECTL) -n devapp logs -l app=api -f

test:          ## Hit the API (NodePort 30080), the site (30081), and the web edge
	curl -s http://$(WORKER_IP):30080/healthz; echo
	curl -s -X POST http://$(WORKER_IP):30080/notes -H 'Content-Type: application/json' -d '{"text":"hello from k8s"}'; echo
	curl -s http://$(WORKER_IP):30080/notes; echo
	@curl -sf -o /dev/null http://$(WORKER_IP):30081/ && curl -s http://$(WORKER_IP):30081/api/healthz && echo ' (via site NodePort 30081)'
	@curl -sf -o /dev/null http://$(EDGE_IP)/ && curl -s http://$(EDGE_IP)/api/healthz && echo ' (via web edge)' || echo '(web edge not up: vagrant up web)'

sectest:       ## Security test routines (make sectest ROUTINE=04 for one; SKIP_SLOW=1 skips Trivy/kube-bench)
	KUBECONFIG="$(KUBECONFIG)" ./security/run-all.sh $(ROUTINE)

snapshot:      ## Save a VirtualBox snapshot of every VM (make snapshot SNAP=name); take one after make all
	vagrant snapshot save --force $(SNAP)

restore:       ## Roll every VM back to a snapshot (make restore SNAP=name); the cluster comes back as it was
	vagrant snapshot restore --no-provision $(SNAP)
	vagrant snapshot list

clean:         ## Destroy everything
	vagrant destroy -f
	rm -f kubeconfig join.sh *-image.tar

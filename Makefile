KUBECONFIG ?= $(CURDIR)/kubeconfig
KUBECTL     = KUBECONFIG="$(KUBECONFIG)" kubectl

.PHONY: up down storage image deploy status logs test sectest clean

up:            ## Create the 3-node cluster (10-15 min first run)
	vagrant up

down:          ## Stop VMs, keep state
	vagrant halt

storage:       ## Install local-path storage provisioner and make it default
	$(KUBECTL) apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.28/deploy/local-path-storage.yaml
	$(KUBECTL) patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

image:         ## Build the api and web images and load them onto the workers (make image IMAGES=web)
	./scripts/load-image.sh $(IMAGES)

deploy:        ## Apply all manifests
	$(KUBECTL) apply -f k8s/
	$(KUBECTL) -n devapp rollout status statefulset/postgres
	$(KUBECTL) -n devapp rollout status deployment/api
	$(KUBECTL) -n devapp rollout status deployment/web

status:
	$(KUBECTL) get nodes -o wide
	$(KUBECTL) -n devapp get pods,svc,pvc

logs:
	$(KUBECTL) -n devapp logs -l app=api -f

test:          ## Hit the API (NodePort 30080), the site (30081), and the web edge
	curl -s http://192.168.56.11:30080/healthz; echo
	curl -s -X POST http://192.168.56.11:30080/notes -H 'Content-Type: application/json' -d '{"text":"hello from k8s"}'; echo
	curl -s http://192.168.56.11:30080/notes; echo
	@curl -sf -o /dev/null http://192.168.56.11:30081/ && curl -s http://192.168.56.11:30081/api/healthz && echo ' (via site NodePort 30081)'
	@curl -sf -o /dev/null http://192.168.56.20/ && curl -s http://192.168.56.20/api/healthz && echo ' (via web edge)' || echo '(web edge not up: vagrant up web)'

sectest:       ## Security test routines (make sectest ROUTINE=04 for one; SKIP_SLOW=1 skips Trivy/kube-bench)
	KUBECONFIG="$(KUBECONFIG)" ./security/run-all.sh $(ROUTINE)

clean:         ## Destroy everything
	vagrant destroy -f
	rm -f kubeconfig join.sh api-image.tar

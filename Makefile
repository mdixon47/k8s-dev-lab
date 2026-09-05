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

image:         ## Build API image and load it onto worker nodes
	./scripts/load-image.sh

deploy:        ## Apply all manifests
	$(KUBECTL) apply -f k8s/
	$(KUBECTL) -n devapp rollout status statefulset/postgres
	$(KUBECTL) -n devapp rollout status deployment/api

status:
	$(KUBECTL) get nodes -o wide
	$(KUBECTL) -n devapp get pods,svc,pvc

logs:
	$(KUBECTL) -n devapp logs -l app=api -f

test:          ## Hit the API through a worker's NodePort
	curl -s http://192.168.56.11:30080/healthz; echo
	curl -s -X POST http://192.168.56.11:30080/notes -H 'Content-Type: application/json' -d '{"text":"hello from k8s"}'; echo
	curl -s http://192.168.56.11:30080/notes; echo

sectest:       ## Security test routines (make sectest ROUTINE=04 for one; SKIP_SLOW=1 skips Trivy/kube-bench)
	KUBECONFIG="$(KUBECONFIG)" ./security/run-all.sh $(ROUTINE)

clean:         ## Destroy everything
	vagrant destroy -f
	rm -f kubeconfig join.sh api-image.tar

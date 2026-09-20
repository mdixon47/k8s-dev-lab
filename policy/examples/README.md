# Worked examples for the course (not applied by `make policy`)

`scripts/gatekeeper.sh` applies only `policy/templates/` and `policy/constraints/`.
These files are the reference solution for Part 2 of [docs/course.md](../../docs/course.md)
(lessons 19–23): an approved-registry policy and the two workloads that prove it.

```bash
kubectl apply -f policy/examples/registry-template.yaml
kubectl apply -f policy/examples/registry-constraint.yaml      # warn, devapp + sec-*
kubectl apply -f policy/examples/unapproved-deployment.yaml     # admitted with a Warning
kubectl apply -f policy/examples/approved-deployment.yaml       # admitted cleanly, runs
kubectl patch k8slabapprovedregistry approved-registry --type merge -p '{"spec":{"enforcementAction":"deny"}}'
kubectl apply -f policy/examples/unapproved-deployment.yaml     # now denied
```

Clean up: `kubectl delete -f policy/examples/` (deployments, constraint, template).

# Assignment 2 — Kubernetes Scripts
# Security, Observability & Testing
# github.com/adithyan-ie/kubernetes

## File Overview

```
a2-scripts/checkout-system-security
├── security/
│   ├── 01-serviceaccounts.yaml          # Dedicated SA per service (RBAC)
│   ├── 02-network-policies.yaml         # Default-deny + explicit allow rules
│   ├── 03-deployment-security-patch.yaml # All 4 services with securityContext + limits
│   └── 04-postgres-security-patch.yaml  # Postgres with liveness probe + limits
│
├── observability/
│   ├── 05-observability-namespace.yaml  # Creates + labels the observability namespace
│   ├── 06-prometheus.yaml               # Prometheus + RBAC + scrape config + alert rules
│   └── 07-grafana.yaml                  # Grafana + pre-provisioned dashboards
│
└── testing/
    ├── 08-security-tests.sh             # Trivy scans + NetworkPolicy + RBAC verification
    └── 09-diagnosis-scenario.sh         # Full pricing-service failure diagnosis demo
```

---

## Apply Order

### Prerequisites

```bash
# Your cluster must be running
sudo systemctl start k3s

# Your namespace must exist
kubectl create namespace nano-service 2>/dev/null || true

# Your existing deployment must be up (postgres-secret, postgres-pvc, deployment.yaml etc.)
# as per your existing manifest.md steps 1-7
```

---

### Step 1 — Apply Security Hardening (Section 1 + 2)

```bash
# 1a. Create dedicated ServiceAccounts
kubectl apply -f security/01-serviceaccounts.yaml -n nano-service

# 1b. Apply NetworkPolicies (default-deny + explicit allow)
kubectl apply -f security/02-network-policies.yaml -n nano-service

# 1c. Apply hardened Deployment manifests (replaces your existing deployment.yaml)
kubectl apply -f security/03-deployment-security-patch.yaml -n nano-service

# 1d. Apply hardened Postgres (replaces your existing postgres-deployment.yaml)
kubectl apply -f security/04-postgres-security-patch.yaml -n nano-service

# Verify all pods are still running after security patch
kubectl get pods -n nano-service
kubectl rollout status deployment/api-gateway -n nano-service
kubectl rollout status deployment/checkout-service -n nano-service
kubectl rollout status deployment/pricing-service -n nano-service
kubectl rollout status deployment/inventory-service -n nano-service
```

---

### Step 2 — Apply Observability (Section 3)

```bash
# 2a. Create the observability namespace (must be done FIRST)
kubectl apply -f observability/05-observability-namespace.yaml

# 2b. Deploy Prometheus (scrape config + alert rules + RBAC)
kubectl apply -f observability/06-prometheus.yaml -n observability

# 2c. Deploy Grafana (pre-provisioned dashboards)
kubectl apply -f observability/07-grafana.yaml -n observability

# Verify observability stack is up
kubectl get pods -n observability

# Access Prometheus (open http://localhost:9090 in your browser)
kubectl port-forward svc/prometheus 9090:9090 -n observability &

# Access Grafana (open http://localhost:3000 in your browser)
# Login: admin / admin
kubectl port-forward svc/grafana 3000:3000 -n observability &
```

---

### Step 3 — Run Security Tests (Section 4)

```bash
# Make executable
chmod +x testing/08-security-tests.sh

# Run all tests and save output for your report
cd testing
bash 08-security-tests.sh 2>&1 | tee security-test-results.txt

# Results will be in ./trivy-results/ directory
# Screenshots of this output go in your report appendix
```

---

### Step 4 — Run Diagnosis Scenario (Section 3 demo)

```bash
# Must have port-forward to gateway running first
kubectl port-forward svc/api-gateway 8080:80 -n nano-service &

# Optional: also port-forward Prometheus to get metric evidence
kubectl port-forward svc/prometheus 9090:9090 -n observability &

# Run the scenario
chmod +x testing/09-diagnosis-scenario.sh
bash testing/09-diagnosis-scenario.sh 2>&1 | tee diagnosis-scenario-results.txt
```

---

## Quick Verification Commands

```bash
# Check NetworkPolicies are in place
kubectl get networkpolicies -n nano-service

# Check ServiceAccounts exist
kubectl get serviceaccounts -n nano-service

# Check pods use correct SA and have no auto-mounted token
kubectl get pod -n nano-service -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.serviceAccountName}{"\t"}{.spec.automountServiceAccountToken}{"\n"}{end}'

# Check resource limits are set
kubectl describe pods -n nano-service | grep -A4 "Limits:"

# Check security context is applied
kubectl get pod -n nano-service -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[0].securityContext}{"\n"}{end}'

# Check Prometheus targets are healthy
# (after port-forwarding to 9090)
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -E "health|job|__address__" | head -30

# Verify Grafana dashboards loaded
curl -s http://admin:admin@localhost:3000/api/dashboards/home | python3 -m json.tool
```

---

## Ports Reference (from your docker-compose.yml)

| Service | Port |
|---------|------|
| api-gateway | 80 |
| checkout-service | 3001 |
| inventory-service | 3002 |
| pricing-service | 3003 |
| postgres | 5432 |
| prometheus | 9090 |
| grafana | 3000 |

Namespace for all app services: `nano-service`
Namespace for observability: `observability`

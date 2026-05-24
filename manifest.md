# Project Manifest

## Repository Structure

```
+-- api-gateway/                    # Node.js service + Dockerfile
¦   +-- index.js
¦   +-- package.json
¦   +-- Dockerfile
¦
+-- checkout-service/               # Node.js service + Dockerfile
¦   +-- index.js                    # KEDA target; writes to Postgres
¦   +-- package.json
¦   +-- Dockerfile
¦
+-- inventory-service/              # Node.js service + Dockerfile
¦   +-- index.js
¦   +-- package.json
¦   +-- Dockerfile
¦
+-- pricing-service/                # Node.js service + Dockerfile
¦   +-- index.js
¦   +-- package.json
¦   +-- Dockerfile
¦
+-- deployment/                     # All K8s manifests (plain YAML)
¦   +-- postgres-secret.yaml        # base64-encoded credentials only
¦   +-- postgres-pvc.yaml
¦   +-- postgres-deployment.yaml
¦   +-- deployment.yaml
¦   +-- keda-http-ingress.yaml
¦   +-- keda-http-scaledobject.yaml
¦   +-- keda-http-external-service.yaml
¦
+-- docker-compose.yml              # local dev only; not the deploy target
```

---

## Services

### api-gateway
- **Runtime:** Node.js
- **Role:** Public entry point; routes incoming requests to downstream microservices via Traefik Ingress
- **Scaling:** Fixed replicas

### checkout-service
- **Runtime:** Node.js
- **Role:** Handles checkout logic; persists orders to Postgres; primary KEDA scale-to-zero target
- **Scaling:** KEDA HTTP-triggered autoscaler (scales to zero when idle)
- **Dependencies:** Postgres, pricing-service, inventory-service

### inventory-service
- **Runtime:** Node.js
- **Role:** Manages stock levels; responds to inventory queries from checkout-service
- **Scaling:** Fixed replicas

### pricing-service
- **Runtime:** Node.js
- **Role:** Returns pricing and tax data for SKUs
- **Scaling:** Fixed replicas

---

## Kubernetes Manifests (`deployment/`)

| File | Purpose |
|------|---------|
| `postgres-secret.yaml` | Base64-encoded DB credentials (username, password) |
| `postgres-pvc.yaml` | PersistentVolumeClaim for Postgres data directory |
| `postgres-deployment.yaml` | Postgres Deployment + ClusterIP Service |
| `deployment.yaml` | Deployments and Services for all four Node.js services |
| `keda-http-ingress.yaml` | Traefik Ingress routing rules |
| `keda-http-scaledobject.yaml` | KEDA ScaledObject for checkout-service HTTP trigger |
| `keda-http-external-service.yaml` | KEDA HTTP interceptor external service definition |

---

## Kubernetes Deployment

### Step 1 — Start the K3s cluster

```bash
sudo systemctl start k3s
```

### Step 2 — Create the namespace

```bash
kubectl create namespace nano-service
```

All resources run in the `nano-service` namespace **except** the KEDA service, which runs in its own system namespace.

### Step 3 — Apply KEDA manifests

> KEDA resources are applied **without** `-n nano-service` as they run cluster-wide.

```bash
kubectl apply -f http-scaled-object-deployment.yaml \
              -f keda-external-service.yaml \
              -f keda-ingress-deployment.yaml
```

### Step 4 — Apply DB secrets, config, and PVC

```bash
kubectl apply -n nano-service \
  -f db-postgres.yaml \
  -f db-pvc.yaml \
  -f db-secret.yaml
```

### Step 5 — Build, tag, and push all service images

Ensure the local registry is reachable at `localhost:5000` before proceeding. Build each service from its own directory, tag it to `latest`, and push to the local registry.

**checkout-service**
```bash
docker build -t checkout-service:latest ./checkout-service
docker tag checkout-service:latest localhost:5000/checkout-service:latest
docker push localhost:5000/checkout-service:latest
```

**api-gateway**
```bash
docker build -t api-gateway:latest ./api-gateway
docker tag api-gateway:latest localhost:5000/api-gateway:latest
docker push localhost:5000/api-gateway:latest
```

**inventory-service**
```bash
docker build -t inventory-service:latest ./inventory-service
docker tag inventory-service:latest localhost:5000/inventory-service:latest
docker push localhost:5000/inventory-service:latest
```

**pricing-service**
```bash
docker build -t pricing-service:latest ./pricing-service
docker tag pricing-service:latest localhost:5000/pricing-service:latest
docker push localhost:5000/pricing-service:latest
```

Verify all four images are available in the registry:

```bash
curl http://localhost:5000/v2/_catalog
```

Expected output: `{"repositories":["api-gateway","checkout-service","inventory-service","pricing-service"]}`

### Step 6 — Run the main deployment

```bash
kubectl apply -n nano-service -f deployment.yaml
```

### Step 7 — Verify all pods are running

```bash
kubectl get pods -n nano-service
```

All pods should show `Running`. If any are in `Pending` or `CrashLoopBackOff`, inspect with `kubectl describe pod <n> -n nano-service`.

### Step 8 — Set up port forwarding

```bash
kubectl port-forward svc/api-gateway 8080:80 -n nano-service
```

Leave this terminal open. The UI and API are now accessible at `http://localhost:8080`.

### Step 9 — Access the UI

Open a browser and navigate to:

```
http://localhost:8080
```

### Step 10 — POST a checkout (cold start)

KEDA scales `checkout-service` to zero when idle. The first request will trigger a cold start.

```
POST http://localhost:8080/api/checkout
```

- If the response is **502 or 503**, `checkout-service` is still starting up. **Wait 10–20 seconds and retry** the POST.
- On success you will receive a `200` response with the order payload including a `requestId`.

### Step 11 — GET saved orders

Once a checkout has been successfully persisted, fetch all saved orders:

```
GET http://localhost:8080/api/checkout
```

---

## Local Development

```bash
docker-compose up
```

`docker-compose.yml` is provided for local development only and is **not** the deployment target. All production deployments use the plain YAML manifests in `deployment/`.

---

## Deployment Notes

- All manifests are plain YAML (no Helm) for full transparency and auditability.
- Postgres credentials are managed via Kubernetes Secret; never committed in plaintext.
- The local-path PVC is suitable for single-node K3s; replace with a network-attached StorageClass for multi-node resilience [6].
- KEDA scale-to-zero applies to `checkout-service` only. Pricing and inventory remain at fixed replicas to avoid compounding cold-start latency within the gateway timeout budget.


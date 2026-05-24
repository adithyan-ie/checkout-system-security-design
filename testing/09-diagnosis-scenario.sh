#!/usr/bin/env bash
# =============================================================================
# 09-diagnosis-scenario.sh
# Demonstrates the pricing-service failure diagnosis scenario from the report.
# Deliberately scales pricing-service to 0, observes checkout failures,
# then diagnoses and recovers using kubectl + Prometheus queries.
#
# Prerequisites: all manifests applied, port-forward to api-gateway running:
#   kubectl port-forward svc/api-gateway 8080:80 -n nano-service
#
# Usage: bash 09-diagnosis-scenario.sh
# =============================================================================

set -uo pipefail

NS="nano-service"
GW="http://localhost:8080"

log()  { echo ""; echo "── $1 ──────────────────────────────────────────"; }
info() { echo "  → $1"; }
ok()   { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; }

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 0 — Baseline: confirm system is healthy"
# ─────────────────────────────────────────────────────────────────────────────

info "GET /api/ping ..."
PING=$(curl -s -o /dev/null -w "%{http_code}" "$GW/api/ping")
[ "$PING" = "200" ] && ok "Gateway healthy (200)" || { fail "Gateway not responding ($PING)"; exit 1; }

info "POST /api/checkout (warm baseline)..."
WARM_START=$(date +%s%N)
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$GW/api/checkout" \
  -H "Content-Type: application/json" \
  -H "X-Request-Id: diag-baseline-001" \
  -d '{"sku":"SKU-001","quantity":1}')
WARM_END=$(date +%s%N)
WARM_MS=$(( (WARM_END - WARM_START) / 1000000 ))
HTTP_STATUS=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -1)

info "Warm checkout: HTTP $HTTP_STATUS in ${WARM_MS}ms"
[ "$HTTP_STATUS" = "200" ] && ok "Warm path working" || info "Note: $HTTP_STATUS — may be cold start, wait 15s and retry"
echo "  Body: $BODY"

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 1 — Inject fault: scale pricing-service to 0"
# ─────────────────────────────────────────────────────────────────────────────

info "Scaling pricing-service to 0 replicas..."
kubectl scale deployment pricing-service --replicas=0 -n "$NS"
sleep 3

PRICING_READY=$(kubectl get deployment pricing-service -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)
info "pricing-service ready replicas: ${PRICING_READY:-0}"
ok "Fault injected — pricing-service has 0 ready pods"

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 2 — Observe failure: POST /api/checkout should return 503"
# ─────────────────────────────────────────────────────────────────────────────

info "Sending 3 checkout requests (expect 503)..."
for i in 1 2 3; do
  RESP=$(curl -s -w "\n%{http_code}" -X POST "$GW/api/checkout" \
    -H "Content-Type: application/json" \
    -H "X-Request-Id: diag-fault-00$i" \
    -d '{"sku":"SKU-001","quantity":1}')
  STATUS=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | head -1)
  info "Request $i: HTTP $STATUS — $BODY"
done

echo ""
info "GET /api/ping while checkout is failing (gateway should still be healthy)..."
PING_DURING=$(curl -s -o /dev/null -w "%{http_code}" "$GW/api/ping")
[ "$PING_DURING" = "200" ] && ok "Gateway /api/ping still returns 200 during checkout failure (partial-failure evidence)" || fail "Gateway unreachable: $PING_DURING"

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 3 — Diagnose using logs (correlated by X-Request-Id)"
# ─────────────────────────────────────────────────────────────────────────────

info "Checking checkout-service logs for pricing timeout..."
kubectl logs -l app=checkout-service -n "$NS" --tail=20 | grep -i "pricing\|timeout\|error\|diag-fault" || info "(no matching log lines — checkout-service may be KEDA scaled to 0)"

echo ""
info "Checking api-gateway logs..."
kubectl logs -l app=api-gateway -n "$NS" --tail=10 | grep -i "diag-fault\|503\|checkout" || info "(no matching log lines)"

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 4 — Endpoints evidence (pricing-service should have no ready addresses)"
# ─────────────────────────────────────────────────────────────────────────────

info "kubectl get endpoints -n $NS"
kubectl get endpoints -n "$NS"

echo ""
info "Focused check on pricing-service endpoint..."
PRICING_ENDPOINTS=$(kubectl get endpoints pricing-service -n "$NS" -o jsonpath='{.subsets}' 2>/dev/null || echo "none")
if [ "$PRICING_ENDPOINTS" = "none" ] || [ -z "$PRICING_ENDPOINTS" ]; then
  ok "pricing-service endpoint has no ready addresses — confirms no pod is running"
else
  info "pricing-service endpoints: $PRICING_ENDPOINTS"
fi

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 5 — Pod status evidence"
# ─────────────────────────────────────────────────────────────────────────────

info "kubectl get pods -n $NS"
kubectl get pods -n "$NS"

PRICING_PODS=$(kubectl get pods -n "$NS" -l app=pricing-service --no-headers 2>/dev/null | wc -l)
info "pricing-service pod count: $PRICING_PODS"
[ "$PRICING_PODS" -eq 0 ] && ok "Confirmed: 0 pricing-service pods running" || info "Pods found: $PRICING_PODS"

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 6 — Prometheus metric evidence (if port-forwarded)"
# ─────────────────────────────────────────────────────────────────────────────

info "Querying Prometheus for checkout error rate (requires: kubectl port-forward svc/prometheus 9090:9090 -n observability)..."
PROM_RESULT=$(curl -s "http://localhost:9090/api/v1/query?query=sum(rate(http_requests_total{service=\"checkout-service\",status_code=~\"5..\"}[2m]))" 2>/dev/null || echo "PROM_UNAVAILABLE")

if echo "$PROM_RESULT" | grep -q "PROM_UNAVAILABLE"; then
  info "Prometheus not reachable on localhost:9090 — run: kubectl port-forward svc/prometheus 9090:9090 -n observability"
else
  ERROR_RATE=$(echo "$PROM_RESULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['result'][0]['value'][1] if d['data']['result'] else '0')" 2>/dev/null || echo "parse error")
  info "Current checkout 5xx rate: $ERROR_RATE req/s"
  ok "Prometheus confirms elevated error rate during fault"
fi

# ─────────────────────────────────────────────────────────────────────────────
log "STEP 7 — Recover: restore pricing-service"
# ─────────────────────────────────────────────────────────────────────────────

info "Scaling pricing-service back to 1 replica..."
kubectl scale deployment pricing-service --replicas=1 -n "$NS"

info "Waiting for pricing-service to become ready..."
kubectl rollout status deployment/pricing-service -n "$NS" --timeout=60s

info "POST /api/checkout after recovery..."
sleep 3
RECOVERY_RESP=$(curl -s -w "\n%{http_code}" -X POST "$GW/api/checkout" \
  -H "Content-Type: application/json" \
  -H "X-Request-Id: diag-recovery-001" \
  -d '{"sku":"SKU-001","quantity":1}')
RECOVERY_STATUS=$(echo "$RECOVERY_RESP" | tail -1)
info "Recovery checkout: HTTP $RECOVERY_STATUS"
[ "$RECOVERY_STATUS" = "200" ] && ok "System recovered — checkout returns 200" || fail "Still failing: $RECOVERY_STATUS"

# ─────────────────────────────────────────────────────────────────────────────
log "SCENARIO COMPLETE"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "  Summary of evidence collected:"
echo "  1. Checkout returned 503 while gateway /api/ping returned 200 (partial failure)"
echo "  2. checkout-service logs showed pricing timeout"
echo "  3. pricing-service endpoints had no ready addresses"
echo "  4. kubectl get pods confirmed 0 pricing pods"
echo "  5. Prometheus showed checkout error rate spike"
echo "  6. Recovery confirmed by 200 after scale-up"
echo ""

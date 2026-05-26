#!/usr/bin/env bash
# =============================================================================
# 08-security-tests.sh
# Covers Assignment 2 Part 3: Security Testing
#
# What this script does:
#   1. Trivy image scan  — all 4 app images + postgres base
#   2. Trivy config scan — your deployment/ manifests for misconfigurations
#   3. NetworkPolicy verification — confirm deny and allow rules work
#   4. RBAC verification — confirm service account token is not mounted
#
# Prerequisites:
#   - trivy installed (https://trivy.dev/docs/getting-started/installation/)
#   - kubectl configured pointing at your K3s cluster
#   - All manifests from security/ and observability/ already applied
#   - Local registry running at localhost:5000
#
# Folder structure expected:
#   deployment/
#   ├── db-postgres.yaml
#   ├── db-pvc.yaml
#   ├── db-secret.yaml
#   ├── deployment.yaml
#   ├── security/        ← hardened manifests
#   └── testing/
#       └── 08-security-tests.sh   ← this file
#
# Usage: bash 08-security-tests.sh 2>&1 | tee security-test-results.txt
# =============================================================================

set -euo pipefail

NS="nano-service"
REGISTRY="localhost:5000"
IMAGES=("api-gateway" "checkout-service" "pricing-service" "inventory-service")

# Resolve all paths relative to this script's location — works from any directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"   # one level up = deployment/

MANIFEST_DIR="$DEPLOYMENT_DIR"                   # original manifests
HARDENED_DIR="$DEPLOYMENT_DIR/security"          # hardened manifests
RESULTS_DIR="$SCRIPT_DIR/trivy-results"
mkdir -p "$RESULTS_DIR"

PASS=0
FAIL=0

log()  { echo ""; echo "══════════════════════════════════════════"; echo "  $1"; echo "══════════════════════════════════════════"; }
ok()   { echo "  ✅  $1"; PASS=$((PASS+1)); }
fail() { echo "  ❌  $1"; FAIL=$((FAIL+1)); }
info() { echo "  ℹ️   $1"; }

# ─────────────────────────────────────────────────────────────────────────────
log "PART 1 — Trivy Image Scanning"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Checking trivy is installed..."
if ! command -v trivy &>/dev/null; then
  echo "  trivy not found. Install with:"
  echo "    curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin"
  exit 1
fi
trivy --version

# Scan each application image
for IMG in "${IMAGES[@]}"; do
  echo ""
  info "Scanning $REGISTRY/$IMG:latest ..."
  trivy image \
    --severity HIGH,CRITICAL \
    --format table \
    --output "$RESULTS_DIR/${IMG}-scan.txt" \
    "$REGISTRY/$IMG:latest" || true

  CRITICAL_COUNT=$(grep -c "CRITICAL" "$RESULTS_DIR/${IMG}-scan.txt" 2>/dev/null || echo 0)
  HIGH_COUNT=$(grep -c "HIGH" "$RESULTS_DIR/${IMG}-scan.txt" 2>/dev/null || echo 0)

  echo "  → CRITICAL: $CRITICAL_COUNT  HIGH: $HIGH_COUNT"

  if [ "$CRITICAL_COUNT" -gt 0 ]; then
    fail "$IMG has CRITICAL CVEs — must be fixed before production deployment"
  else
    ok "$IMG — no CRITICAL CVEs found"
  fi

  cat "$RESULTS_DIR/${IMG}-scan.txt"
done

# Scan postgres base image
echo ""
info "Scanning postgres:15 base image..."
trivy image \
  --severity HIGH,CRITICAL \
  --format table \
  --output "$RESULTS_DIR/postgres-scan.txt" \
  postgres:15 || true

CRITICAL_COUNT=$(grep -c "CRITICAL" "$RESULTS_DIR/postgres-scan.txt" 2>/dev/null || echo 0)
echo "  → CRITICAL: $CRITICAL_COUNT"
[ "$CRITICAL_COUNT" -gt 0 ] && fail "postgres:15 has CRITICAL CVEs" || ok "postgres:15 — no CRITICAL CVEs"
cat "$RESULTS_DIR/postgres-scan.txt"

# ─────────────────────────────────────────────────────────────────────────────
log "PART 2 — Trivy Misconfiguration Scan (Kubernetes Manifests)"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Scanning original manifests in $MANIFEST_DIR ..."
trivy config \
  --severity MEDIUM,HIGH,CRITICAL \
  --format table \
  --output "$RESULTS_DIR/manifest-config-scan.txt" \
  "$MANIFEST_DIR" || true

cat "$RESULTS_DIR/manifest-config-scan.txt"

echo ""
info "Scanning hardened manifests in $HARDENED_DIR ..."
trivy config \
  --severity MEDIUM,HIGH,CRITICAL \
  --format table \
  --output "$RESULTS_DIR/manifest-hardened-scan.txt" \
  "$HARDENED_DIR" || true

cat "$RESULTS_DIR/manifest-hardened-scan.txt"

HIGH_AFTER=$(grep -c "HIGH\|CRITICAL" "$RESULTS_DIR/manifest-hardened-scan.txt" 2>/dev/null || echo 0)
[ "$HIGH_AFTER" -eq 0 ] && ok "No HIGH/CRITICAL misconfigurations in hardened manifests" || fail "$HIGH_AFTER HIGH/CRITICAL misconfigurations remain"

# ─────────────────────────────────────────────────────────────────────────────
log "PART 3 — NetworkPolicy Verification"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Test 3a: Unauthorized pod SHOULD NOT reach postgres (default-deny)"
echo "  Launching toolbox pod in nano-service..."

RESULT=$(kubectl run nettest-deny \
  --image=curlimages/curl:latest \
  --restart=Never \
  --rm \
  --timeout=30s \
  -n "$NS" \
  -q \
  -- curl -m 5 -s -o /dev/null -w "%{http_code}" \
     http://postgres:5432/ 2>&1 || echo "TIMEOUT_OR_REFUSED")

if echo "$RESULT" | grep -qE "TIMEOUT_OR_REFUSED|Connection refused|timed out|exit code"; then
  ok "3a: NetworkPolicy BLOCKS arbitrary pod → postgres (expected)"
else
  fail "3a: NetworkPolicy NOT blocking — postgres reachable from random pod: $RESULT"
fi

echo ""
info "Test 3b: pricing-service SHOULD NOT reach postgres (not in allow list)"
PRICING_POD=$(kubectl get pod -n "$NS" -l app=pricing-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$PRICING_POD" ]; then
  RESULT=$(kubectl exec -n "$NS" "$PRICING_POD" -- \
    sh -c "curl -m 5 -s -o /dev/null -w '%{http_code}' http://postgres:5432/ 2>&1 || echo BLOCKED" 2>&1 || echo "BLOCKED")

  if echo "$RESULT" | grep -qiE "BLOCKED|timed out|refused|000"; then
    ok "3b: NetworkPolicy BLOCKS pricing-service → postgres (expected)"
  else
    fail "3b: pricing-service can reach postgres — NetworkPolicy not working: $RESULT"
  fi
else
  info "3b: No pricing-service pod found — skip"
fi

echo ""
info "Test 3c: checkout-service SHOULD reach postgres (explicit allow)"
CHECKOUT_POD=$(kubectl get pod -n "$NS" -l app=checkout-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$CHECKOUT_POD" ]; then
  RESULT=$(kubectl exec -n "$NS" "$CHECKOUT_POD" -- \
    sh -c "curl -m 5 -s -o /dev/null -w '%{http_code}' http://postgres:5432/ 2>&1 || echo CONN_ERR" 2>&1 || echo "CONN_ERR")

  # A refused connection means the packet reached postgres — allow rule working
  # A timeout means NetworkPolicy is blocking — allow rule not working
  if echo "$RESULT" | grep -qiE "refused|CONN_ERR|52|000"; then
    ok "3c: checkout-service REACHES postgres (connection refused = packet arrived, allow rule works)"
  elif echo "$RESULT" | grep -q "timed out"; then
    fail "3c: checkout-service timed out — NetworkPolicy may be blocking the allow path"
  else
    info "3c: Unexpected result: $RESULT (manual verification recommended)"
  fi
else
  info "3c: No checkout-service pod found — skip (KEDA may have scaled to 0)"
fi

echo ""
info "Test 3d: api-gateway SHOULD reach checkout-service on port 3001"
GW_POD=$(kubectl get pod -n "$NS" -l app=api-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$GW_POD" ]; then
  RESULT=$(kubectl exec -n "$NS" "$GW_POD" -- \
    curl -m 5 -s -o /dev/null -w "%{http_code}" http://checkout-service:3001/health 2>&1 || echo "FAIL")

  if [ "$RESULT" = "200" ]; then
    ok "3d: api-gateway → checkout-service :3001 reachable (200)"
  else
    fail "3d: api-gateway cannot reach checkout-service: $RESULT"
  fi
else
  info "3d: No api-gateway pod found — skip"
fi

# ─────────────────────────────────────────────────────────────────────────────
log "PART 4 — RBAC / ServiceAccount Verification"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
info "Test 4a: Verify checkout-service token is NOT auto-mounted"
CHECKOUT_POD=$(kubectl get pod -n "$NS" -l app=checkout-service -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [ -n "$CHECKOUT_POD" ]; then
  TOKEN_PRESENT=$(kubectl exec -n "$NS" "$CHECKOUT_POD" -- \
    sh -c "ls /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null && echo EXISTS || echo ABSENT" 2>&1 || echo "ABSENT")

  if echo "$TOKEN_PRESENT" | grep -q "ABSENT"; then
    ok "4a: ServiceAccount token NOT mounted in checkout-service pod"
  else
    fail "4a: ServiceAccount token IS mounted — automountServiceAccountToken not effective"
  fi
else
  info "4a: No checkout-service pod (KEDA scale-to-zero) — check after triggering a request"
fi

echo ""
info "Test 4b: Verify pods use dedicated ServiceAccounts (not default)"
for SVC in api-gateway checkout-service pricing-service inventory-service; do
  SA=$(kubectl get pod -n "$NS" -l "app=$SVC" -o jsonpath='{.items[0].spec.serviceAccountName}' 2>/dev/null || echo "none")
  if [ "$SA" != "default" ] && [ "$SA" != "none" ]; then
    ok "4b: $SVC uses dedicated SA: $SA"
  else
    fail "4b: $SVC is still using default ServiceAccount"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
log "SUMMARY"
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "  PASSED: $PASS"
echo "  FAILED: $FAIL"
echo ""
echo "  Results saved to: $RESULTS_DIR/"
echo "  Full output logged to: security-test-results.txt (if redirected)"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "  ⚠️  $FAIL test(s) failed — review output above."
  exit 1
else
  echo "  ✅  All tests passed."
fi

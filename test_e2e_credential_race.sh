#!/bin/bash
# End-to-end test for credential CRUD vs concurrent reload race condition (issue #50273)
#
# This script tests that credential create/update/delete operations are preserved
# even when a periodic reload runs concurrently. It demonstrates the bug exists on
# upstream main and is fixed on this branch.
#
# Usage:
#   ./test_e2e_credential_race.sh [before|after]
#     before - test upstream main (expects failure)
#     after  - test this branch (expects success)

set -e

MODE="${1:-after}"
MASTER_KEY="sk-test-$(date +%s)"
PORT=4000
DB_PATH="/tmp/litellm_test_$(date +%s).db"
LOG_PATH="/tmp/litellm_test_proxy.log"

cleanup() {
    echo "Cleaning up..."
    if [ -n "$PROXY_PID" ] && kill -0 "$PROXY_PID" 2>/dev/null; then
        kill "$PROXY_PID" 2>/dev/null || true
        wait "$PROXY_PID" 2>/dev/null || true
    fi
    rm -f "$DB_PATH" "$LOG_PATH"
}
trap cleanup EXIT

cat > /tmp/test_config.yaml <<EOF
model_list:
  - model_name: test-model
    litellm_params:
      model: gpt-4o-mini
      api_key: fake-key

general_settings:
  master_key: $MASTER_KEY
  store_model_in_db: true
  database_url: "sqlite:///$DB_PATH"
  proxy_config_reload_interval_seconds: 2
EOF

echo "=== End-to-End Test for Credential Race Condition ==="
echo "Mode: $MODE (testing $([ "$MODE" = "before" ] && echo "upstream main" || echo "this branch"))"
echo "Database: $DB_PATH"
echo ""

echo "Starting proxy..."
python3 -m litellm.proxy.proxy_cli \
    --config /tmp/test_config.yaml \
    --port $PORT \
    --detailed_debug > "$LOG_PATH" 2>&1 &
PROXY_PID=$!

echo "Waiting for proxy to start (PID: $PROXY_PID)..."
sleep 5

if ! kill -0 "$PROXY_PID" 2>/dev/null; then
    echo "ERROR: Proxy failed to start"
    cat "$LOG_PATH"
    exit 1
fi
echo "Proxy started successfully"
echo ""

BASE_URL="http://localhost:$PORT"
AUTH_HEADER="Authorization: Bearer $MASTER_KEY"

echo "=== Test 1: Create credential during reload ==="
echo "Creating credential 'test-cred-create'..."
curl -s -X POST "$BASE_URL/credentials" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d '{"credential_name": "test-cred-create", "credential_values": {"api_key": "sk-create-test"}, "credential_info": {"custom_llm_provider": "openai"}}' \
    | python3 -m json.tool

sleep 1
echo ""
echo "Waiting for reload cycle (2 seconds)..."
sleep 2.5

echo "Checking if credential still exists..."
RESULT=$(curl -s -X GET "$BASE_URL/credentials/by_name/test-cred-create" -H "$AUTH_HEADER")
echo "$RESULT" | python3 -m json.tool

if echo "$RESULT" | grep -q "test-cred-create"; then
    echo "✓ CREATE TEST PASSED: Credential persisted after reload"
    CREATE_PASS=1
else
    echo "✗ CREATE TEST FAILED: Credential lost after reload (race condition)"
    CREATE_PASS=0
fi
echo ""

echo "=== Test 2: Update credential during reload ==="
echo "Creating credential 'test-cred-update' with initial value..."
curl -s -X POST "$BASE_URL/credentials" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d '{"credential_name": "test-cred-update", "credential_values": {"api_key": "sk-initial"}, "credential_info": {"custom_llm_provider": "openai"}}' \
    | python3 -m json.tool

sleep 1
echo ""
echo "Updating credential to 'sk-updated'..."
curl -s -X PATCH "$BASE_URL/credentials/test-cred-update" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d '{"credential_values": {"api_key": "sk-updated"}}' \
    | python3 -m json.tool

sleep 1
echo ""
echo "Waiting for reload cycle (2 seconds)..."
sleep 2.5

echo "Checking if update persisted..."
RESULT=$(curl -s -X GET "$BASE_URL/credentials/by_name/test-cred-update" -H "$AUTH_HEADER")
echo "$RESULT" | python3 -m json.tool

if echo "$RESULT" | grep -q "sk-updat"; then
    echo "✓ UPDATE TEST PASSED: Update persisted after reload"
    UPDATE_PASS=1
else
    echo "✗ UPDATE TEST FAILED: Update reverted after reload (race condition)"
    UPDATE_PASS=0
fi
echo ""

echo "=== Test 3: Delete credential during reload ==="
echo "Creating credential 'test-cred-delete'..."
curl -s -X POST "$BASE_URL/credentials" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    -d '{"credential_name": "test-cred-delete", "credential_values": {"api_key": "sk-delete-test"}, "credential_info": {"custom_llm_provider": "openai"}}' \
    | python3 -m json.tool

sleep 1
echo ""
echo "Deleting credential..."
curl -s -X DELETE "$BASE_URL/credentials/test-cred-delete" \
    -H "$AUTH_HEADER" \
    | python3 -m json.tool

sleep 1
echo ""
echo "Waiting for reload cycle (2 seconds)..."
sleep 2.5

echo "Checking if credential stays deleted..."
STATUS=$(curl -s -w "%{http_code}" -o /dev/null -X GET "$BASE_URL/credentials/by_name/test-cred-delete" -H "$AUTH_HEADER")

if [ "$STATUS" = "404" ]; then
    echo "✓ DELETE TEST PASSED: Credential stayed deleted after reload"
    DELETE_PASS=1
else
    echo "✗ DELETE TEST FAILED: Credential restored after reload (race condition) - Status: $STATUS"
    DELETE_PASS=0
fi
echo ""

echo "=== Summary ==="
echo "Create test: $([ $CREATE_PASS -eq 1 ] && echo "PASS ✓" || echo "FAIL ✗")"
echo "Update test: $([ $UPDATE_PASS -eq 1 ] && echo "PASS ✓" || echo "FAIL ✗")"
echo "Delete test: $([ $DELETE_PASS -eq 1 ] && echo "PASS ✓" || echo "FAIL ✗")"
echo ""

TOTAL_PASS=$((CREATE_PASS + UPDATE_PASS + DELETE_PASS))
if [ $TOTAL_PASS -eq 3 ]; then
    echo "ALL TESTS PASSED ✓"
    exit 0
else
    echo "SOME TESTS FAILED ($((3 - TOTAL_PASS))/3) ✗"
    exit 1
fi

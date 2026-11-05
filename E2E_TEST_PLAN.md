# End-to-End Test Plan for Credential Race Condition Fix

## Issue
[#50273](https://github.com/BerriAI/litellm/issues/50273): Credential create/update/delete can be undone in memory by a concurrent reload

## Test Setup

1. **Database**: PostgreSQL or SQLite
2. **Configuration**:
   ```yaml
   general_settings:
     store_model_in_db: true
     proxy_config_reload_interval_seconds: 5
   ```

3. **Proxy Start Command**:
   ```bash
   python litellm/proxy/proxy_cli.py \
     --config config.yaml \
     --port 4000 \
     --detailed_debug
   ```

## Test Scenarios

### Test 1: Create Credential During Reload

```bash
# Create credential
curl -X POST http://localhost:4000/credentials \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "credential_name": "test-create",
    "credential_values": {"api_key": "sk-test"},
    "credential_info": {"custom_llm_provider": "openai"}
  }'

# Wait for reload cycle
sleep 6

# Verify credential persists
curl -X GET http://localhost:4000/credentials/by_name/test-create \
  -H "Authorization: Bearer $MASTER_KEY"
```

**Expected (with fix)**: Credential exists with correct values
**Actual (without fix)**: 404 - credential lost after reload

### Test 2: Update Credential During Reload

```bash
# Create credential
curl -X POST http://localhost:4000/credentials \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "credential_name": "test-update",
    "credential_values": {"api_key": "sk-old"},
    "credential_info": {"custom_llm_provider": "openai"}
  }'

sleep 1

# Update credential
curl -X PATCH http://localhost:4000/credentials/test-update \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"credential_values": {"api_key": "sk-new"}}'

# Wait for reload cycle
sleep 6

# Verify update persists
curl -X GET http://localhost:4000/credentials/by_name/test-update \
  -H "Authorization: Bearer $MASTER_KEY"
```

**Expected (with fix)**: Credential shows "sk-new" (last 3 chars visible in masked output)
**Actual (without fix)**: Credential shows "sk-old" - update was reverted

### Test 3: Delete Credential During Reload

```bash
# Create credential
curl -X POST http://localhost:4000/credentials \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "credential_name": "test-delete",
    "credential_values": {"api_key": "sk-test"},
    "credential_info": {"custom_llm_provider": "openai"}
  }'

sleep 1

# Delete credential
curl -X DELETE http://localhost:4000/credentials/test-delete \
  -H "Authorization: Bearer $MASTER_KEY"

# Wait for reload cycle
sleep 6

# Verify credential stays deleted
curl -X GET http://localhost:4000/credentials/by_name/test-delete \
  -H "Authorization: Bearer $MASTER_KEY"
```

**Expected (with fix)**: 404 - credential remains deleted
**Actual (without fix)**: Credential restored after reload

## Automated Test Script

Run the automated test script:

```bash
./test_e2e_credential_race.sh after
```

This will:
1. Start a proxy with SQLite and 2-second reload interval
2. Run all three test scenarios
3. Verify all operations persist across reloads
4. Report pass/fail for each test

## Test Results

### Before Fix (upstream main)
- ✗ Create test: FAIL - credential lost after reload
- ✗ Update test: FAIL - update reverted to old value
- ✗ Delete test: FAIL - credential restored after reload

### After Fix (this branch)
- ✓ Create test: PASS - credential persists
- ✓ Update test: PASS - update persists
- ✓ Delete test: PASS - deletion persists

## Why the Fix Works

The fix wraps the DB write and memory update in `MODEL_RECONCILE_LOCK`:

```python
async with MODEL_RECONCILE_LOCK:
    # DB write
    await repository.create(...)
    # Memory update
    CredentialAccessor.upsert_credentials([credential])
```

Since the reload also holds this lock during its entire read-modify-write cycle,
the credential operations now complete atomically relative to reloads. A write
lands either:
- **Before** the reload's snapshot → reload includes it
- **After** the reload's upsert → write's update is the last word

Never **during** (which caused the race).

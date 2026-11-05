"""
Demonstration of credential CRUD vs concurrent reload race condition fix.

This script simulates the race condition described in issue #50273 and demonstrates
that the fix (MODEL_RECONCILE_LOCK) prevents it.

The race condition:
1. Periodic reload reads all credentials from DB
2. While reload is processing, a credential endpoint writes to DB and updates memory
3. Reload's upsert overwrites the endpoint's memory update with stale data
4. Result: create is lost, update is reverted, delete is restored (until next reload)

The fix: Wrap DB write + memory update in MODEL_RECONCILE_LOCK, so they complete
atomically relative to the reload.

#!/usr/bin/env bash
# End-to-end harness runner: fake Kasa devices -> collector -> InfluxDB, no hardware.
# Brings up the `e2e` PROFILE of the single compose.yml, waits for the collector to
# write emeter data for the emulated devices, and asserts both device aliases show up
# in InfluxDB. Always tears the stack down. Driven by `make test-e2e`, which builds the
# collector and fake images first and passes REGISTRY/TAG/FAKE_TAG — compose only runs
# the tags.
#
# Its own project name keeps the throwaway stack isolated from the dev/demo stacks, so
# a `down -v` here can never reach their volumes.
#
# ENV_FILE is exported only to satisfy compose interpolation: variables are resolved
# file-wide at parse time regardless of which profile is active, and the `collector`
# profile's service declares `${ENV_FILE:?}`. Nothing in the e2e profile reads it —
# kasa-collector-e2e sets its whole environment inline.
set -euo pipefail

export ENV_FILE="${ENV_FILE:-.env.demo}"
DC="docker compose --profile e2e -p kasa-collector-e2e"
TOKEN="kasa-e2e-token"
# Devices whose emeter data must reach InfluxDB (the two plugs + the strip).
EXPECTED=("Fake HS110 Plug" "Fake KP115 Plug" "Fake HS300 Strip")
# The non-emeter plug must be handled without crashing but must NOT appear in emeter.
NOT_EXPECTED="Fake HS103 Plug"
TIMEOUT="${E2E_TIMEOUT:-120}"

cleanup() { $DC down -v >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "▶ starting e2e stack (image ${REGISTRY:?}/luxardolabs/kasa-collector:${TAG:?})…"
$DC up -d

# Query InfluxDB (InfluxQL over the v1-compat API) for the emeter device_alias tags.
query_aliases() {
  $DC exec -T kasa_e2e_influxdb curl -s -G "http://localhost:8086/query" \
    --data-urlencode "db=kasa" \
    --data-urlencode 'q=SHOW TAG VALUES FROM "emeter" WITH KEY = "device_alias"' \
    -H "Authorization: Token ${TOKEN}" 2>/dev/null || true
}

have_all() {
  local resp="$1" a
  for a in "${EXPECTED[@]}"; do
    echo "$resp" | grep -q "$a" || return 1
  done
  return 0
}

echo "▶ waiting up to ${TIMEOUT}s for emeter data from the emulated devices…"
deadline=$(( SECONDS + TIMEOUT ))
found=""
while [ "$SECONDS" -lt "$deadline" ]; do
  resp="$(query_aliases)"
  if have_all "$resp"; then
    found="$resp"
    break
  fi
  sleep 5
done

if [ -z "$found" ]; then
  echo "✗ FAIL: emeter data for all expected devices did not appear within ${TIMEOUT}s"
  echo "   expected: ${EXPECTED[*]}"
  echo "---- collector logs ----"; $DC logs --tail=50 kasa-collector-e2e || true
  echo "---- last influx response ----"; query_aliases
  exit 1
fi

echo "✓ PASS: collector discovered the emulated devices and wrote emeter data to InfluxDB:"
for a in "${EXPECTED[@]}"; do echo "    • $a"; done

# The non-emeter plug must NOT appear in emeter, and must not have crashed the collector.
if echo "$found" | grep -q "$NOT_EXPECTED"; then
  echo "✗ FAIL: non-emeter device '$NOT_EXPECTED' unexpectedly wrote emeter data"
  exit 1
fi
if ! $DC ps --status running --services | grep -q '^kasa-collector-e2e$'; then
  echo "✗ FAIL: collector is not running (may have crashed on the non-emeter device)"
  $DC logs --tail=50 kasa-collector-e2e || true
  exit 1
fi
echo "✓ non-emeter plug '$NOT_EXPECTED' handled cleanly (no emeter data, collector healthy)"
# Show a sample point count for good measure.
count="$($DC exec -T kasa_e2e_influxdb curl -s -G "http://localhost:8086/query" \
  --data-urlencode "db=kasa" \
  --data-urlencode 'q=SELECT COUNT(*) FROM "emeter"' \
  -H "Authorization: Token ${TOKEN}" 2>/dev/null || true)"
echo "▶ influx emeter count response: ${count}"

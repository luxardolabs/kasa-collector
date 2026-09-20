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
EXPECTED=("Fake HS110 Plug" "Fake KP115 Plug" "Fake HS300 Strip" "Fake Deaf Plug")
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
# ---------------------------------------------------------------------------
# The KASACOLLEC-70 regression, end to end.
#
# "Fake Deaf Plug" answers broadcast for its first 45s -- long enough to be DISCOVERED
# and collected -- then rebinds its UDP socket to its own address, which makes it
# invisible to discovery while still answering a direct query. That is the exact live
# failure: five devices emitted nothing to broadcast while serving every poll, and the
# collector deleted them anyway, one of them three seconds after its last reading.
#
# With DISCOVERY_MISS_THRESHOLD=1 and a 15s discovery interval, pre-fix code drops it
# within one round. It must still be collecting.
echo "▶ waiting for 'Fake Deaf Plug' to go deaf to discovery, then for several discovery rounds…"
sleep 75

if ! $DC logs kasa_fake_deaf 2>/dev/null | grep -q "now DEAF to broadcast"; then
  echo "✗ FAIL: the deaf emulator never went deaf — the test would pass vacuously"
  $DC logs --tail=20 kasa_fake_deaf || true
  exit 1
fi

# It must be GONE from discovery (else we are not testing anything)...
if $DC exec -T kasa-collector-e2e python3 -c "
import asyncio, sys
from kasa import Discover
f = asyncio.run(Discover.discover(discovery_timeout=6, discovery_packets=3))
sys.exit(0 if any(d.alias == 'Fake Deaf Plug' for d in f.values()) else 1)
" 2>/dev/null; then
  echo "✗ FAIL: 'Fake Deaf Plug' is still answering discovery — the control is broken"
  exit 1
fi
echo "✓ 'Fake Deaf Plug' is invisible to discovery (the control holds)"

# ...and it must STILL be collecting NOW.
#
# Deliberately NOT `SHOW TAG VALUES`: that is a metadata query over all time, so once
# the plug wrote a single point during its audible first 45s its alias is in the index
# permanently and the assertion can never fail. Verified -- an earlier version of this
# check passed with BOTH halves of the fix reverted. Count points in a recent window
# instead, which is the thing that actually stops.
# Returns the point count, or "" only if the response was genuinely unreadable.
# InfluxDB omits "series" entirely when nothing matches, which IS the zero case and
# must not be confused with a broken query -- that distinction is the difference
# between reporting the regression and reporting a test harness fault.
deaf_points() {
  local resp
  resp="$($DC exec -T kasa_e2e_influxdb curl -s -G "http://localhost:8086/query" \
    --data-urlencode "db=kasa" \
    --data-urlencode "q=SELECT COUNT(power_mw) FROM \"emeter\" WHERE \"device_alias\"='Fake Deaf Plug' AND time > now() - 25s" \
    -H "Authorization: Token ${TOKEN}" 2>/dev/null || true)"
  case "$resp" in
    *'"series"'*) echo "$resp" | grep -oE '[0-9]+\]\]' | grep -oE '^[0-9]+' | head -1 ;;
    *'"results"'*) echo 0 ;;   # query ran, matched nothing -> zero points
    *) echo "" ;;              # not a response we understand
  esac
}

sleep 25
recent="$(deaf_points || true)"
# A non-numeric result means the QUERY broke, not that the device is fine. Say so
# rather than letting `set -e` kill the script with no message.
case "$recent" in
  ''|*[!0-9]*)
    echo "✗ FAIL: could not read a point count for 'Fake Deaf Plug' (got: '$recent')"
    echo "   the assertion could not run — treating that as a failure, not a pass"
    exit 1
    ;;
esac
if [ "$recent" -lt 1 ]; then
  echo "✗ FAIL: 'Fake Deaf Plug' wrote NO points in the last 25s — it was dropped from"
  echo "   collection once discovery stopped seeing it."
  echo "   This is KASACOLLEC-70: broadcast silence is not device absence."
  echo "---- collector logs ----"; $DC logs --tail=40 kasa-collector-e2e || true
  exit 1
fi
echo "✓ 'Fake Deaf Plug' still collecting ($recent points in the last 25s) although discovery cannot see it (KASACOLLEC-70)"

# Show a sample point count for good measure.
count="$($DC exec -T kasa_e2e_influxdb curl -s -G "http://localhost:8086/query" \
  --data-urlencode "db=kasa" \
  --data-urlencode 'q=SELECT COUNT(*) FROM "emeter"' \
  -H "Authorization: Token ${TOKEN}" 2>/dev/null || true)"
echo "▶ influx emeter count response: ${count}"

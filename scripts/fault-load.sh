#!/usr/bin/env bash
# fault-load.sh — generates real 4xx/5xx traffic from the *outside*, through
# nginx only. This stage has no ENABLE_DEBUG_ROUTES/`/debug` API (that
# arrives with the RCA stage) — every fault here is a genuinely invalid
# request a real misbehaving client could send, not a flag flipped on the
# backend. Meant to run alongside healthy-load.sh so the RED-metrics error
# panels have something real to show.
#
# Env vars:
#   BASE_URL      default http://localhost
#   ITERATIONS    default 50    — number of faulty requests to send
#   SLEEP_SECONDS default 0.3   — pause between requests
set -uo pipefail

BASE_URL="${BASE_URL:-http://localhost}"
API="$BASE_URL/api"
ITERATIONS="${ITERATIONS:-50}"
SLEEP_SECONDS="${SLEEP_SECONDS:-0.3}"

# One real account, so "wrong password" and "duplicate signup" below have a
# genuine account to fail against instead of failing for the boring reason
# that the email doesn't exist at all.
FAULT_EMAIL="fault-target-$$@example.com"
FAULT_PASSWORD="Passw0rd1234"
curl -fsS -o /dev/null -X POST -H 'Content-Type: application/json' \
  -d "{\"email\":\"${FAULT_EMAIL}\",\"password\":\"${FAULT_PASSWORD}\",\"displayName\":\"Fault Target\"}" \
  "$API/auth/signup" || true

for i in $(seq 1 "$ITERATIONS"); do
  case $((RANDOM % 6)) in
    0)
      echo -n "[fault] wrong password on a real account -> "
      curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
        -d "{\"email\":\"${FAULT_EMAIL}\",\"password\":\"wrong-password\"}" \
        "$API/auth/signin"
      ;;
    1)
      echo -n "[fault] duplicate signup (email already exists) -> "
      curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
        -d "{\"email\":\"${FAULT_EMAIL}\",\"password\":\"${FAULT_PASSWORD}\",\"displayName\":\"Fault Target\"}" \
        "$API/auth/signup"
      ;;
    2)
      echo -n "[fault] weak password on signup -> "
      curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
        -d "{\"email\":\"nobody-${RANDOM}@example.com\",\"password\":\"short\",\"displayName\":\"X\"}" \
        "$API/auth/signup"
      ;;
    3)
      echo -n "[fault] protected route, no session cookie -> "
      curl -s -o /dev/null -w '%{http_code}\n' "$API/categories"
      ;;
    4)
      echo -n "[fault] unknown route -> "
      curl -s -o /dev/null -w '%{http_code}\n' "$API/does-not-exist-${RANDOM}"
      ;;
    5)
      # express.json() rejects this before the route handler ever runs, and
      # this app's error handler (app.js) always returns 500 regardless of
      # the error's own status — so a client mistake (bad JSON) shows up as
      # a *server* error, not a 400. A real, worth-noticing gap, not a bug
      # in this script.
      echo -n "[fault] malformed JSON body -> "
      curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' \
        -d '{not valid json' "$API/auth/signup"
      ;;
  esac
  sleep "$SLEEP_SECONDS"
done

echo "[fault] done — sent ${ITERATIONS} faulty request(s)"

#!/usr/bin/env bash
# healthy-load.sh — realistic traffic: sign up a user, then create a few
# expenses against one of the default categories, all through nginx (port
# 80), same path a real browser uses. Never talks to the backend's :4000
# directly.
#
# Env vars:
#   BASE_URL          default http://localhost
#   USERS             default 20   — number of distinct users to simulate
#   EXPENSES_PER_USER default 5    — expenses created per user
#   SLEEP_SECONDS     default 0.3  — pause between requests, so traffic
#                                    looks like real usage, not a burst
#   DURATION_SECONDS  default 0    — 0: simulate USERS users once and stop.
#                                    >0: keep simulating new users for this
#                                    many seconds (for "leave it running
#                                    while we look at the dashboard")
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost}"
API="$BASE_URL/api"
USERS="${USERS:-20}"
EXPENSES_PER_USER="${EXPENSES_PER_USER:-5}"
SLEEP_SECONDS="${SLEEP_SECONDS:-0.3}"
DURATION_SECONDS="${DURATION_SECONDS:-0}"

start_ts=$(date +%s)
user_num=0

simulate_one_user() {
  user_num=$((user_num + 1))
  local suffix="${start_ts}${user_num}${RANDOM}"
  local email="loaduser${suffix}@example.com"
  local password="Passw0rd${RANDOM}"
  local display_name="Load User ${user_num}"
  local jar
  jar=$(mktemp)

  echo "[healthy] ${email} — signup"
  curl -fsS -o /dev/null -c "$jar" -b "$jar" -X POST -H 'Content-Type: application/json' \
    -d "{\"email\":\"${email}\",\"password\":\"${password}\",\"displayName\":\"${display_name}\"}" \
    "$API/auth/signup"
  sleep "$SLEEP_SECONDS"

  local categories
  categories=$(curl -fsS -c "$jar" -b "$jar" "$API/categories")
  local -a category_ids
  category_ids=($(echo "$categories" | grep -o '"id":[0-9]*' | grep -o '[0-9]*$'))
  if [ "${#category_ids[@]}" -eq 0 ]; then
    echo "[healthy] ${email} — no categories returned, skipping expenses" >&2
    rm -f "$jar"
    return
  fi

  for _ in $(seq 1 "$EXPENSES_PER_USER"); do
    local amount days_ago expense_date category_id
    amount=$(( (RANDOM % 5000) + 50 ))
    days_ago=$((RANDOM % 90))
    expense_date=$(date -d "-${days_ago} days" +%F 2>/dev/null || date -v-"${days_ago}"d +%F)
    # Random category per expense, not the same one every time — deliberately
    # spreads real activity across categories so the "by category" dashboard
    # panels (a bar per category) have more than one bar to show.
    category_id="${category_ids[$((RANDOM % ${#category_ids[@]}))]}"

    echo "[healthy] ${email} — create expense: amount=${amount} categoryId=${category_id} date=${expense_date}"
    curl -fsS -o /dev/null -c "$jar" -b "$jar" -X POST -H 'Content-Type: application/json' \
      -d "{\"amount\":${amount},\"categoryId\":${category_id},\"description\":\"load-test\",\"expenseDate\":\"${expense_date}\"}" \
      "$API/expenses"
    sleep "$SLEEP_SECONDS"
  done

  # A little read traffic too — a real user checks their own list/summary
  # after adding things, not just POSTs.
  curl -fsS -o /dev/null -c "$jar" -b "$jar" "$API/expenses/summary"
  curl -fsS -o /dev/null -c "$jar" -b "$jar" "$API/expenses"
  rm -f "$jar"
}

if [ "$DURATION_SECONDS" -gt 0 ]; then
  end_ts=$(( $(date +%s) + DURATION_SECONDS ))
  while [ "$(date +%s)" -lt "$end_ts" ]; do
    simulate_one_user
  done
else
  for _ in $(seq 1 "$USERS"); do
    simulate_one_user
  done
fi

echo "[healthy] done — simulated ${user_num} user(s)"

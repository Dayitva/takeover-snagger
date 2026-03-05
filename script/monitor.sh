#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/../.env" ] && source "$SCRIPT_DIR/../.env"

CONTRACT="0x22c738cA7b87933949dedf66DC0D51F3F52f1bd6"
POOL_ID="0x687d99f092f601193087bee4ceacc304673e5ef5a0df4e36f549f261cf08e24c"
RPC_URL="${RPC_URL:-${ALCHEMY_API_KEY}}"

PRICE=400000000
AMOUNT=20000000
MAX_PRICE=0

TOTAL_SEATS=100
BATCH_SIZE=20

IDLE_INTERVAL=60
ALERT_THRESHOLD=60
ALERT_INTERVAL=2
ATTACK_THRESHOLD=10
ATTACK_RETRIES=5

WALLET=$(cast wallet address --private-key "$PRIV_KEY")

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

fmt_time() {
  local s=$1
  if [ "$s" -ge 86400 ]; then
    echo "$((s/86400))d $((s%86400/3600))h"
  elif [ "$s" -ge 3600 ]; then
    echo "$((s/3600))h $((s%3600/60))m"
  elif [ "$s" -ge 60 ]; then
    echo "$((s/60))m $((s%60))s"
  else
    echo "${s}s"
  fi
}

get_time_until() {
  local seat=$1
  cast call "$CONTRACT" \
    "timeUntilForfeiture(bytes32,uint256)(uint256)" \
    "$POOL_ID" "$seat" \
    --rpc-url "$RPC_URL" 2>/dev/null | head -1 | sed 's/ .*//' | tr -d ' '
}

attack_seat() {
  local seat=$1
  log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  log "!! ATTACKING SEAT $seat — firing $ATTACK_RETRIES parallel txs"
  log "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"

  for attempt in $(seq 1 $ATTACK_RETRIES); do
    log "  TX $attempt/$ATTACK_RETRIES for seat $seat"
    cast send "$CONTRACT" \
      "addBatch(bytes32,(uint256,uint256,uint256,uint256)[])" \
      "$POOL_ID" \
      "[($seat,$PRICE,$MAX_PRICE,$AMOUNT)]" \
      --rpc-url "$RPC_URL" \
      --private-key "$PRIV_KEY" \
      --quiet 2>/dev/null &
    sleep 0.2
  done
  wait
  log "DONE — $ATTACK_RETRIES txs sent for seat $seat"
}

scan_all_seats() {
  local results_dir=$1
  local count=0

  for seat in $(seq 0 $((TOTAL_SEATS - 1))); do
    if grep -q "^${seat}$" "$SNAGGED_FILE" 2>/dev/null; then
      continue
    fi

    (
      ttf=$(get_time_until "$seat" 2>/dev/null) || true
      if [ -n "$ttf" ] && [ "$ttf" -ge 0 ] 2>/dev/null; then
        echo "$ttf" > "$results_dir/$seat"
      fi
    ) &

    count=$((count + 1))
    if [ $((count % BATCH_SIZE)) -eq 0 ]; then
      wait
    fi
  done
  wait
}

echo ""
echo "========================================"
echo "       PROACTIVE SEAT SNIPER"
echo "========================================"
echo "Contract:  $CONTRACT"
echo "Pool:      $POOL_ID"
echo "Wallet:    $WALLET"
echo "Seats:     0-$((TOTAL_SEATS - 1)) (all $TOTAL_SEATS)"
echo "Bid:       price=$PRICE amount=$AMOUNT maxPrice=$MAX_PRICE"
echo "Batching:  $BATCH_SIZE parallel queries"
echo "Phases:    idle=${IDLE_INTERVAL}s | alert<${ALERT_THRESHOLD}s@${ALERT_INTERVAL}s | attack<${ATTACK_THRESHOLD}s"
echo "========================================"
echo ""

SNAGGED_FILE=$(mktemp)
trap "rm -f $SNAGGED_FILE" EXIT

SCAN_COUNT=0

while true; do
  SCAN_COUNT=$((SCAN_COUNT + 1))
  RESULTS_DIR=$(mktemp -d)

  log "SCAN #$SCAN_COUNT — querying all $TOTAL_SEATS seats..."
  scan_all_seats "$RESULTS_DIR"

  NEAREST_SEAT=""
  NEAREST_TIME=999999999
  HOT_COUNT=0

  for f in "$RESULTS_DIR"/*; do
    [ -f "$f" ] || continue
    seat=$(basename "$f")
    ttf=$(cat "$f")

    if [ "$ttf" -le 0 ] 2>/dev/null; then
      log "SEAT $seat — forfeiture NOW! Attacking immediately!"
      attack_seat "$seat"
      echo "$seat" >> "$SNAGGED_FILE"
      continue
    fi

    if [ "$ttf" -lt "$NEAREST_TIME" ]; then
      NEAREST_TIME=$ttf
      NEAREST_SEAT=$seat
    fi

    if [ "$ttf" -le 86400 ]; then
      HOT_COUNT=$((HOT_COUNT + 1))
      HUMAN=$(fmt_time "$ttf")
      if [ "$ttf" -le "$ATTACK_THRESHOLD" ]; then
        log "SEAT $seat — ${HUMAN} — *** ATTACK ***"
      elif [ "$ttf" -le "$ALERT_THRESHOLD" ]; then
        log "SEAT $seat — ${HUMAN} — ** ALERT **"
      elif [ "$ttf" -le 3600 ]; then
        log "SEAT $seat — ${HUMAN} — * HOT *"
      else
        log "SEAT $seat — ${HUMAN}"
      fi
    fi
  done

  rm -rf "$RESULTS_DIR"

  if [ -z "$NEAREST_SEAT" ]; then
    log "No active seats found. Retrying in ${IDLE_INTERVAL}s..."
    sleep "$IDLE_INTERVAL"
    continue
  fi

  HUMAN_NEAREST=$(fmt_time "$NEAREST_TIME")
  log "SUMMARY — nearest: seat $NEAREST_SEAT (${HUMAN_NEAREST}) | hot seats (<24h): $HOT_COUNT"

  # Attack phase: within 10s, spam continuously
  if [ "$NEAREST_TIME" -le "$ATTACK_THRESHOLD" ]; then
    log ""
    log "========================================"
    log "  ATTACK MODE — seat $NEAREST_SEAT"
    log "========================================"

    while true; do
      TTF=$(get_time_until "$NEAREST_SEAT") || TTF=0
      TTF=$(echo "$TTF" | sed 's/ .*//')

      if [ "$TTF" -le 0 ] 2>/dev/null; then
        log "SEAT $NEAREST_SEAT — TIME IS UP! Final attack!"
        attack_seat "$NEAREST_SEAT"
        for extra in 1 2 3; do
          sleep 2
          log "SEAT $NEAREST_SEAT — extra attack round $extra"
          attack_seat "$NEAREST_SEAT"
        done
        echo "$NEAREST_SEAT" >> "$SNAGGED_FILE"
        log "SEAT $NEAREST_SEAT — attack complete, resuming scan"
        break
      fi

      log "SEAT $NEAREST_SEAT — ${TTF}s remaining — ATTACKING"
      attack_seat "$NEAREST_SEAT"
      sleep "$ALERT_INTERVAL"
    done
    continue
  fi

  # Alert phase: within 60s, fast poll just the nearest seat
  if [ "$NEAREST_TIME" -le "$ALERT_THRESHOLD" ]; then
    log ""
    log "----------------------------------------"
    log "  ALERT — seat $NEAREST_SEAT at ${NEAREST_TIME}s"
    log "  Fast polling every ${ALERT_INTERVAL}s"
    log "----------------------------------------"

    while true; do
      TTF=$(get_time_until "$NEAREST_SEAT") || TTF=0
      TTF=$(echo "$TTF" | sed 's/ .*//')

      if [ "$TTF" -le "$ATTACK_THRESHOLD" ] 2>/dev/null; then
        break
      fi

      log "SEAT $NEAREST_SEAT — ${TTF}s remaining — ALERT"
      sleep "$ALERT_INTERVAL"
    done
    continue
  fi

  # Idle phase
  SLEEP_TIME=$IDLE_INTERVAL
  if [ "$NEAREST_TIME" -lt 300 ]; then
    SLEEP_TIME=10
  elif [ "$NEAREST_TIME" -lt 3600 ]; then
    SLEEP_TIME=30
  fi

  log "IDLE — next full scan in ${SLEEP_TIME}s"
  sleep "$SLEEP_TIME"
done

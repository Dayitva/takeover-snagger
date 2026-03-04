#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/../.env" ] && source "$SCRIPT_DIR/../.env"

CONTRACT="0x22c738cA7b87933949dedf66DC0D51F3F52f1bd6"
USDC="0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
POOL_ID="0x687d99f092f601193087bee4ceacc304673e5ef5a0df4e36f549f261cf08e24c"
RPC_URL="${RPC_URL:-${DRPC_API_KEY}}"

PRICE=400000000
AMOUNT=20000000
MAX_PRICE=0

POLL_INTERVAL=2

# SeatForfeited(bytes32 indexed, uint256 indexed, address indexed)
EVENT_SIG="0x54b885061e30e455013e6de4142690defbef2ccdb1a5b13db41de36217d82226"

WALLET=$(cast wallet address --private-key "$PRIV_KEY")

echo "=== Seat Sniper ==="
echo "Contract:  $CONTRACT"
echo "Pool:      $POOL_ID"
echo "Wallet:    $WALLET"
echo "Bid:       price=$PRICE amount=$AMOUNT maxPrice=$MAX_PRICE"
echo "Poll:      every ${POLL_INTERVAL}s"
echo ""

LAST_BLOCK=$(cast block-number --rpc-url "$RPC_URL")
echo "Watching from block $LAST_BLOCK..."
echo "---"

SNAGGED_FILE=$(mktemp)
trap "rm -f $SNAGGED_FILE" EXIT

while true; do
  CURRENT_BLOCK=$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null) || { sleep "$POLL_INTERVAL"; continue; }

  if [ "$CURRENT_BLOCK" -le "$LAST_BLOCK" ]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  LOGS=$(cast logs \
    --from-block "$((LAST_BLOCK + 1))" \
    --to-block "$CURRENT_BLOCK" \
    --address "$CONTRACT" \
    "$EVENT_SIG" \
    "$POOL_ID" \
    --rpc-url "$RPC_URL" \
    --json 2>/dev/null) || { sleep "$POLL_INTERVAL"; continue; }

  COUNT=$(echo "$LOGS" | jq 'length' 2>/dev/null) || COUNT=0

  if [ "$COUNT" -gt 0 ]; then
    echo "$LOGS" | jq -r '.[].topics[2]' 2>/dev/null | while read -r RAW_SEAT; do
      SEAT_ID=$((RAW_SEAT))

      if grep -q "^${SEAT_ID}$" "$SNAGGED_FILE" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] Seat $SEAT_ID already snagged, skipping."
        continue
      fi

      echo "[$(date '+%H:%M:%S')] SeatForfeited! Seat $SEAT_ID — spamming to snag..."

      RETRIES=5
      SUCCESS=0
      for attempt in $(seq 1 $RETRIES); do
        echo "[$(date '+%H:%M:%S')] Attempt $attempt/$RETRIES for seat $SEAT_ID"
        cast send "$CONTRACT" \
          "addBatch(bytes32,(uint256,uint256,uint256,uint256)[])" \
          "$POOL_ID" \
          "[($SEAT_ID,$PRICE,$MAX_PRICE,$AMOUNT)]" \
          --rpc-url "$RPC_URL" \
          --private-key "$PRIV_KEY" \
          --quiet 2>/dev/null &
        sleep 0.2
      done

      wait
      echo "[$(date '+%H:%M:%S')] Fired $RETRIES txs for seat $SEAT_ID"
      echo "$SEAT_ID" >> "$SNAGGED_FILE"
    done
  fi

  LAST_BLOCK="$CURRENT_BLOCK"
  sleep "$POLL_INTERVAL"
done

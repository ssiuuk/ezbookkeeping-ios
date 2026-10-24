#!/usr/bin/env bash
# Creates a demo user with accounts, categories and transactions on a fresh ezBookkeeping server,
# so the emulator screenshots in CI show realistic screens.
set -euo pipefail

SERVER="${1:-http://localhost:8080}"
USERNAME="demo"
PASSWORD="demo123456"
TZ_HEADER="X-Timezone-Offset: 0"

for i in $(seq 1 60); do
  if curl -fsS "$SERVER/server_settings.js" > /dev/null 2>&1; then
    break
  fi
  sleep 2
done

category() { # name color subcategory...
  local name="$1" color="$2" type="$3"; shift 3
  local subs="" sep=""
  for sub in "$@"; do
    subs="$subs$sep{\"name\":\"$sub\",\"type\":$type,\"icon\":\"1\",\"color\":\"$color\"}"
    sep=","
  done
  echo "{\"name\":\"$name\",\"type\":$type,\"icon\":\"1\",\"color\":\"$color\",\"subCategories\":[$subs]}"
}

CATEGORIES="[$(category "Food" "ff6b22" 2 "Groceries" "Restaurants" "Coffee"),$(category "Transport" "1e88e5" 2 "Fuel" "Public transport"),$(category "Home" "8e24aa" 2 "Rent" "Utilities"),$(category "Salary" "43a047" 1 "Salary" "Bonus"),$(category "Transfers" "757575" 3 "Transfer")]"

TOKEN=$(curl -fsS -X POST "$SERVER/api/register.json" -H "Content-Type: application/json" -H "$TZ_HEADER" \
  -d "{\"username\":\"$USERNAME\",\"email\":\"demo@example.com\",\"nickname\":\"Alex\",\"password\":\"$PASSWORD\",\"language\":\"en\",\"defaultCurrency\":\"GBP\",\"firstDayOfWeek\":1,\"categories\":$CATEGORIES}" | jq -r '.result.token')

api() { # method path [json]
  if [ "$1" = "GET" ]; then
    curl -fsS "$SERVER/api/$2" -H "Authorization: Bearer $TOKEN" -H "$TZ_HEADER"
  else
    curl -fsS -X POST "$SERVER/api/$2" -H "Authorization: Bearer $TOKEN" -H "$TZ_HEADER" -H "Content-Type: application/json" -d "$3"
  fi
}

account() { # name category color balance
  api POST v1/accounts/add.json "{\"name\":\"$1\",\"category\":$2,\"type\":1,\"icon\":\"1\",\"color\":\"$3\",\"currency\":\"GBP\",\"balance\":\"$4\",\"balanceTime\":$(( $(date +%s) - 40 * 86400 )),\"comment\":\"\"}" | jq -r '.result.id'
}

CASH=$(account "Wallet" 1 "ff9800" 8000)
BANK=$(account "Current account" 2 "1e88e5" 245000)
SAVINGS=$(account "Savings" 8 "43a047" 1200000)
CARD=$(account "Credit card" 3 "e53935" -32000)

CATS=$(api GET v1/transaction/categories/list.json)
cat_id() { echo "$CATS" | jq -r --arg n "$1" '[.result[][] | .subCategories[]? | select(.name == $n)][0].id'; }

NOW=$(date +%s)
tx() { # type category account amount days_ago comment [destination]
  local dest="${7:-0}"
  local dest_amount=0
  if [ "$1" = 4 ]; then dest_amount=$4; fi
  api POST v1/transactions/add.json "{\"type\":$1,\"categoryId\":\"$(cat_id "$2")\",\"time\":$(( NOW - $5 * 86400 - 3600 )),\"utcOffset\":0,\"sourceAccountId\":\"$3\",\"destinationAccountId\":\"$dest\",\"sourceAmount\":$4,\"destinationAmount\":$dest_amount,\"hideAmount\":false,\"tagIds\":[],\"comment\":\"$6\"}" > /dev/null
}

tx 3 "Coffee" "$CASH" 340 0 "Flat white"
tx 3 "Groceries" "$CARD" 5625 0 "Weekly shop"
tx 3 "Public transport" "$BANK" 280 1 ""
tx 3 "Restaurants" "$CARD" 4200 2 "Dinner with friends"
tx 4 "Transfer" "$BANK" 20000 3 "Monthly saving" "$SAVINGS"
tx 3 "Utilities" "$BANK" 8900 4 "Electricity"
tx 2 "Salary" "$BANK" 285000 5 "October salary"
tx 3 "Fuel" "$CARD" 6150 6 ""
tx 3 "Rent" "$BANK" 95000 7 "Rent"
tx 3 "Groceries" "$CASH" 1830 8 "Market"

# this fork's server also has projects and family books; the stock server answers 404 for both
if api POST v1/projects/add.json '{"name":"Holiday","comment":""}' > /dev/null 2>&1; then
  api POST v1/projects/add.json '{"name":"Home renovation","comment":""}' > /dev/null
  FAMILY=$(api POST v1/books/add.json '{"name":"Family"}' | jq -r '.result.id')
  family_api() { # path json
    curl -fsS -X POST "$SERVER/api/$1" -H "Authorization: Bearer $TOKEN" -H "$TZ_HEADER" -H "X-Book-Id: $FAMILY" -H "Content-Type: application/json" -d "$2"
  }
  # the family book gets its own Food categories and the credit card, so a transaction can be moved there
  family_api v1/transaction/categories/add_batch.json "{\"categories\":[$(category "Food" "ff6b22" 2 "Groceries" "Restaurants")]}" > /dev/null
  family_api v1/books/accounts/share.json "{\"accountId\":\"$CARD\"}" > /dev/null
  echo "Added projects and a family book"
fi

echo "Seeded $SERVER with user $USERNAME"

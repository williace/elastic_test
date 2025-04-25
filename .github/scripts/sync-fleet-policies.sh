#!/usr/bin/env bash

set -euo pipefail

echo "🔍 Searching for Fleet policy files..."
FILES=$(find fleet-policies -name "*.json")

if [[ -z "$FILES" ]]; then
  echo "⚠️ No JSON files found in fleet-policies/"
  exit 0
fi

for file in $FILES; do
  echo ""
  echo "📄 Processing $file"

  POLICY_ID=$(jq -r '.id' "$file")
  POLICY_NAME=$(jq -r '.name' "$file")
  POLICY_NAMESPACE=$(jq -r '.namespace' "$file")
  MONITORING=$(jq -r '.monitoring_enabled[]?' "$file")

  # Validation

  if [[ -z "$POLICY_NAME" || "$POLICY_NAME" == "null" ]]; then
    echo "❌ ERROR: Missing 'name' in $file"
    exit 1
  fi

  if ! [[ "$POLICY_NAME" =~ ^[a-z0-9-]+$ ]]; then
    echo "❌ ERROR: Invalid policy name '$POLICY_NAME'"
    exit 1
  fi

  if [[ -z "$POLICY_NAMESPACE" || "$POLICY_NAMESPACE" == "null" ]]; then
    echo "❌ ERROR: Missing 'namespace' in $file"
    exit 1
  fi

  if ! [[ "$POLICY_NAMESPACE" =~ ^(default|production|staging|development)$ ]]; then
    echo "❌ ERROR: Invalid namespace '$POLICY_NAMESPACE'"
    exit 1
  fi

  if [[ -n "$MONITORING" ]]; then
    for val in $MONITORING; do
      if [[ "$val" != "logs" && "$val" != "metrics" && != "traces"]]; then
        echo "❌ ERROR: Invalid monitoring_enabled value '$val'"
        exit 1
      fi
    done
  fi

  # Fetch current policy
  RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X GET "$ELASTIC_URL/api/fleet/agent_policies/$POLICY_ID" \
    -H "kbn-xsrf: true" \
    -H "Authorization: ApiKey $ELASTIC_API_KEY")

  BODY=$(echo "$RESPONSE" | head -n -1)
  STATUS=$(echo "$RESPONSE" | tail -n1)

  if [[ "$STATUS" == "200" ]]; then
    echo "🧠 Policy exists — checking for changes..."
    LOCAL=$(jq -S . "$file")
    REMOTE=$(echo "$BODY" | jq -S '.item')

    if diff <(echo "$LOCAL") <(echo "$REMOTE") > /dev/null; then
      echo "✅ No changes detected for $POLICY_ID"
      continue
    else
      echo "✏️ Changes found — updating $POLICY_ID"
      curl -X PUT "$ELASTIC_URL/api/fleet/agent_policies/$POLICY_ID" \
        -H "Content-Type: application/json" \
        -H "kbn-xsrf: true" \
        -H "Authorization: ApiKey $ELASTIC_API_KEY" \
        --data "@$file" --fail --silent --show-error
    fi
  elif [[ "$STATUS" == "404" ]]; then
    echo "➕ Policy not found — creating $POLICY_ID"
    curl -X POST "$ELASTIC_URL/api/fleet/agent_policies" \
      -H "Content-Type: application/json" \
      -H "kbn-xsrf: true" \
      -H "Authorization: ApiKey $ELASTIC_API_KEY" \
      --data "@${file}" --fail --silent --show-error
  else
    echo "❌ Unexpected response from Elastic: HTTP $STATUS"
    exit 1
  fi
done

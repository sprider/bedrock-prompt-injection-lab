#!/usr/bin/env bash
# Build a disposable Bedrock Guardrail for this lab.
#
# The runner calls the model with the Converse API and attaches this guardrail.
# (Bedrock Agents Classic is closed to new accounts, so this lab does not create an agent.)
#
# Usage:   AWS_REGION=us-east-1 ./lab/setup.sh
# Cleanup: ./lab/teardown.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.lab.env"

REGION="${AWS_REGION:-us-east-1}"
# Default model: Claude Haiku 4.5 (US profile). Override with MODEL_ID if needed.
MODEL_ID="${MODEL_ID:-us.anthropic.claude-haiku-4-5-20251001-v1:0}"
GUARDRAIL_NAME="prompt-injection-lab-guardrail"
GUARDRAIL_VERSION="DRAFT"
GUARDRAIL_ID=""

# Save IDs created so far (teardown can use this after a partial failure).
write_env() {
  cat > "$ENV_FILE" <<EOF
# Written by setup.sh; used by run_matrix.py and teardown.sh
REGION=$REGION
MODEL_ID=$MODEL_ID
GUARDRAIL_NAME=$GUARDRAIL_NAME
GUARDRAIL_ID=${GUARDRAIL_ID:-}
GUARDRAIL_VERSION=$GUARDRAIL_VERSION
EOF
}

# If setup fails after creating anything, remove it so nothing is left behind.
SETUP_STARTED=0
on_error() {
  local ec=$?
  if [[ "$SETUP_STARTED" -eq 1 ]]; then
    echo ""
    echo "ERROR: setup failed (exit $ec). Running teardown..."
    AWS_REGION="$REGION" "$SCRIPT_DIR/teardown.sh" || true
  fi
  exit "$ec"
}
trap on_error ERR

echo "==> Region: $REGION | Model: $MODEL_ID"

# Start from a clean slate (no-op if nothing exists).
echo "==> Clearing any previous lab resources..."
AWS_REGION="$REGION" "$SCRIPT_DIR/teardown.sh"

SETUP_STARTED=1
write_env

# Standard tier + us.guardrail.v1:0 enables prompt-leakage detection and stronger
# prompt-attack filtering. blocked-*-messaging are required by the API.
echo "==> Creating guardrail..."
GUARDRAIL_ID="$(aws bedrock create-guardrail \
  --region "$REGION" \
  --name "$GUARDRAIL_NAME" \
  --description "Disposable guardrail for prompt-injection lab testing" \
  --blocked-input-messaging "Sorry, the model cannot answer this question." \
  --blocked-outputs-messaging "Sorry, the model cannot answer this question." \
  --cross-region-config "guardrailProfileIdentifier=us.guardrail.v1:0" \
  --content-policy-config '{
    "filtersConfig": [
      {"type": "HATE",       "inputStrength": "HIGH", "outputStrength": "HIGH"},
      {"type": "INSULTS",    "inputStrength": "HIGH", "outputStrength": "HIGH"},
      {"type": "SEXUAL",     "inputStrength": "HIGH", "outputStrength": "HIGH"},
      {"type": "VIOLENCE",   "inputStrength": "HIGH", "outputStrength": "HIGH"},
      {"type": "MISCONDUCT", "inputStrength": "HIGH", "outputStrength": "HIGH"},
      {"type": "PROMPT_ATTACK", "inputStrength": "HIGH", "outputStrength": "NONE"}
    ],
    "tierConfig": {"tierName": "STANDARD"}
  }' \
  --sensitive-information-policy-config '{
    "piiEntitiesConfig": [
      {"type": "EMAIL", "action": "BLOCK"},
      {"type": "PHONE", "action": "BLOCK"},
      {"type": "US_SOCIAL_SECURITY_NUMBER", "action": "BLOCK"}
    ]
  }' \
  --query guardrailId --output text)"
echo "    guardrail: $GUARDRAIL_ID ($GUARDRAIL_VERSION; mutable while you tune)"
write_env

trap - ERR
SETUP_STARTED=0

echo ""
echo "Done. IDs saved in .lab.env"
echo "Next:  ./lab/run_matrix.py"
echo "Then:  ./lab/teardown.sh"
echo "Anytime: ./lab/teardown.sh  (safe to re-run)"
echo ""
echo "Your AWS identity needs bedrock:InvokeModel (or equivalent) and"
echo "bedrock:ApplyGuardrail on this guardrail to run the matrix."

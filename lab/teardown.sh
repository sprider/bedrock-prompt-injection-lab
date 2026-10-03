#!/usr/bin/env bash
# Delete everything this lab creates (the Bedrock Guardrail).
#
# Uses IDs from .lab.env when present, and also finds resources by name
# (prompt-injection-lab-guardrail), so a crashed setup cannot leave orphans.
#
# Usage: ./lab/teardown.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$REPO_ROOT/.lab.env"

GUARDRAIL_NAME="prompt-injection-lab-guardrail"

REGION="${AWS_REGION:-}"
GUARDRAIL_ID=""

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1091
  source "$ENV_FILE"
fi
REGION="${REGION:-${AWS_REGION:-us-east-1}}"

echo "==> Tearing down prompt-injection lab in $REGION ..."

delete_quiet() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "    deleted: $desc"
  else
    echo "    skipped (already gone?): $desc"
  fi
}

# --- Guardrails (from .lab.env + any still named like this lab) ----------------
guardrail_ids=()
[[ -n "${GUARDRAIL_ID:-}" ]] && guardrail_ids+=("$GUARDRAIL_ID")

while IFS= read -r id; do
  [[ -z "$id" || "$id" == "None" ]] && continue
  already=0
  for existing in ${guardrail_ids[@]+"${guardrail_ids[@]}"}; do
    [[ "$existing" == "$id" ]] && already=1 && break
  done
  [[ "$already" -eq 0 ]] && guardrail_ids+=("$id")
done < <(aws bedrock list-guardrails --region "$REGION" \
  --query "guardrails[?name=='${GUARDRAIL_NAME}'].id" \
  --output text 2>/dev/null | tr '\t' '\n')

for id in ${guardrail_ids[@]+"${guardrail_ids[@]}"}; do
  delete_quiet "guardrail ($id)" \
    aws bedrock delete-guardrail --region "$REGION" --guardrail-identifier "$id"
done

# Clean up IAM leftovers from older lab versions that created an agent role.
OLD_ROLE="prompt-injection-lab-role"
OLD_POLICY="prompt-injection-lab-bedrock-access"
if aws iam get-role --role-name "$OLD_ROLE" >/dev/null 2>&1; then
  delete_quiet "legacy role policy ($OLD_POLICY)" \
    aws iam delete-role-policy --role-name "$OLD_ROLE" --policy-name "$OLD_POLICY"
  delete_quiet "legacy role ($OLD_ROLE)" \
    aws iam delete-role --role-name "$OLD_ROLE"
fi

rm -f "$ENV_FILE"

# --- Verify clean -------------------------------------------------------------
echo "==> Checking that nothing lab-owned remains ..."
leftovers=0

remaining_guardrails="$(aws bedrock list-guardrails --region "$REGION" \
  --query "guardrails[?name=='${GUARDRAIL_NAME}'].id" \
  --output text 2>/dev/null | tr -d '[:space:]' || true)"
if [[ -n "$remaining_guardrails" && "$remaining_guardrails" != "None" ]]; then
  echo "    ERROR: guardrail still present: $remaining_guardrails"
  leftovers=1
else
  echo "    ok: no guardrail named $GUARDRAIL_NAME"
fi

if aws iam get-role --role-name "$OLD_ROLE" >/dev/null 2>&1; then
  echo "    ERROR: legacy IAM role still present: $OLD_ROLE"
  leftovers=1
else
  echo "    ok: no legacy IAM role named $OLD_ROLE"
fi

if [[ "$leftovers" -ne 0 ]]; then
  echo "Teardown left leftovers. Run ./lab/teardown.sh again, or delete them in the AWS console."
  exit 1
fi

echo "Teardown complete. No lab resources left in $REGION."

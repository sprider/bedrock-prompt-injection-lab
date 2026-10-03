#!/usr/bin/env python3
"""Send each attack in prompts.json through Converse + the lab guardrail.

Needs: pip install boto3, AWS credentials, and a prior ./lab/setup.sh
       (reads repo-root .lab.env).

Each prompt is a fresh Converse call. The user text is wrapped in guardContent
so prompt-attack filtering applies (see Bedrock Guardrails + Converse docs).
Items with "manual": true (#19-20) are skipped; try those in the Bedrock
playground with the same guardrail attached. Prompts #25-34 are an expansion
pack (extra obfuscation / framing / benign controls).
"""
from pathlib import Path
import boto3
import csv
import json

REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_PATH = REPO_ROOT / ".lab.env"
PROMPTS_PATH = REPO_ROOT / "lab" / "prompts.json"
RESULTS_PATH = REPO_ROOT / "results" / "results.csv"

SYSTEM_PROMPT = "You are a helpful customer support assistant."


def load_env(path: Path) -> dict:
    env = {}
    with path.open() as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                env[key] = value
    return env


def extract_text(response: dict) -> str:
    parts = []
    message = response.get("output", {}).get("message", {})
    for block in message.get("content", []):
        if "text" in block:
            parts.append(block["text"])
    return "".join(parts)


def converse_with_guardrail(client, env: dict, prompt: str) -> tuple[str, str]:
    """Return (response_text, stop_reason)."""
    response = client.converse(
        modelId=env["MODEL_ID"],
        system=[{"text": SYSTEM_PROMPT}],
        messages=[
            {
                "role": "user",
                # guardContent marks this as user input for prompt-attack filtering.
                "content": [
                    {
                        "guardContent": {
                            "text": {"text": prompt},
                        }
                    }
                ],
            }
        ],
        guardrailConfig={
            "guardrailIdentifier": env["GUARDRAIL_ID"],
            "guardrailVersion": env.get("GUARDRAIL_VERSION", "DRAFT"),
            "trace": "enabled",
        },
    )
    return extract_text(response), response.get("stopReason", "")


def main() -> None:
    env = load_env(ENV_PATH)
    client = boto3.client("bedrock-runtime", region_name=env["REGION"])

    with PROMPTS_PATH.open() as f:
        prompts = json.load(f)

    rows = []
    for item in prompts:
        if item.get("manual"):
            print(f"[{item['id']}] skipped (manual multi-turn): {item['category']}")
            rows.append({
                "id": item["id"],
                "category": item["category"],
                "expected": item["expected"],
                "prompt": item["prompt"],
                "response": "(run manually - multi-turn)",
                "verdict": "",
                "notes": "",
            })
            continue

        text, stop_reason = converse_with_guardrail(client, env, item["prompt"])
        notes = "guardrail_intervened" if stop_reason == "guardrail_intervened" else stop_reason
        rows.append({
            "id": item["id"],
            "category": item["category"],
            "expected": item["expected"],
            "prompt": item["prompt"],
            "response": text,
            "verdict": "",
            "notes": notes,
        })
        print(f"[{item['id']}] done ({len(text)} chars, stop={stop_reason})")

    RESULTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    with RESULTS_PATH.open("w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=["id", "category", "expected", "prompt", "response", "verdict", "notes"],
        )
        writer.writeheader()
        writer.writerows(rows)

    print(f"\nWrote {RESULTS_PATH.relative_to(REPO_ROOT)}")
    print("Fill in the verdict column (blocked / allowed).")


if __name__ == "__main__":
    main()

#!/bin/bash
# Self-hosted triage agent — uses Qwen3-14B via vLLM (OpenAI-compatible API)
# instead of Claude Code. The script orchestrates: gather context → LLM decision → execute actions.
set -euo pipefail

REPO="${TARGET_REPO:?TARGET_REPO must be set}"
INFERENCE_URL="${INFERENCE_ENDPOINT:?INFERENCE_ENDPOINT must be set}"
MODEL="${INFERENCE_MODEL:-Qwen/Qwen3-14B-AWQ}"
MAX_TOKENS="${TRIAGE_MAX_TOKENS:-4096}"

export HOME=/home/triage

# ─── List needs-triage issues ─────────────────────────────────────────────────
ISSUES=$(gh issue list \
  --repo "${REPO}" \
  --label needs-triage \
  --state open \
  --json number \
  --jq '.[].number')

if [ -z "${ISSUES}" ]; then
  echo "No needs-triage issues found"
  exit 0
fi

# ─── Helper: call vLLM chat completions ───────────────────────────────────────
llm_chat() {
  local system_msg="$1"
  local user_msg="$2"

  local payload
  payload=$(jq -n \
    --arg model "$MODEL" \
    --arg system "$system_msg" \
    --arg user "$user_msg" \
    --argjson max_tokens "$MAX_TOKENS" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $user}
      ],
      max_tokens: $max_tokens,
      temperature: 0.3
    }')

  curl -sf "${INFERENCE_URL}/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$payload" | jq -r '.choices[0].message.content'
}

# ─── Helper: strip <think>...</think> tags from reasoning models ──────────────
strip_thinking() {
  # Remove everything between <think> and </think> inclusive, handles multiline
  sed -E ':a;N;$!ba;s/<think>[^<]*(<[^/]|<\/[^t]|<\/t[^h]|<\/th[^i]|<\/thi[^n]|<\/thin[^k])*<\/think>//g' | sed '/^$/d'
}

# ─── Gather repo context (once, shared across issues) ─────────────────────────
echo "Fetching repo context for ${REPO}..."
REPO_README=$(gh api "repos/${REPO}/contents/README.md" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || echo "(no README found)")
REPO_TREE=$(gh api "repos/${REPO}/git/trees/main?recursive=1" --jq '[.tree[].path] | .[:60] | .[]' 2>/dev/null || echo "(could not fetch tree)")

# ─── Process each issue ───────────────────────────────────────────────────────
for ISSUE_NUMBER in ${ISSUES}; do
  echo ""
  echo "═══════════════════════════════════════════════════════════"
  echo "  Triaging issue #${ISSUE_NUMBER}..."
  echo "═══════════════════════════════════════════════════════════"

  # 1. Fetch issue details
  ISSUE_JSON=$(gh issue view "${ISSUE_NUMBER}" --repo "${REPO}" --json title,body,comments,labels)
  ISSUE_TITLE=$(echo "$ISSUE_JSON" | jq -r '.title')
  ISSUE_BODY=$(echo "$ISSUE_JSON" | jq -r '.body // "(empty)"')
  ISSUE_COMMENTS=$(echo "$ISSUE_JSON" | jq -r '.comments[] | "[\(.author.login)] \(.body)"' 2>/dev/null || echo "(no comments)")

  # 2. Idempotency guard: skip if last comment is from the agent
  LAST_COMMENT=$(echo "$ISSUE_JSON" | jq -r '(.comments | last | .body) // ""')
  if echo "$LAST_COMMENT" | grep -qE '^(Implementation plan|/clarification-needed)'; then
    echo "  → Skipping: already triaged (last comment is agent's)"
    continue
  fi

  # 3. Fetch any URLs in the issue body
  URLS=$(echo "$ISSUE_BODY" | grep -oE 'https?://[^ )<>]+' || true)
  URL_CONTENT=""
  if [ -n "$URLS" ]; then
    for url in $URLS; do
      echo "  Fetching URL: ${url}"
      FETCHED=$(curl -fsSL "$url" 2>/dev/null | head -300 || echo "(fetch failed)")
      URL_CONTENT="${URL_CONTENT}

--- Content from ${url} ---
${FETCHED}"
    done
  fi

  # 4. Build context for the LLM
  SYSTEM_PROMPT="You are a triage agent for the repository ${REPO}. Your job is to evaluate GitHub issues and decide if they are ready for implementation or need clarification.

You MUST respond with EXACTLY one JSON object (no markdown fencing, no explanation outside the JSON). The JSON schema:

If the issue IS ready for implementation:
{
  \"decision\": \"ready\",
  \"plan\": \"A detailed implementation plan including: specific files to change, the approach, how to test, and acceptance criteria.\"
}

If the issue needs clarification:
{
  \"decision\": \"needs-info\",
  \"question\": \"A specific, concrete clarifying question (not generic).\"
}

Decision criteria:
- 'ready': The issue has a specific goal, the approach is clear, and you can identify which files need changes.
- 'needs-info': Requirements are vague, missing context, or the scope is unclear.

Be concise but thorough in your implementation plans. Reference specific files from the repo tree."

  USER_PROMPT="## Issue #${ISSUE_NUMBER}: ${ISSUE_TITLE}

### Issue Body
${ISSUE_BODY}

### Comments
${ISSUE_COMMENTS}

### Repository README (excerpt)
${REPO_README}

### Repository File Tree
${REPO_TREE}
${URL_CONTENT}

Based on the above, produce your triage decision as JSON."

  # 5. Call the LLM
  echo "  Calling LLM for triage decision..."
  LLM_RESPONSE=$(llm_chat "$SYSTEM_PROMPT" "$USER_PROMPT" | strip_thinking)
  echo "  LLM response received (${#LLM_RESPONSE} chars)"

  # 6. Parse the decision
  DECISION=$(echo "$LLM_RESPONSE" | jq -r '.decision // empty' 2>/dev/null)

  if [ -z "$DECISION" ]; then
    # Try to extract JSON from markdown code fences if model wrapped it
    LLM_RESPONSE=$(echo "$LLM_RESPONSE" | sed -n '/^```/,/^```/p' | sed '1d;$d')
    DECISION=$(echo "$LLM_RESPONSE" | jq -r '.decision // empty' 2>/dev/null)
  fi

  if [ -z "$DECISION" ]; then
    echo "  ⚠ Could not parse LLM response, skipping issue #${ISSUE_NUMBER}"
    echo "  Raw response: ${LLM_RESPONSE:0:500}"
    continue
  fi

  # 7. Execute the decision
  case "$DECISION" in
    ready)
      PLAN=$(echo "$LLM_RESPONSE" | jq -r '.plan')
      echo "  → Decision: READY for development"

      # Remove needs-triage first (idempotency)
      gh issue edit "${ISSUE_NUMBER}" --repo "${REPO}" --remove-label "needs-triage" || true

      # Post implementation plan
      gh issue comment "${ISSUE_NUMBER}" --repo "${REPO}" \
        --body "Implementation plan:

${PLAN}"

      # Add ready-for-development label
      gh issue edit "${ISSUE_NUMBER}" --repo "${REPO}" --add-label "ready-for-development"
      echo "  ✓ Issue #${ISSUE_NUMBER} marked ready-for-development"
      ;;

    needs-info)
      QUESTION=$(echo "$LLM_RESPONSE" | jq -r '.question')
      echo "  → Decision: NEEDS INFO"

      # Remove needs-triage first
      gh issue edit "${ISSUE_NUMBER}" --repo "${REPO}" --remove-label "needs-triage" || true

      # Post clarification question
      gh issue comment "${ISSUE_NUMBER}" --repo "${REPO}" \
        --body "/clarification-needed: ${QUESTION}"

      # Add needs-info label
      gh issue edit "${ISSUE_NUMBER}" --repo "${REPO}" --add-label "needs-info"
      echo "  ✓ Issue #${ISSUE_NUMBER} marked needs-info"
      ;;

    *)
      echo "  ⚠ Unknown decision '${DECISION}', skipping"
      ;;
  esac

  echo "  Done with issue #${ISSUE_NUMBER}"
done

echo ""
echo "Triage run complete."

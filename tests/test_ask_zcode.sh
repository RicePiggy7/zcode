#!/usr/bin/env bash
# Regression tests for scripts/ask_zcode.sh against a scripted mock app-server.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$SCRIPT_DIR/../scripts/ask_zcode.sh"
MOCK="$SCRIPT_DIR/mock_app_server.py"

# Isolate from the user's real ~/.config/zcode-skill/env; env-file-specific
# cases override this inline with their own work-local file.
TEST_EMPTY_ENV="$(mktemp)"
: > "$TEST_EMPTY_ENV"
export ZCODE_SKILL_ENV_FILE="$TEST_EMPTY_ENV"

pass=0
fail=0

one_test() {
  local name="$1" expect_exit="$2"; shift 2
  local work assertion_file stdout_log exit_code
  work="$(mktemp -d)"
  assertion_file="$work/assertions.txt"
  stdout_log="$work/stdout.log"

  local -a env_vars=(
    "ZCODE_BIN=$work/bin/zcode"
    "ZCODE_SKILL_STATE_HOME=$work/state"
    "ZCODE_SKILL_CREDENTIALS=$work/credentials.json"
    "ZCODE_SKILL_TIMEOUT=30"
    "MOCK_ASSERT_FILE=$assertion_file"
  )
  # Extra env pairs passed as KEY=VALUE arguments.
  local extra_env=("$@")

  mkdir -p "$work/bin"
  {
    echo "#!/usr/bin/env bash"
    echo "exec python3 \"$MOCK\""
  } > "$work/bin/zcode"
  chmod +x "$work/bin/zcode"

  cat > "$work/credentials.json" <<'EOF'
{"account-provider:coding-plan:account:test-plan-individual-coding-plan:account:42:api-key":"mock-key"}
EOF

  for kv in "${env_vars[@]}"; do export "$kv"; done
  for kv in ${extra_env[@]+"${extra_env[@]}"}; do export "$kv"; done

  ( cd "$work" && bash "$WRAPPER" "run the mock task" > "$stdout_log" 2> "$work/stderr.log" )
  exit_code=$?

  for kv in ${extra_env[@]+"${extra_env[@]}"}; do unset "${kv%%=*}"; done

  if [[ "$exit_code" -eq "$expect_exit" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL [$name]: expected exit $expect_exit, got $exit_code"
    echo "--- stdout ---"; cat "$stdout_log"
    echo "--- stderr ---"; cat "$work/stderr.log"
  fi

  if [[ -f "$assertion_file" ]]; then
    if grep -q "^FAIL:" "$assertion_file"; then
      fail=$((fail + 1))
      echo "FAIL [$name]: mock assertions failed"
      cat "$assertion_file"
    elif [[ "$(grep -c '^ok:' "$assertion_file" || true)" -eq 0 ]]; then
      fail=$((fail + 1))
      echo "FAIL [$name]: mock produced no assertions"
    else
      pass=$((pass + 1))
    fi
  fi

  if [[ -f "$work/result.md" || -d "$work/state" ]]; then
    local result_json
    result_json="$(find "$work/state" -name result.json | head -1)"
    if [[ -n "$result_json" ]]; then
      local status
      status="$(jq -r '.status' "$result_json")"
      if [[ "$status" == "completed" && "$expect_exit" -eq 0 ]] ||
         [[ "$status" == "failed" && "$expect_exit" -ne 0 ]]; then
        pass=$((pass + 1))
      else
        fail=$((fail + 1))
        echo "FAIL [$name]: result.json status '$status' inconsistent with exit $expect_exit"
      fi
    else
      fail=$((fail + 1))
      echo "FAIL [$name]: no result.json written"
    fi
  fi

  echo "$name#$exit_code#$assertion_file#$work" >> "${TEST_LOG:-/dev/null}"
  if [[ "${TEST_KEEP:-}" != "1" ]]; then
    rm -rf "$work"
  fi
}

# 1. Successful run: defaults, mock asserts prefs/headers handling, final answer.
one_test "success" 0

# 2. Turn failure surfaces the scripted error.
one_test "turn-failure" 1 MOCK_FAIL=turn

# 3. ZCODE_SKILL_MODEL pin (string setModel + separate thought level).
one_test "model-pin" 0 'ZCODE_SKILL_MODEL=account:test-plan-individual-coding-plan/GLM-X$high' 'MOCK_EXPECT_SET_MODEL=account:test-plan-individual-coding-plan/GLM-X' 'MOCK_EXPECT_THOUGHT=high'

# 4. Without a pin, the wrapper picks the first available model from session/read.
one_test "default-model" 0 'MOCK_EXPECT_SET_MODEL=account:test-plan-individual-coding-plan/GLM-Mock'

# 5. Mid-turn permission ask is auto-allowed.
one_test "permission-allow" 0 MOCK_ASK_PERMISSION=1

# 5b. Config-file pin applies to new sessions (model + thought level).
work="$(mktemp -d)"
mkdir -p "$work/bin"
{ echo "#!/usr/bin/env bash"; echo "exec python3 \"$MOCK\""; } > "$work/bin/zcode"
chmod +x "$work/bin/zcode"
cat > "$work/credentials.json" <<'EOF'
{"account-provider:coding-plan:account:test-plan-individual-coding-plan:account:42:api-key":"mock-key"}
EOF
cat > "$work/env" <<'EOF'
# habitual defaults
ZCODE_SKILL_MODEL = "account:test-plan-individual-coding-plan/GLM-Env$max"
EOF
(
  cd "$work" &&
  ZCODE_BIN="$work/bin/zcode" \
  ZCODE_SKILL_STATE_HOME="$work/state" \
  ZCODE_SKILL_CREDENTIALS="$work/credentials.json" \
  ZCODE_SKILL_ENV_FILE="$work/env" \
  ZCODE_SKILL_TIMEOUT=30 \
  MOCK_EXPECT_SET_MODEL='account:test-plan-individual-coding-plan/GLM-Env' \
  MOCK_EXPECT_THOUGHT=max \
  MOCK_ASSERT_FILE="$work/assertions.txt" \
  bash "$WRAPPER" "run the mock task" > "$work/stdout.log" 2> "$work/stderr.log"
) ; rc=$?
if [[ $rc -eq 0 ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL [config-file-pin]: rc=$rc"; cat "$work/stderr.log"
fi
if [[ -f "$work/assertions.txt" ]] && ! grep -q '^FAIL:' "$work/assertions.txt"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL [config-file-pin]: mock assertions"; cat "$work/assertions.txt" 2>/dev/null
fi
rm -rf "$work"

# 6. Resume keeps the given session id; a config-file pin must NOT hijack it.
work="$(mktemp -d)"
mkdir -p "$work/bin"
{ echo "#!/usr/bin/env bash"; echo "exec python3 \"$MOCK\""; } > "$work/bin/zcode"
chmod +x "$work/bin/zcode"
cat > "$work/credentials.json" <<'EOF'
{"account-provider:coding-plan:account:test-plan-individual-coding-plan:account:42:api-key":"mock-key"}
EOF
cat > "$work/env" <<'EOF'
ZCODE_SKILL_MODEL=account:test-plan-individual-coding-plan/GLM-Env$max
EOF
out="$work/stdout.log"
(
  cd "$work" &&
  ZCODE_BIN="$work/bin/zcode" \
  ZCODE_SKILL_STATE_HOME="$work/state" \
  ZCODE_SKILL_CREDENTIALS="$work/credentials.json" \
  ZCODE_SKILL_ENV_FILE="$work/env" \
  ZCODE_SKILL_TIMEOUT=30 \
  MOCK_SESSION_ID=sess_prev01 \
  MOCK_ASSERT_NO_SETMODEL=1 \
  MOCK_ASSERT_FILE="$work/assertions.txt" \
  bash "$WRAPPER" "continue the task" --session sess_prev01 > "$out" 2> "$work/stderr.log"
) ; rc=$?
if [[ $rc -eq 0 ]] && grep -q "session_id=sess_prev01" "$out"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL [resume]: rc=$rc stdout:"; cat "$out"; cat "$work/stderr.log"
fi
rm -rf "$work"

# 6b. An explicitly exported ZCODE_SKILL_MODEL overrides a resumed session's model.
work="$(mktemp -d)"
mkdir -p "$work/bin"
{ echo "#!/usr/bin/env bash"; echo "exec python3 \"$MOCK\""; } > "$work/bin/zcode"
chmod +x "$work/bin/zcode"
cat > "$work/credentials.json" <<'EOF'
{"account-provider:coding-plan:account:test-plan-individual-coding-plan:account:42:api-key":"mock-key"}
EOF
out="$work/stdout.log"
(
  cd "$work" &&
  ZCODE_BIN="$work/bin/zcode" \
  ZCODE_SKILL_STATE_HOME="$work/state" \
  ZCODE_SKILL_CREDENTIALS="$work/credentials.json" \
  ZCODE_SKILL_TIMEOUT=30 \
  ZCODE_SKILL_MODEL='account:test-plan-individual-coding-plan/GLM-Explicit$low' \
  MOCK_SESSION_ID=sess_prev01 \
  MOCK_EXPECT_SET_MODEL='account:test-plan-individual-coding-plan/GLM-Explicit' \
  MOCK_EXPECT_THOUGHT=low \
  MOCK_ASSERT_FILE="$work/assertions.txt" \
  bash "$WRAPPER" "continue the task" --session sess_prev01 > "$out" 2> "$work/stderr.log"
) ; rc=$?
if [[ $rc -eq 0 ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL [resume-explicit-pin]: rc=$rc stdout:"; cat "$out"; cat "$work/stderr.log"
fi
if grep -q '^FAIL:' "$work/assertions.txt" 2>/dev/null; then
  fail=$((fail + 1)); echo "FAIL [resume-explicit-pin]: mock assertions"; cat "$work/assertions.txt"
else
  pass=$((pass + 1))
fi
rm -rf "$work"

# 7. --read-only is rejected together with --session.
bash "$WRAPPER" "task" --session sess_x --read-only >/dev/null 2>&1
if [[ $? -ne 0 ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL [resume-readonly-conflict]: expected non-zero exit"
fi

echo
echo "passed: $pass  failed: $fail"
[[ $fail -eq 0 ]]

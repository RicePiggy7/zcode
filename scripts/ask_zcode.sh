#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage:
  ask_zcode.sh <task> [options]
  ask_zcode.sh -t <task> [options]

Task input:
  <task>                       First positional argument is the task text
  -t, --task <text>            Alias for positional task
  (stdin)                      Pipe task text via stdin if no arg/flag given

File context (optional, repeatable):
  -f, --file <path>            Priority file path (listed in the prompt)
  -i, --image <path>           Image attached natively to ZCode

Multi-turn:
      --session <id>           Resume a previous session (sess_... from prior run)

Options:
  -w, --workspace <path>       Workspace directory (default: current directory)
      --read-only              Read-only session (plan mode; no file changes)
      --mode <mode>            Explicit mode override: build|edit|plan|yolo|guarded
      --notify                 Desktop notification when a long run finishes (opt-in)
  -o, --output <path>          Output file path
  -h, --help                   Show this help

Environment:
  ZCODE_BIN                    zcode CLI binary (default: zcode)
  ZCODE_SKILL_MODEL            Model pin as providerId/modelId or providerId/modelId$level.
                               Only used when the session has no default model.
  ZCODE_SKILL_TIMEOUT          Overall turn timeout in seconds (default: 1800)
  ZCODE_SKILL_CREDENTIALS      Path to the shared credentials.json
                               (default: ~/.zcode/v2/credentials.json)
  ZCODE_SKILL_ENV_FILE         Persistent defaults file (KEY=VALUE lines);
                               default: ~/.config/zcode-skill/env. The calling
                               environment takes precedence over this file.

Output (on success):
  session_id=<sess_...>        Use with --session for follow-up calls
  runtime=app-server           Talks to `zcode app-server --stdio`
  output_path=<file>           Path to response markdown
  result_path=<file>           Structured run status and metadata
  events_path=<file>           Session events (JSONL) for diagnostics

Examples:
  # New task (positional)
  ask_zcode.sh "Add error handling to api.ts" -f src/api.ts

  # With explicit workspace
  ask_zcode.sh "Fix the bug" -w /other/repo

  # Continue conversation
  ask_zcode.sh "Also add retry logic" --session sess_abc123

  # Read-only exploration
  ask_zcode.sh "Trace the request path with file:line evidence" --read-only
USAGE
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[ERROR] Missing required command: $1" >&2
    exit 1
  fi
}

load_env_file() {
  # Persistent defaults: KEY=VALUE lines from the skill env file. The calling
  # environment always wins — a key is only taken from the file when it is not
  # already set. File-sourced model pins are recorded so resume runs can keep
  # the session's own model instead of being hijacked by the stored default.
  local file="$1" key value
  [[ -f "$file" ]] || return 0
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    key="${raw%%=*}"
    [[ "$key" == "$raw" ]] && continue
    key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [[ -z "$key" || "$key" == \#* ]] && continue
    value="${raw#*=}"
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    [[ -z "$key" ]] && continue
    if [[ -z "${!key:-}" ]]; then
      export "$key=$value"
      [[ "$key" == "ZCODE_SKILL_MODEL" ]] && ZCODE_SKILL_MODEL_FROM_FILE=1
    fi
  done < "$file"
}

trim_whitespace() {
  awk 'BEGIN { RS=""; ORS="" } { gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, ""); print }' <<<"$1"
}

to_abs_if_exists() {
  local target="$1"
  if [[ -e "$target" ]]; then
    local dir
    dir="$(cd "$(dirname "$target")" && pwd)"
    echo "$dir/$(basename "$target")"
    return
  fi
  echo "$target"
}

resolve_file_ref() {
  local workspace="$1" raw="$2" cleaned
  cleaned="$(trim_whitespace "$raw")"
  [[ -z "$cleaned" ]] && { echo ""; return; }
  if [[ "$cleaned" =~ ^(.+)#L[0-9]+$ ]]; then cleaned="${BASH_REMATCH[1]}"; fi
  if [[ "$cleaned" =~ ^(.+):[0-9]+(-[0-9]+)?$ ]]; then cleaned="${BASH_REMATCH[1]}"; fi
  if [[ "$cleaned" != /* ]]; then cleaned="$workspace/$cleaned"; fi
  to_abs_if_exists "$cleaned"
}

append_file_refs() {
  local raw="$1" item
  IFS=',' read -r -a items <<< "$raw" || true
  for item in ${items[@]+"${items[@]}"}; do
    local trimmed
    trimmed="$(trim_whitespace "$item")"
    [[ -n "$trimmed" ]] && file_refs+=("$trimmed")
  done
}

mime_for_image() {
  case "${1##*.}" in
    png) echo "image/png" ;;
    jpg|jpeg) echo "image/jpeg" ;;
    gif) echo "image/gif" ;;
    webp) echo "image/webp" ;;
    *) echo "" ;;
  esac
}

# --- Load persistent defaults, then parse arguments ---

ZCODE_SKILL_MODEL_FROM_FILE=0
load_env_file "${ZCODE_SKILL_ENV_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/zcode-skill/env}"

workspace="${PWD}"
task_text=""
read_only=false
mode_override=""
notify=false
output_path=""
session_id=""
was_resume=0
file_refs=()
image_refs=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -w|--workspace)   workspace="${2:-}"; shift 2 ;;
    -t|--task)        task_text="${2:-}"; shift 2 ;;
    -f|--file|--focus) append_file_refs "${2:-}"; shift 2 ;;
    -i|--image)       image_refs+=("${2:-}"); shift 2 ;;
    --read-only)      read_only=true; shift ;;
    --mode)           mode_override="${2:-}"; shift 2 ;;
    --notify)         notify=true; shift ;;
    --session)        session_id="${2:-}"; shift 2 ;;
    -o|--output)      output_path="${2:-}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    -*)               echo "[ERROR] Unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)                if [[ -z "$task_text" ]]; then task_text="$1"; shift; else echo "[ERROR] Unexpected argument: $1" >&2; usage >&2; exit 1; fi ;;
  esac
done

zcode_bin="${ZCODE_BIN:-zcode}"
require_cmd "$zcode_bin" || [[ -x "$zcode_bin" ]]
require_cmd jq

# --- Validate inputs ---

if [[ ! -d "$workspace" ]]; then
  echo "[ERROR] Workspace does not exist: $workspace" >&2; exit 1
fi
workspace="$(cd "$workspace" && pwd)"

if [[ -z "$task_text" && ! -t 0 ]]; then
  task_text="$(cat)"
fi
task_text="$(trim_whitespace "$task_text")"

if [[ -z "$task_text" ]]; then
  echo "[ERROR] Request text is empty. Pass a positional arg, --task, or stdin." >&2; exit 1
fi

if [[ -n "$mode_override" ]]; then
  case "$mode_override" in
    build|edit|plan|yolo|guarded) ;;
    *) echo "[ERROR] Unsupported mode: $mode_override" >&2; exit 1 ;;
  esac
fi

if [[ -n "$session_id" && "$read_only" == true ]]; then
  echo "[ERROR] Resume keeps the original session mode. Start a new session with --read-only instead." >&2
  exit 1
fi

mode="yolo"
if [[ "$read_only" == true ]]; then
  mode="plan"
elif [[ -n "$mode_override" ]]; then
  mode="$mode_override"
fi

# --- Build file context block ---

file_block=""
if (( ${#file_refs[@]} > 0 )); then
  file_block=$'\nPriority files (read these first before making changes):'
  for ref in "${file_refs[@]}"; do
    resolved="$(resolve_file_ref "$workspace" "$ref")"
    [[ -z "$resolved" ]] && continue
    exists_tag="missing"
    [[ -e "$resolved" ]] && exists_tag="exists"
    file_block+=$'\n- '"${resolved} (${exists_tag})"
  done
fi

prompt="$task_text"
if [[ -n "$file_block" ]]; then
  prompt+=$'\n'"$file_block"
fi

# --- Validate images ---

declare -a attachment_json=()
if (( ${#image_refs[@]} > 0 )); then
  for image_ref in "${image_refs[@]}"; do
    resolved_image="$(resolve_file_ref "$workspace" "$image_ref")"
    [[ -f "$resolved_image" ]] || { echo "[ERROR] Image not found: $resolved_image" >&2; exit 1; }
    mime="$(mime_for_image "$resolved_image")"
    [[ -n "$mime" ]] || { echo "[ERROR] Unsupported image type (png/jpg/gif/webp only): $resolved_image" >&2; exit 1; }
    b64="$(base64 < "$resolved_image" | tr -d '\n')"
    attachment_json+=("$(jq -nc --arg kind image --arg fn "$(basename "$resolved_image")" \
      --arg mime "$mime" --arg b64 "$b64" \
      '{kind:$kind, filename:$fn, mimeType:$mime, dataBase64:$b64}')")
  done
fi

# --- Prepare unique run artifacts ---

timestamp="$(date -u +"%Y%m%d-%H%M%S")"
state_root="${ZCODE_SKILL_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/zcode-skill}"
mkdir -p "$state_root"
run_dir="$(mktemp -d "$state_root/run-${timestamp}-XXXXXX")"
result_path="$run_dir/result.json"
events_path="$run_dir/events.jsonl"
protocol_path="$run_dir/protocol.log"
stderr_path="$run_dir/stderr.log"
if [[ -z "$output_path" ]]; then
  output_path="$run_dir/result.md"
fi
mkdir -p "$(dirname "$output_path")"
: > "$events_path"
: > "$protocol_path"
: > "$stderr_path"

started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
start_ts=$SECONDS
server_pid=""
responder_pid=""
LAST_RPC_ERROR=""

cleanup() {
  if [[ -n "$responder_pid" ]]; then
    pkill -P "$responder_pid" 2>/dev/null || true
    kill "$responder_pid" 2>/dev/null || true
    wait "$responder_pid" 2>/dev/null || true
  fi
  if [[ -n "$server_pid" ]]; then
    if kill -0 "$server_pid" 2>/dev/null; then
      kill "$server_pid" 2>/dev/null || true
      local i=0
      while (( i < 30 )) && kill -0 "$server_pid" 2>/dev/null; do
        sleep 0.1
        i=$((i + 1))
      done
      kill -9 "$server_pid" 2>/dev/null || true
    fi
  fi
  exec 3>&- 2>/dev/null || true
}
trap cleanup EXIT

fail_run() {
  local exit_code="$1" error_message="$2" summary_text="${3:-}"
  write_result "failed" "$exit_code" "$error_message" "$summary_text"
  echo "[ERROR] $error_message" >&2
  if [[ -s "$stderr_path" ]]; then
    tail -n 5 "$stderr_path" >&2
  fi
  echo "status=failed"
  echo "runtime=app-server"
  [[ -n "$session_id" ]] && echo "session_id=$session_id"
  echo "result_path=$result_path"
  echo "events_path=$events_path"
  echo "protocol_path=$protocol_path"
  exit "$exit_code"
}

write_result() {
  local status="$1" exit_code="$2" error_message="$3" summary_text="${4:-}"
  local finished_at stderr_tail result_tmp
  finished_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  stderr_tail=""
  if [[ "$status" != "completed" && -s "$stderr_path" ]]; then
    stderr_tail="$(tail -n 20 "$stderr_path" 2>/dev/null || true)"
  fi
  local elapsed_now=$(( SECONDS - start_ts ))
  result_tmp="$result_path.tmp.$$"
  jq -n \
    --arg status "$status" \
    --argjson exit_code "$exit_code" \
    --arg runtime "app-server" \
    --arg run_id "$(basename "$run_dir")" \
    --arg workspace "$workspace" \
    --arg session_id "${session_id:-}" \
    --arg final_message "$summary_text" \
    --arg output_path "$output_path" \
    --arg events_path "$events_path" \
    --arg protocol_path "$protocol_path" \
    --arg stderr_path "$stderr_path" \
    --argjson elapsed "$elapsed_now" \
    --arg started_at "$started_at" \
    --arg finished_at "$finished_at" \
    --arg stderr_tail "$stderr_tail" \
    --arg error "$error_message" \
    '{
      schema: "zcode-skill.run.v1",
      status: $status,
      exit_code: $exit_code,
      runtime: $runtime,
      run_id: $run_id,
      workspace: $workspace,
      session_id: (if $session_id == "" then null else $session_id end),
      final_message: $final_message,
      output_path: $output_path,
      events_path: $events_path,
      protocol_path: $protocol_path,
      stderr_path: $stderr_path,
      elapsed_seconds: $elapsed,
      started_at: $started_at,
      finished_at: $finished_at,
      stderr_tail: (if $stderr_tail == "" then null else $stderr_tail end),
      error: (if $error == "" then null else $error end)
    }' > "$result_tmp"
  mv "$result_tmp" "$result_path"
}

# --- Start the app-server and the frame responder ---

fifo_path="$run_dir/server.in"
mkfifo "$fifo_path"

"$zcode_bin" app-server --stdio < "$fifo_path" > "$protocol_path" 2> "$stderr_path" &
server_pid=$!

# Opening the write end blocks until the server opens its stdin; guard with a
# watchdog so a broken CLI cannot hang the wrapper forever.
( sleep 20; kill "$$" 2>/dev/null ) & watchdog_pid=$!
exec 3>"$fifo_path"
kill "$watchdog_pid" 2>/dev/null || true
wait "$watchdog_pid" 2>/dev/null || true
watchdog_pid=""

credentials_file="${ZCODE_SKILL_CREDENTIALS:-$HOME/.zcode/v2/credentials.json}"

reply_json() {
  # reply_json <id> <result-json>; the server sends both numeric and string ids.
  if [[ "$1" =~ ^[0-9]+$ ]]; then
    jq -nc --argjson id "$1" --argjson result "$2" '{id:$id, result:$result}' >&3
  else
    jq -nc --arg id "$1" --argjson result "$2" '{id:$id, result:$result}' >&3
  fi
}

decrypt_credential() {
  # Decrypt one `enc:v1:<iv>.<authTag>.<ciphertext>` store value (AES-256-GCM,
  # key = sha256 of ZCODE_CREDENTIAL_SECRET or ZCode's machine-bound fallback).
  # Plaintext values pass through. Node is required by the zcode CLI itself.
  local value="$1"
  if [[ "$value" != enc:v1:* ]]; then
    printf '%s' "$value"
    return 0
  fi
  if ! command -v node >/dev/null 2>&1; then
    echo "[ERROR] credential store value is encrypted but node is unavailable" >&2
    return 1
  fi
  node -e '
    const crypto = require("crypto"), os = require("os");
    let secret = (process.env.ZCODE_CREDENTIAL_SECRET || "").trim();
    if (!secret) {
      let username = "unknown";
      try { username = os.userInfo().username; } catch {}
      secret = `zcode-credential-fallback:${process.platform}:${os.homedir()}:${username}`;
    }
    const [iv, tag, data] = process.argv[1].split(".");
    const key = crypto.createHash("sha256").update(secret).digest();
    const decipher = crypto.createDecipheriv("aes-256-gcm", key, Buffer.from(iv, "base64url"));
    decipher.setAuthTag(Buffer.from(tag, "base64url"));
    process.stdout.write(Buffer.concat([
      decipher.update(Buffer.from(data, "base64url")),
      decipher.final(),
    ]).toString("utf8"));
  ' "${value#enc:v1:}"
}

answer_provider_runtime_headers() {
  local frame="$1" line
  local provider_id
  provider_id="$(jq -r '.params.modelSelection.providerId // .params.providerId // empty' <<<"$frame")"
  if [[ -n "$provider_id" && -f "$credentials_file" ]]; then
    line="$(jq -r --arg prefix "account-provider:coding-plan:account:${provider_id#account:}:account:" \
      'to_entries[]
         | select((.key | startswith($prefix)) and (.key | endswith(":api-key")))
         | .value' "$credentials_file" 2>/dev/null | head -1)"
    if [[ -n "$line" ]]; then
      if line="$(decrypt_credential "$line")"; then
        reply_json "$2" "$(jq -nc --arg key "$line" '{headersApplied:true, requestAuth:{apiKey:$key}}')"
        return
      fi
    fi
  fi
  reply_json "$2" '{"headersApplied":false, "errorMessage":"ask_zcode: no coding-plan api key found for this provider in the shared credential store"}'
}

print_progress() {
  local frame="$1" etype payload_kind tool_name
  etype="$(jq -r '.params.type // empty' <<<"$frame")"
  case "$etype" in
    turn.started)
      echo "[zcode] turn started" >&2
      ;;
    tool.updated)
      payload_kind="$(jq -r '.params.payload.kind // empty' <<<"$frame")"
      if [[ "$payload_kind" == "started" ]]; then
        tool_name="$(jq -r '.params.payload.toolName // empty' <<<"$frame")"
        echo "[zcode] tool: ${tool_name:-unknown}" >&2
      fi
      ;;
    turn.failed)
      echo "[zcode] turn failed: $(jq -r '.params.payload.error.message // .params.payload.message // "unknown error"' <<<"$frame")" >&2
      ;;
  esac
}

# The responder is the only reader of the protocol log: it auto-answers
# server->client requests and files responses by id for the sequential main
# loop. Every session/event notification is appended to events.jsonl.
responder_done="$run_dir/.responder_done"
(
  # Never let a malformed frame or a failed reply kill the responder loop.
  set +e +u
  tail -n +1 -F "$protocol_path" 2>/dev/null | while IFS= read -r frame; do
    [[ "$frame" == \{* ]] || continue
    jq -e . >/dev/null 2>&1 <<<"$frame" || continue
    method="$(jq -r '.method // empty' <<<"$frame")"
    id="$(jq -r '.id // empty' <<<"$frame")"
    if [[ -n "$method" && -n "$id" && "$id" != "null" ]]; then
      case "$method" in
        session/requestRuntimePreferences)
          reply_json "$id" '{"nativeSearchEnhancementsEnabled":false, "memoryEnabled":false, "askUserQuestionAutoResolutionEnabled":false}'
          ;;
        interaction/requestProviderRuntimeHeaders)
          answer_provider_runtime_headers "$frame" "$id"
          ;;
        interaction/requestPermission)
          reply_json "$id" '{"decision":"allow", "reason":"auto-allowed by ask_zcode wrapper"}'
          ;;
        interaction/requestUserInput|elicitation/create)
          reply_json "$id" '{"action":"decline", "reason":"headless delegation cannot answer interactive questions; include all necessary context in the task prompt"}'
          ;;
        *)
          reply_json "$id" '{"action":"decline", "reason":"ask_zcode wrapper does not support this request"}'
          ;;
      esac
      continue
    fi
    if [[ "$method" == "session/event" ]]; then
      printf '%s\n' "$frame" >> "$events_path"
      print_progress "$frame"
      continue
    fi
    if [[ -n "$id" && "$id" != "null" ]]; then
      printf '%s\n' "$frame" > "$run_dir/resp-$id.json"
    fi
  done
  echo done > "$responder_done"
) &
responder_pid=$!

# --- Sequential RPC over the protocol ---

RPC_ID=0
RPC_RESP=""
# rpc <method> <params-json> [timeout-seconds]
# Sets RPC_RESP to the response JSON on success; sets LAST_RPC_ERROR and
# returns non-zero on failure. Runs in the main shell (no command
# substitution) so error state survives for the caller.
rpc() {
  RPC_RESP=""
  local method="$1" params="$2" timeout_s="${3:-60}"
  RPC_ID=$((RPC_ID + 1))
  local rid="$RPC_ID"
  local resp_file="$run_dir/resp-$rid.json"
  rm -f "$resp_file"
  local frame
  frame="$(jq -nc --argjson id "$rid" --arg m "$method" --argjson p "$params" '{id:$id, method:$m, params:$p}')" || {
    LAST_RPC_ERROR="failed to encode request frame for $method"
    return 1
  }
  printf '%s\n' "$frame" >&3
  local deadline=$(( SECONDS + timeout_s ))
  while [[ ! -s "$resp_file" ]]; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      LAST_RPC_ERROR="app-server exited before replying to $method"
      return 125
    fi
    if (( SECONDS >= deadline )); then
      LAST_RPC_ERROR="timed out waiting for $method"
      return 124
    fi
    sleep 0.1
  done
  RPC_RESP="$(cat "$resp_file")"
  if jq -e 'has("error")' >/dev/null 2>&1 <<<"$RPC_RESP"; then
    LAST_RPC_ERROR="$(jq -r '.error.message // "unknown error"' <<<"$RPC_RESP")"
    return 1
  fi
}

# --- Make local account providers visible to the app-server ---
# The standalone app-server boots with an empty model registry: entitlement
# states are normally pushed by the desktop host via provider/updateAccountConfig.
# Build the same snapshot from local evidence (bundled provider table + coding
# plan cache + shared credentials) and push it before any session work.
coding_plan_cache="${ZCODE_SKILL_CODING_PLAN_CACHE:-$HOME/.zcode/v2/coding-plan-cache.json}"
builtin_table="${ZCODE_BUILTIN_PROVIDER_CONFIG_FILE:-/Applications/ZCode.app/Contents/Resources/config/provider/zcode-builtin.json}"
table_src="$run_dir/builtin.json"
cache_src="$run_dir/cache.json"
creds_src="$run_dir/creds.json"
if [[ -f "$builtin_table" ]]; then cp "$builtin_table" "$table_src"; else echo '{}' > "$table_src"; fi
if [[ -f "$coding_plan_cache" ]]; then cp "$coding_plan_cache" "$cache_src"; else echo '{}' > "$cache_src"; fi
if [[ -f "$credentials_file" ]]; then cp "$credentials_file" "$creds_src"; else echo '{}' > "$creds_src"; fi

if jq -e '.config.providerConfigRules.providerRules | type == "array"' >/dev/null 2>&1 "$table_src" &&
   jq -e 'length > 0' >/dev/null 2>&1 "$creds_src"; then
  table_revision="$(jq -r '.revision // 0' "$table_src")"
  # The backend compares this against a hash of ITS bundled table path, so the
  # original path is hashed — hashing our run-dir copy gets the push silently
  # discarded even though the RPC acks "received".
  case "$(uname -s)" in
    Darwin) path_hash="$(printf '%s' "$builtin_table" | shasum -a 256 | awk '{print $1}')" ;;
    *)      path_hash="$(printf '%s' "$builtin_table" | sha256sum | awk '{print $1}')" ;;
  esac
  builtin_revision="zcode-builtin:${table_revision}:${path_hash}"
  push_json="$(jq -nc --arg rev "$builtin_revision" \
    --slurpfile t "$table_src" --slurpfile c "$cache_src" --slurpfile k "$creds_src" '
    def cachekey(family; mode):
      "builtin:" + family + "-" + ({
        "individual-coding-plan": "coding-plan",
        "team-coding-plan": "coding-plan",
        "start-plan": "start-plan",
        "off-peak": "offpeak-idle-plan",
        "highspeed": "highspeed-card"
      }[mode]);
    def hasstoredkey(slug):
      ($k[0] | [to_entries[]
        | select((.key | startswith("account-provider:coding-plan:account:" + slug + ":account:"))
                 and (.key | endswith(":api-key")))] | length) > 0;
    def entitled(family; mode; slug):
      (($c[0].entryStatus.items[cachekey(family; mode)].status // "unavailable") == "available")
      or hasstoredkey(slug);
    [$t[0].config.providerConfigRules.providerRules[]
      | select(.config.access.type == "zhipu-account")] as $rules
    | (reduce $rules[] as $r ({};
        ($r.providerId | ltrimstr("account:")) as $slug
        | ($r.config.access.accountType) as $family
        | ($r.config.access.mode) as $mode
        | entitled($family; $mode; $slug) as $ent
        | .[$r.providerId] = {builtinModelIds: ($r.config.builtinModelIds // []),
                              access: {type: "zhipu-account", entitled: $ent}}
      )) as $providers
    | (reduce $rules[] as $r ({};
        ($r.providerId | ltrimstr("account:")) as $slug
        | ($r.config.access.accountType) as $family
        | ($r.config.access.mode) as $mode
        | entitled($family; $mode; $slug) as $ent
        | .[$r.providerId] = {availability: (if $ent then "available" else "unavailable" end),
                              entitled: $ent, current: $ent}
      )) as $states
    | {revision: $rev, basedOnZCodeBuiltinRevision: $rev,
       providers: $providers, states: $states}
  ' 2>/dev/null)"
  if [[ -n "$push_json" ]] && rpc provider/updateAccountConfig "$push_json" 20; then
    echo "[zcode] account providers synced" >&2
  else
    echo "[zcode] warn: could not sync account providers; the session may have no model" >&2
  fi
fi

# --- Create or resume the session ---

if [[ -n "$session_id" ]]; then
  if ! rpc session/resume "$(jq -nc --arg sid "$session_id" \
      --arg path "$workspace" \
      '{sessionId:$sid, workspace:{workspacePath:$path, workspaceKey:$path}}')" 60; then
    fail_run 1 "session resume failed: $LAST_RPC_ERROR"
  fi
  was_resume=1
  echo "[zcode] resumed session $session_id" >&2
else
  if ! rpc session/create "$(jq -nc --arg path "$workspace" --arg mode "$mode" \
      '{workspace:{workspacePath:$path, workspaceKey:$path}, mode:$mode}')" 60; then
    fail_run 1 "session create failed: $LAST_RPC_ERROR"
  fi
  session_id="$(jq -r '.result.session.sessionId // empty' <<<"$RPC_RESP")"
  if [[ -z "$session_id" ]]; then
    fail_run 1 "session create returned no sessionId: $RPC_RESP"
  fi
  echo "[zcode] session $session_id (mode=$mode)" >&2
fi

# --- Model selection ---
# After the account snapshot push, session/read lists the available models.
# Default: pin the first available model on a new session (the desktop host
# would do this from its UI). ZCODE_SKILL_MODEL overrides the choice, with an
# optional $level suffix for the thought level. A resumed session keeps its
# own model unless ZCODE_SKILL_MODEL says otherwise.
pick_model() {
  # Poll briefly: the registry rebuilds asynchronously after the account push.
  local attempt=0
  while (( attempt < 6 )); do
    if rpc session/read "$(jq -nc --arg sid "$session_id" '{sessionId:$sid}')" 30; then
      local spec
      spec="$(jq -r '.result.settings.model.available[0]?
        | if type == "object" then ((.providerId // "") + "/" + (.modelId // ""))
          elif type == "string" then .
          else "" end' <<<"$RPC_RESP" 2>/dev/null)"
      if [[ -n "$spec" && "$spec" != "/" ]]; then
        printf '%s' "$spec"
        return 0
      fi
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

# Fall back to the first entitled provider/model pair from the bundled table.
pick_model_from_table() {
  jq -rn --slurpfile t "$table_src" --slurpfile c "$cache_src" --slurpfile k "$creds_src" '
    [$t[0].config.providerConfigRules.providerRules[]
      | select(.config.access.type == "zhipu-account")
      | select((.config.builtinModelIds // [] | length) > 0)] as $rules
    | ($c[0].entryStatus.items // {}) as $cache
    | ($k[0] | keys) as $credkeys
    | first(
        $rules[]
        | (.providerId | ltrimstr("account:")) as $slug
        | (.config.access.accountType) as $family
        | (.config.access.mode) as $mode
        | ("builtin:" + $family + "-" + ({"individual-coding-plan": "coding-plan",
            "team-coding-plan": "coding-plan", "start-plan": "start-plan",
            "off-peak": "offpeak-idle-plan", "highspeed": "highspeed-card"}[$mode])) as $ck
        | select((($cache[$ck].status // "unavailable") == "available")
                 or ($credkeys | map(select(startswith("account-provider:coding-plan:account:" + $slug
                     + ":account:") and endswith(":api-key"))) | length > 0))
        | .providerId + "/" + (.config.builtinModelIds[0])
      )
  ' 2>/dev/null
}

pin_model() {
  # pin_model <providerId/modelId> [thought-level]
  # GLM models declare reasoning levels; the registry rejects a level-less pin
  # with "Reasoning level is required". Retry down a candidate ladder, mirroring
  # the desktop host: the user level first, then the local provider config's
  # default/variants, then common levels.
  local spec="$1" user_level="${2:-}"
  local provider_id="${spec%%/*}" model_id="${spec#*/}"
  if [[ -z "$provider_id" || -z "$model_id" || "$provider_id" == "$spec" ]]; then
    LAST_RPC_ERROR="invalid model spec '$spec' (expected providerId/modelId)"
    return 1
  fi
  local attempt_model base error
  base="$(jq -nc --arg p "$provider_id" --arg m "$model_id" '{providerId:$p, modelId:$m}')"
  local -a candidates=("")
  [[ -n "$user_level" ]] && candidates+=("$user_level")
  local cfg="${ZCODE_SKILL_PROVIDER_CONFIG:-$HOME/.zcode/v2/config.json}"
  if [[ -f "$cfg" ]]; then
    while IFS= read -r cand; do
      [[ -n "$cand" ]] && candidates+=("$cand")
    done < <(jq -r --arg m "$model_id" '
      .provider["builtin:bigmodel"].models[$m].reasoning.defaultVariant,
      (.provider["builtin:bigmodel"].models[$m].reasoning.variants[]? // empty)' "$cfg" 2>/dev/null | uniq)
  fi
  candidates+=("high" "max" "low")
  for attempt_model in "${candidates[@]}"; do
    local params
    if [[ -n "$attempt_model" ]]; then
      params="$(jq -nc --arg sid "$session_id" --argjson m "$base" --arg l "$attempt_model" \
        '{sessionId:$sid, model:($m + {options:{reasoningLevel:$l}}), persistAsWorkspaceLastUsed:false}')"
    else
      params="$(jq -nc --arg sid "$session_id" --argjson m "$base" \
        '{sessionId:$sid, model:$m, persistAsWorkspaceLastUsed:false}')"
    fi
    if rpc session/setModel "$params" 30; then
      [[ -n "$attempt_model" ]] && echo "[zcode] reasoning level: $attempt_model" >&2
      return 0
    fi
    error="$LAST_RPC_ERROR"
    case "$error" in
      *"Reasoning level is required"*|*"Reasoning effort"*"not supported"*|*"Reasoning effort is not supported"*) : ;;
      *) return 1 ;;
    esac
  done
  LAST_RPC_ERROR="$error"
  return 1
}

if [[ -n "${ZCODE_SKILL_MODEL:-}" ]]; then
  model_spec="$ZCODE_SKILL_MODEL"
  level=""
  if [[ "$model_spec" == *'$'* ]]; then
    level="${model_spec#*\$}"
    model_spec="${model_spec%%\$*}"
  fi
  if [[ "$was_resume" == "1" && "$ZCODE_SKILL_MODEL_FROM_FILE" == "1" ]]; then
    # A stored default must not hijack a resumed session's own model; an
    # explicitly exported ZCODE_SKILL_MODEL still applies (see else-branch).
    echo "[zcode] resumed session keeps its own model (config-file pin ignored; export ZCODE_SKILL_MODEL to override)" >&2
  elif ! pin_model "$model_spec" "$level"; then
    fail_run 1 "model pin failed ($model_spec): $LAST_RPC_ERROR"
  else
    echo "[zcode] model pinned to $model_spec" >&2
  fi
elif [[ "$was_resume" == "1" ]]; then
  echo "[zcode] resumed session keeps its own model" >&2
else
  model_spec="$(pick_model || true)"
  if [[ -z "$model_spec" || "$model_spec" == "/" ]]; then
    model_spec="$(pick_model_from_table || true)"
    [[ -n "$model_spec" ]] && echo "[zcode] availability list empty; using model from provider table" >&2
  fi
  if [[ -z "$model_spec" || "$model_spec" == "/" ]]; then
    fail_run 1 "no model is available to this session. Set ZCODE_SKILL_MODEL=providerId/modelId[\$level] explicitly, or check that the shared credential store is readable."
  fi
  if ! pin_model "$model_spec"; then
    fail_run 1 "model pin failed ($model_spec): $LAST_RPC_ERROR"
  fi
  echo "[zcode] model: $model_spec" >&2
fi

# --- Subscribe to events, then send the task ---

if ! rpc session/subscribe "$(jq -nc --arg sid "$session_id" \
    '{sessionId:$sid, deliveryKind:"desktop-continuous", includeSnapshot:true, afterSeq:0}')" 60; then
  fail_run 1 "event subscribe failed: $LAST_RPC_ERROR"
fi

send_params="$(jq -nc --arg sid "$session_id" --arg content "$prompt" \
  '{sessionId:$sid, content:$content}')"
if (( ${#attachment_json[@]} > 0 )); then
  send_params="$(printf '%s' "$attachment_json" | jq -sc --argjson base "$send_params" \
    '$base * {attachments:$}')"
fi
if ! rpc session/send "$send_params" 60; then
  fail_run 1 "task send failed: $LAST_RPC_ERROR"
fi

# --- Wait for the turn to finish ---

turn_status=0
deadline=$(( SECONDS + ${ZCODE_SKILL_TIMEOUT:-1800} ))
while :; do
  if grep -q '"type": *"turn.failed"\|"type":"turn.failed"' "$events_path" 2>/dev/null; then
    turn_status=1
    break
  fi
  if grep -q '"type": *"turn.completed"\|"type":"turn.completed"' "$events_path" 2>/dev/null || \
     grep -q '"type": *"turn.terminal"\|"type":"turn.terminal"' "$events_path" 2>/dev/null; then
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    turn_status=125
    break
  fi
  (( SECONDS < deadline )) || { turn_status=124; break; }
  sleep 1
done

elapsed=$(( SECONDS - start_ts ))

if (( turn_status == 1 )); then
  failure_text="$(jq -rs 'map(select(.params.type == "turn.failed") | .params.payload.error.message // .params.payload.message) | (last // "turn failed")' "$events_path" 2>/dev/null || true)"
  [[ -z "$failure_text" || "$failure_text" == "null" ]] && failure_text="turn failed"
  rpc session/stop "$(jq -nc --arg sid "$session_id" '{sessionId:$sid}')" 10 >/dev/null 2>&1 || true
  fail_run 1 "ZCode turn failed: $failure_text"
fi

if (( turn_status == 125 )); then
  fail_run 125 "app-server exited unexpectedly (see stderr.log / protocol.log)"
fi

if (( turn_status == 124 )); then
  rpc session/stop "$(jq -nc --arg sid "$session_id" '{sessionId:$sid}')" 10 >/dev/null 2>&1 || true
  fail_run 124 "turn timed out after ${ZCODE_SKILL_TIMEOUT:-1800}s; the turn was asked to stop"
fi

# --- Collect the final answer ---

summary_text=""
rpc session/messages "$(jq -nc --arg sid "$session_id" '{sessionId:$sid}')" 60 || true
if [[ -n "${RPC_RESP:-}" ]]; then
  summary_text="$(jq -r '
    [ .result.messages[]?
      | select((.role // "") == "assistant")
      | if (.content | type) == "array"
        then [.content[] | select((.type // "") == "text") | .text] | join("\n")
        else (.content // .text // "")
        end
    ] | (last // "")' <<<"$RPC_RESP" 2>/dev/null || true)"
fi

# Fallback: the trailing text deltas streamed in events.
if [[ -z "$summary_text" || "$summary_text" == "null" ]]; then
  summary_text="$(jq -rs '
    map(select(.params.type == "model.streaming" and .params.payload.kind == "text_delta") | .params.payload.delta)
    | add // ""' "$events_path" 2>/dev/null || true)"
fi

# --- Compose the markdown result ---

details="$(
  jq -rs '
    [ .[] | select(.params.type == "tool.updated") | .params.payload ] as $ev
    | [ $ev[] | select(.kind == "result") ] as $results
    | $results[] as $r
    | ([ $ev[]
         | select(.kind == "scheduled" and .toolCallId == $r.toolCallId)
         | .toolName ] | first // "tool") as $name
    | "### Tool: " + $name + " (" + (($r.result.perf.totalMs? // 0) | tostring) + "ms)\n" +
      (if (($r.result.success? // true) | not) then "[failed] " else "" end) +
      ((($r.result.content? // "") | tostring)[0:400])
  ' "$events_path" 2>/dev/null || true
)"

cmd_count="$(jq -rs 'map(select(.params.type == "tool.updated" and .params.payload.kind == "started")) | length' "$events_path" 2>/dev/null || true)"
usage_footer="$(jq -rs '
  (map(select(.params.type == "turn.completed") | .params.payload.usage) | last) as $u
  | if $u == null then ""
    else "tokens in=\($u.inputTokens // 0) (cached \($u.cacheReadTokens // 0)) out=\($u.outputTokens // 0)"
    end' "$events_path" 2>/dev/null || true)"

{
  if [[ -n "$summary_text" && "$summary_text" != "null" ]]; then
    printf '## Summary\n\n%s\n\n' "$summary_text"
  fi
  if [[ -n "$details" ]]; then
    printf '## Details\n\n%s\n\n' "$details"
  fi
  printf -- '---\nelapsed %ss · %s tool calls' "$elapsed" "${cmd_count:-0}"
  [[ -n "$usage_footer" && "$usage_footer" != "null" ]] && printf -- ' · %s' "$usage_footer"
  printf '\n'
} > "$output_path"

if [[ ! -s "$output_path" ]]; then
  echo "(no response from zcode)" > "$output_path"
  summary_text=""
fi

write_result "completed" 0 "" "$summary_text"

# --- Desktop notification for long runs (opt-in via --notify or ZCODE_NOTIFY=1) ---

if [[ "${ZCODE_NOTIFY:-0}" == "1" || "$notify" == true ]] && (( elapsed >= 30 )); then
  title="ZCode done (${elapsed}s)"
  body="$(printf '%s' "${summary_text:-task complete}" | tr '\n' ' ' | cut -c1-120)"
  case "$(uname -s)" in
    Darwin)
      if command -v terminal-notifier >/dev/null 2>&1; then
        terminal-notifier -title "$title" -message "$body" >/dev/null 2>&1 || true
      else
        osascript -e "display notification \"${body//\"/\'}\" with title \"${title//\"/\'}\" sound name \"Glass\"" >/dev/null 2>&1 || true
      fi
      ;;
    Linux)
      command -v notify-send >/dev/null 2>&1 && notify-send "$title" "$body" >/dev/null 2>&1 || true
      ;;
  esac
fi

# --- Output results ---

echo "session_id=$session_id"
echo "runtime=app-server"
echo "output_path=$output_path"
echo "result_path=$result_path"
echo "events_path=$events_path"
echo "elapsed=${elapsed}s"

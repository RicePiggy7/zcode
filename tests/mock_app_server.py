#!/usr/bin/env python3
"""A scripted mock of the ZCode app-server for ask_zcode.sh tests.

Speaks the line-delimited JSON protocol (no `jsonrpc` field) on stdin/stdout.
Behavior is controlled by environment variables:

  MOCK_SESSION_ID        sessionId returned by session/create (default sess_mock0001)
  MOCK_NO_DEFAULT_MODEL  session/read reports no current model (forces a setModel pin)
  MOCK_EXPECT_SET_MODEL  expected pin as providerId/modelId$level (asserted)
  MOCK_FAIL=turn         the turn fails with a scripted error instead of completing
  MOCK_ASK_PERMISSION    ask interaction/requestPermission mid-turn (assert allow)
  MOCK_ASSERT_FILE       path to write assertion results ("ok" / failure lines)
"""

import json
import os
import signal
import sys
import time


def emit(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def notify(method, params):
    emit({"method": method, "params": params})


def reply(req_id, result):
    emit({"id": req_id, "result": result})


def reply_error(req_id, message, code=-32000):
    emit({"id": req_id, "error": {"message": message, "code": code}})


def event(sid, seq, etype, payload):
    notify("session/event", {"sessionId": sid, "seq": seq, "type": etype, "payload": payload})


def ask(req_id, method, params):
    notify_req = {"id": req_id, "method": method, "params": params}
    emit(notify_req)


def assert_true(store, cond, label):
    if cond:
        store.append("ok: " + label)
    else:
        store.append("FAIL: " + label)


def main():
    sid = os.environ.get("MOCK_SESSION_ID", "sess_mock0001")
    no_default_model = os.environ.get("MOCK_NO_DEFAULT_MODEL") == "1"
    expect_set_model = os.environ.get("MOCK_EXPECT_SET_MODEL", "")
    fail_turn = os.environ.get("MOCK_FAIL") == "turn"
    ask_permission = os.environ.get("MOCK_ASK_PERMISSION") == "1"
    api_key = os.environ.get("MOCK_API_KEY", "mock-key")
    assert_file = os.environ.get("MOCK_ASSERT_FILE", "")
    store = []
    ask_id = 1000
    seq = 0

    def flush_assertions(*_args):
        if assert_file:
            with open(assert_file, "w", encoding="utf-8") as f:
                f.write("\n".join(store) + "\n")
        sys.exit(0)

    # The wrapper kills this process on exit; flush assertions on the way down.
    signal.signal(signal.SIGTERM, flush_assertions)
    signal.signal(signal.SIGINT, flush_assertions)

    def next_ask_id():
        nonlocal ask_id
        ask_id += 1
        return ask_id

    def read_reply_for(want_id):
        """Read frames until a reply with the given id arrives; return its result."""
        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            try:
                frame = json.loads(raw)
            except ValueError:
                continue
            if frame.get("id") == want_id and "method" not in frame:
                return frame.get("result")
            # Client requests while we wait (e.g. session/stop) get a generic ack.
            if "method" in frame and "id" in frame:
                reply(frame["id"], {})
        return None

    def provider_headers_flow(provider_id):
        """Mirror the backend: ask for runtime headers on account providers."""
        if not (provider_id or "").startswith("account:"):
            return
        aid = next_ask_id()
        ask(aid, "interaction/requestProviderRuntimeHeaders",
            {"sessionId": sid, "modelSelection": {"providerId": provider_id}})
        result = read_reply_for(aid)
        if not isinstance(result, dict):
            store.append("FAIL: provider headers reply missing")
            return
        assert_true(store, result.get("headersApplied") is True, "headers applied true")
        auth = result.get("requestAuth") or {}
        assert_true(store, auth.get("apiKey") == api_key, "requestAuth api key matches")

    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            frame = json.loads(raw)
        except ValueError:
            continue

        # Client replies to our server->client asks.
        if "method" not in frame and "id" in frame:
            continue

        method = frame.get("method")
        rid = frame.get("id")
        params = frame.get("params") or {}

        if method == "session/create":
            aid = next_ask_id()
            ask(aid, "session/requestRuntimePreferences", {"sessionId": None})
            prefs = read_reply_for(aid)
            if not isinstance(prefs, dict):
                store.append("FAIL: runtime preferences reply missing")
            else:
                assert_true(store, prefs.get("memoryEnabled") is False, "memoryEnabled false")
                assert_true(
                    store,
                    prefs.get("askUserQuestionAutoResolutionEnabled") is False,
                    "askUserQuestionAutoResolutionEnabled false",
                )
            reply(rid, {"session": {"sessionId": sid, "title": ""}})
        elif method == "session/resume":
            reply(rid, {"session": {"sessionId": params.get("sessionId", sid)}})
        elif method == "session/read":
            if no_default_model:
                available = []
            else:
                available = [{"providerId": "account:test-plan-individual-coding-plan",
                              "modelId": "GLM-Mock"}]
            reply(rid, {"settings": {"model": {"available": available}}})
        elif method == "session/setModel":
            if os.environ.get("MOCK_ASSERT_NO_SETMODEL") == "1":
                store.append("FAIL: setModel sent although no pin was requested")
            model = params.get("model", "")
            if isinstance(model, dict):
                actual = f"{model.get('providerId', '')}/{model.get('modelId', '')}"
            else:
                actual = str(model)
            if expect_set_model:
                assert_true(store, actual == expect_set_model,
                            f"setModel pin {actual} == {expect_set_model}")
            reply(rid, {"applied": True})
        elif method == "session/setThoughtLevel":
            expect_thought = os.environ.get("MOCK_EXPECT_THOUGHT", "")
            level = params.get("thoughtLevel", "")
            if expect_thought:
                assert_true(store, level == expect_thought,
                            f"thoughtLevel {level} == {expect_thought}")
            reply(rid, {"applied": True})
        elif method == "session/subscribe":
            reply(rid, {"eventSeq": 0, "snapshot": {}})
        elif method == "session/send":
            reply(rid, {"accepted": True})
            provider_id = ((params.get("modelSelection") or {}).get("providerId")
                           or "account:test-plan-individual-coding-plan")
            seq += 1
            event(sid, seq, "turn.started", {})
            provider_headers_flow(provider_id)
            if ask_permission:
                aid = next_ask_id()
                ask(aid, "interaction/requestPermission",
                    {"sessionId": sid, "toolCallId": "call_1", "toolName": "Bash",
                     "reason": "mock ask",
                     "input": {"command": "echo hi"},
                     "options": [{"optionId": "allow", "kind": "allow_once", "name": "Allow once"},
                                 {"optionId": "deny", "kind": "deny_once", "name": "Deny"}]})
                result = read_reply_for(aid)
                assert_true(store, isinstance(result, dict) and result.get("decision") == "allow",
                            "permission auto-allowed")
            seq += 1
            event(sid, seq, "tool.updated",
                  {"kind": "started", "toolCallId": "call_1", "toolName": "Bash",
                   "input": {"command": "echo hi"}})
            seq += 1
            event(sid, seq, "tool.updated",
                  {"kind": "result", "toolCallId": "call_1", "toolName": "Bash",
                   "outputTail": "hi"})
            seq += 1
            event(sid, seq, "model.streaming", {"kind": "text_delta", "delta": "MOCK "})
            seq += 1
            event(sid, seq, "model.streaming", {"kind": "text_delta", "delta": "FINAL"})
            delay = float(os.environ.get("MOCK_DELAY_TURN", "0") or 0)
            if delay > 0:
                time.sleep(delay)
            if fail_turn:
                seq += 1
                event(sid, seq, "turn.failed",
                      {"error": {"code": 1308, "message": "mock failure message"}})
            else:
                seq += 1
                event(sid, seq, "turn.completed",
                      {"resultType": "success",
                       "usage": {"source": "provider", "modelRequestCount": 1,
                                 "inputTokens": 100, "outputTokens": 10,
                                 "totalTokens": 110, "cacheReadTokens": 50,
                                 "cacheWriteTokens": 0, "reasoningTokens": 0}})
        elif method == "session/messages":
            reply(rid, {"messages": [
                {"role": "user", "content": params.get("x", "")},
                {"role": "assistant",
                 "content": [{"type": "text", "text": "MOCK FINAL"}]},
            ]})
        elif method == "session/stop":
            reply(rid, {})
        else:
            if rid is not None:
                reply(rid, {})

    if assert_file:
        with open(assert_file, "w", encoding="utf-8") as f:
            f.write("\n".join(store) + "\n")
    else:
        for line in store:
            sys.stderr.write(line + "\n")
    sys.exit(0)


if __name__ == "__main__":
    main()

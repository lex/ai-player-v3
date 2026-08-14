"""
Tool-calling turn: call a skill, SEE the result, decide again — inside one turn.

The text path emits one to three actions blind and only learns how they went on the next
turn. That is what let the agent build twelve furnaces and never load them: nothing told it
the furnaces were empty while it still had a turn to act. Here each call comes back with the
skill's own {ok, detail} before the next decision.

Two hard limits, because Factorio does NOT pause while the model thinks. The world keeps
moving, so a turn that deliberates for two minutes is acting on a world that no longer
exists:
  MAX_CALLS   — how many skills may run in one turn
  MAX_SECONDS — wall clock for the whole turn, checked between calls

Skills run through the mod's remote interface (RCONGateway.run_skill), the same dispatch
path the mod uses itself, so mechanics stay in exactly one place.
"""

import json
import logging
import time

from .providers.openai_compat import complete_with_tools
from .tools import skill_tools

log = logging.getLogger(__name__)

MAX_CALLS = 3
MAX_SECONDS = 45.0


class ToolLoopResult:
    def __init__(self, executed: list[dict], narration: str | None, stopped_because: str):
        self.executed = executed          # [{skill, params, ok, detail}]
        self.narration = narration        # the model's closing words, if any
        self.stopped_because = stopped_because

    @property
    def did_anything(self) -> bool:
        return bool(self.executed)


def run_tool_turn(messages: list[dict], provider_cfg, rcon) -> ToolLoopResult | None:
    """
    Drive one turn as a tool-calling conversation. Returns None if the model could not be
    reached at all, so the caller can fall back to the text path.
    """
    tools = skill_tools()
    convo = list(messages)
    executed: list[dict] = []
    started = time.monotonic()

    for step in range(MAX_CALLS):
        reply = complete_with_tools(convo, provider_cfg, tools)
        if reply is None:
            # Nothing came back. If earlier calls already did work, keep it.
            return ToolLoopResult(executed, None, "model unreachable") if executed else None

        calls = reply.get("tool_calls") or []
        if not calls:
            return ToolLoopResult(executed, reply.get("content"), "model finished")

        convo.append({
            "role": "assistant",
            "content": reply.get("content") or None,
            "tool_calls": [
                {"id": c["id"], "type": "function",
                 "function": {"name": c["name"], "arguments": c["arguments"]}}
                for c in calls
            ],
        })

        for call in calls:
            try:
                params = json.loads(call["arguments"]) if call["arguments"] else {}
            except ValueError:
                params = {}
            if not isinstance(params, dict):
                params = {}

            result = rcon.run_skill(call["name"], params)
            ok = bool(result.get("ok"))
            detail = str(result.get("detail", ""))
            executed.append({"skill": call["name"], "params": params, "ok": ok, "detail": detail})
            log.info("  tool %s(%s) -> %s: %s", call["name"],
                     ", ".join(f"{k}={v}" for k, v in params.items()), ok, detail[:120])

            convo.append({
                "role": "tool",
                "tool_call_id": call["id"],
                "content": json.dumps({"ok": ok, "detail": detail}),
            })

        elapsed = time.monotonic() - started
        if elapsed > MAX_SECONDS:
            return ToolLoopResult(executed, None,
                                  f"time budget spent ({elapsed:.0f}s of {MAX_SECONDS:.0f}s)")

    return ToolLoopResult(executed, None, f"call limit reached ({MAX_CALLS})")

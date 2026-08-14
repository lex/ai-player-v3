"""
Router agent (v3).

Agent.decide() builds the small router prompt from raw perception, calls the
LLM, parses + validates the response into a list of skill/primitive entries,
and returns it. Skills are validated against api.SKILLS, primitives against
api.ACTIONS (see factorio/api.py). Stateless between calls.
"""

import logging
import time

from .config import BridgeConfig
from .factorio.api import parse_response
from .factorio.watcher import PendingRequest
from .metrics import STATUS_OK, STATUS_PARSE_ERROR, STATUS_TIMEOUT, record_exchange
from .agent_loop import run_tool_turn
from .goals import GoalTracker, TurnHistory
from .prompt import build_messages, next_objective
from .providers import get_provider
from .transcript import log_exchange

log = logging.getLogger(__name__)


def _count(value) -> int:
    """ghosts/deconstruction arrive as a plain int or as {count, list} depending on the
    perception path that produced them."""
    if isinstance(value, dict):
        return int(value.get("count", 0) or 0)
    return int(value or 0)


def _model_needed(payload: dict) -> str | None:
    """
    Why this turn needs a model, or None when the deterministic ladder is enough.

    The model is for judgement under ambiguity. It is not for arithmetic: when the
    bootstrap ladder already yields exactly one sensible move, asking a model to agree
    costs 15-20s and a few thousand tokens per turn and can only introduce disagreement.
    A turn is handed to the model when something genuinely open is happening — the human
    is directing, or has placed ghosts / marked deconstruction, or the ladder has run out
    and the base needs actual planning.
    """
    perception = payload.get("perception") or {}
    memory = perception.get("memory") or payload.get("memory") or {}

    if payload.get("user_message"):
        return "player sent a message"
    if memory.get("user_directive"):
        return "a player directive is active"
    if memory.get("force_skill"):
        return "a skill is force-gated"
    if _count(perception.get("ghosts")) > 0:
        return "the human placed ghosts"
    if _count(perception.get("deconstruction")) > 0:
        return "the human marked deconstruction"

    # A failure last turn means the obvious move already did not work; let the model
    # read the failure detail and choose differently rather than repeating the ladder.
    for r in (memory.get("last_action_results") or []):
        if not r.get("ok"):
            return "the last turn had a failure to react to"

    return None


def _fallback(reason: str) -> list[dict]:
    """Safe response so the mod never hangs; the summary states the real reason."""
    return [
        {"action": "wait"},
        {"action": "summary", "text": f"No action this turn — {reason}."},
    ]


class Agent:
    def __init__(self, rcon=None):
        # Long-lived with the bridge process, so goals and history persist across turns.
        self.goals = GoalTracker()
        self.history = TurnHistory()
        # Needed only by the tool loop, which executes skills through the mod directly.
        self.rcon = rcon

    def decide(self, req: PendingRequest, config: BridgeConfig) -> list[dict]:
        provider_cfg = config.to_provider_config()
        complete = get_provider(provider_cfg)

        payload = req.payload
        if "perception" not in payload:
            log.error("Request %s: no 'perception' in payload — fallback", req.req_id)
            return _fallback("internal error: request had no perception")

        # Deterministic fast path: during the bootstrap the next move is a fact about
        # Factorio, not a judgement call, so answer it directly instead of paying a
        # model round trip to be told what we already computed.
        perception = payload["perception"]
        memory = perception.get("memory") or {}
        objective_entry, _, _ = next_objective(perception)
        self.goals.observe(objective_entry, memory.get("last_action_results"))

        why_model = _model_needed(payload)
        # A stuck goal is exactly the case the ladder cannot fix by repeating itself, so
        # hand it to the model even though the situation looks unambiguous.
        if why_model is None and self.goals.stuck:
            why_model = "the current goal has failed repeatedly"

        if why_model is None:
            entry, chat_line, _ = next_objective(perception)
            if entry:
                log.info("Request %s: answered from the objective ladder, no model call (%s)",
                         req.req_id, entry.get("skill"))
                self.history.record(f"ladder chose {entry.get('skill')}")
                return [{"action": "chat", "message": chat_line}, entry]

        notes = [n for n in (self.goals.note(), self.history.as_message()) if n]
        messages = build_messages(payload, config.system_prefix,
                                  "\n\n".join(notes) if notes else None)

        # Tool-calling turn: call a skill, see its result, decide again — all before the
        # turn ends. Falls through to the single-shot text path if it cannot run.
        if config.tool_loop and self.rcon is not None:
            log.info("Request %s: tool-calling turn (%s)", req.req_id, why_model)
            result = run_tool_turn(messages, provider_cfg, self.rcon)
            if result is not None and result.did_anything:
                self.history.record_tool_turn(result.executed)
                log.info("Request %s: %d tool call(s), stopped because %s",
                         req.req_id, len(result.executed), result.stopped_because)
                # The skills have already run, so the mod just needs something to close the
                # request with: say what happened rather than acting twice.
                summary = "; ".join(
                    f"{e['skill']}: {'ok' if e['ok'] else 'failed'}" for e in result.executed)
                say = result.narration or ("Did: " + summary)
                return [
                    {"action": "chat", "message": say[:240]},
                    {"action": "summary", "text": summary[:400]},
                ]
            log.warning("Request %s: tool loop produced nothing — using the text path",
                        req.req_id)

        log.info("Routing request %s via %s (model=%s)",
                 req.req_id, provider_cfg.provider, provider_cfg.model)
        t0 = time.monotonic()
        content = complete(messages, provider_cfg)
        elapsed = time.monotonic() - t0

        if content is None:
            log.error("Request %s: no response after %.1fs (timeout=%.0fs) — fallback. "
                      "Raise AI_TIMEOUT or use a faster model.",
                      req.req_id, elapsed, provider_cfg.timeout)
            actions = _fallback(f"model did not respond within {provider_cfg.timeout:.0f}s "
                                f"(raise AI_TIMEOUT or use a faster model)")
            log_exchange(config.output_dir, req.req_id, messages, None, elapsed, actions)
            record_exchange(config.output_dir, req.req_id, payload, None, STATUS_TIMEOUT,
                            elapsed, provider_cfg.provider, provider_cfg.model)
            return actions

        log.info("Request %s: response in %.1fs (%d chars)", req.req_id, elapsed, len(content))
        log.debug("Request %s raw: %s", req.req_id, content[:600])

        entries = parse_response(content)
        if entries is None:
            log.warning("Request %s: could not parse skills/actions — fallback. Raw: %s",
                        req.req_id, content[:600])
            log_exchange(config.output_dir, req.req_id, messages, content, elapsed, None)
            record_exchange(config.output_dir, req.req_id, payload, None, STATUS_PARSE_ERROR,
                            elapsed, provider_cfg.provider, provider_cfg.model)
            return _fallback("could not parse a valid skill/action array from the model's reply")

        entries = self._label_chat(entries, provider_cfg.provider)
        log.info("Request %s: %d entr(ies) [%s]", req.req_id, len(entries),
                 ", ".join(e.get("skill") or e.get("action", "?") for e in entries))
        log_exchange(config.output_dir, req.req_id, messages, content, elapsed, entries)
        record_exchange(config.output_dir, req.req_id, payload, entries, STATUS_OK,
                        elapsed, provider_cfg.provider, provider_cfg.model)
        return entries

    @staticmethod
    def _label_chat(entries: list[dict], provider: str) -> list[dict]:
        """Prefix each chat action's message with the provider name."""
        labels = {"anthropic": "[Claude]", "openai": "[GPT]", "lmstudio": "[Local]", "custom": "[Custom]"}
        label = labels.get(provider, "[AI]")
        for e in entries:
            if e.get("action") == "chat" and e.get("message"):
                e["message"] = f"{label} {e['message']}"
        return entries

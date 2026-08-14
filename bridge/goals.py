"""
Cross-turn continuity.

Every turn is otherwise decided from scratch: perception in, actions out, nothing carried
over but the mod's short memory. That is what produced the oscillation seen in play — mine,
then power, then mine again — and what let a failing objective be retried forever, because
each turn had no idea the last three had tried the same thing.

The bridge is a long-running process, so this state costs nothing to keep here. It lives in
memory deliberately: it is an observation about the current run, not a fact about the world,
and a restart should forget it.
"""

import logging

log = logging.getLogger(__name__)

# How many times the same objective may be attempted before we tell the model to stop
# repeating it. Three is enough to ride out a transient failure (a full inventory, a
# half-finished craft) without letting a genuinely stuck loop run all night.
STUCK_AFTER = 3


class GoalTracker:
    def __init__(self):
        self._goal: str | None = None
        self._attempts: int = 0
        self._failures: int = 0

    def observe(self, objective: dict | None, last_results: list[dict] | None) -> None:
        """Record what we are about to attempt and how the previous attempt went."""
        key = objective.get("skill") if objective else None

        if key != self._goal:
            self._goal, self._attempts, self._failures = key, 0, 0

        if key:
            self._attempts += 1

        for r in (last_results or []):
            if not r.get("ok") and str(r.get("action", "")).endswith(str(self._goal)):
                self._failures += 1

    @property
    def stuck(self) -> bool:
        return bool(self._goal) and self._attempts >= STUCK_AFTER and self._failures > 0

    def note(self) -> str | None:
        """A line for the prompt, or None when there is nothing worth saying."""
        if not self._goal or self._attempts < 2:
            return None

        if self.stuck:
            return (
                f'You have now tried "{self._goal}" {self._attempts} turns running and it has '
                f"failed {self._failures} time(s). STOP repeating it. Read the failure detail in "
                "your last results and do what it asks — clear_area if the ground is blocked, "
                "gather or craft if something is missing, explore if the resource is not here — "
                "or pick a different goal entirely."
            )
        return (
            f'Continuing "{self._goal}" (turn {self._attempts} on this goal). Finish it rather '
            "than starting something else, unless your last results say it cannot be done."
        )

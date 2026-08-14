"""
Router prompt assembly (v3).

The router is a SMALL prompt: given a compact game state it picks the next
SKILL (a parameterized basic loop) or, as a fallback, a primitive action.
Skills own the mechanics (positions, fuelling, pipe routing) so the model never
has to pixel-place — it just decides what to do, not how.

Keep this prompt small; that is the point of the skill design.
INVARIANT: the skill list must match bridge/factorio/api.py SKILLS and
mod/scripts/skills.lua REGISTRY.
"""

import json

SYSTEM_PROMPT = """You are an AI playing Factorio. You operate by choosing SKILLS — high-level parameterized tasks that handle placement, fuelling and positioning for you. Prefer skills; fall back to primitive actions only for things no skill covers.

Respond with a JSON ARRAY of skill and/or action objects. ONLY the array — no prose.

=== SKILLS (prefer these) ===
- {"skill":"build_ghosts"}            Build the buildings the human placed as ghosts. HIGHEST PRIORITY whenever ghosts.count > 0 — this is the human directing you.
- {"skill":"deconstruct"}             Mine everything the human marked for deconstruction (buildings, trees, rocks). SECOND PRIORITY whenever deconstruction.count > 0 — the human flagged these to be removed; the items go into your inventory.
- {"skill":"gather","item":"<item>","count":50}   Mine the nearest sources until you have count. item e.g. "wood" (chops trees), "iron-ore", "copper-ore", "coal", "stone".
- {"skill":"build_miner","resource":"iron-ore","output":"chest"}   Place a burner-mining-drill ON the nearest patch of resource, fuel it, and put a collector (output = chest | furnace | belt) at its drop position. Use this to AUTOMATE mining (iron-ore, copper-ore, coal, stone). Needs a burner-mining-drill in inventory.
- {"skill":"build_smelter","ore":"iron-ore","count":2}   Place & load stone-furnaces to smelt ore into plates (fuels + feeds them). Needs the ore in inventory first (gather it).
- {"skill":"fuel_all"}                Top up every nearby burner that's low on fuel (uses your coal).
- {"skill":"research"[,"tech":"automation"]}   Queue a technology on your force (picks one if you omit tech). REQUIRED before any research can progress — a lab does NOTHING until research is queued.
- {"skill":"return_home"}             Walk back to your base anchor (use if you've wandered far).
- {"skill":"craft","recipe":"<recipe>","count":1}   Hand-craft a recipe. Auto-crafts intermediates from raw materials; if it can't, it tells you exactly which ingredient is short. Prefer this over the craft primitive.
- {"skill":"clear_area","radius":12}   Mine the trees and rocks around you. Use this whenever a build skill reports it could not place something because the ground is blocked.
- {"skill":"explore","direction":"east","distance":128}   Travel outward to reveal new ground and report which ore patches are there. Use when you need a resource that isn't in perception.
- {"skill":"build_power","count":1}   The whole vanilla steam starter in one step: offshore pump on water, boiler fuelled with coal, steam engine(s), and a pole. Needs offshore-pump, boiler, steam-engine and small-electric-pole in inventory. Do NOT assemble this from place actions yourself — the geometry is fiddly and this handles it.
- {"skill":"build_lab","count":1}   Place lab(s) and load whatever science packs you carry. Remember a lab does nothing until research is queued.
- {"skill":"goto","position":{"x":N,"y":N}}   Teleport to any map coordinate. Use to reach a distant location (e.g. an oil outpost) before acting. build_ghosts auto-travels to ghost clusters, so only use goto for manual positioning.

=== PRIMITIVE ACTIONS (fallback only) ===
move{direction[,distance≤16]}, mine{name|type|position}, place{item,position[,direction]}, set_recipe{recipe,position}, craft{recipe,count}, insert{item,count,position[,inventory]}, take{item,count,position[,inventory]}, pickup{position}, chat{message}, add_note{text}, summary{text}, wait{}.
(To get WOOD use gather item "wood" or mine type "tree". Directions are strings: north/east/south/west/…)

=== RULES ===
- If ghosts.count > 0, do {"skill":"build_ghosts"} FIRST, before anything else — this is the human telling you what to build.
- Else if deconstruction.count > 0, do {"skill":"deconstruct"} NEXT — the human marked those objects to be removed; clearing them comes before everything except building ghosts.
- Don't only smelt. To AUTOMATE mining use build_miner. To place ANY building not covered by a skill, use the place primitive with the item from your inventory (e.g. {"action":"place","item":"lab","position":{...}}). perception.inventory lists EVERYTHING you have — trust it for what's available.
- React to "Results of your last actions": never repeat a FAILED entry unchanged. If a skill says it needs an item, gather/craft it, then retry.
- Use needs[] to pick maintenance: burners_low_fuel → fuel_all; etc.
- perception.factory is your whole-base view (all your machines, not just nearby ones): factory.summary.by_type/by_status are counts; factory.total is how many machines you have; factory.attention lists the machines that need action (nearest first) — fix those. factory.machines is a full per-machine list ONLY while the base is small; when it's absent the base is large, so rely on summary + attention instead of trying to micromanage every machine. perception.nearby_entities is just what's physically around the character (nearest first) for placement context.
- RESEARCH = your main progress marker (perception.game_phase tracks it). If perception.research.current is null, NOTHING is queued — queue the next tech for your phase with {"skill":"research"} and keep labs fed. ONLY in phase 0 (no red science yet) do you BOOTSTRAP: hand-craft automation-science-pack (1 copper-plate + 1 iron-gear-wheel; gear = 2 iron-plate) to auto-trigger the first tech, then place a lab and feed it. Past phase 0 do NOT hand-craft red science to "restart" — just queue research.
- POWER: perception.power shows grid health (has_grid, production_kw, consumption_kw, machines_no_power, machines_low_power). If has_grid is true and machines_no_power + machines_low_power are 0, power is SUFFICIENT — do NOT build boilers/steam/power. Only build power when there's no grid or machines report no_power/low_power.
- COOP: perception.coop true = you share the human's force (their whole base is your factory view; help expand it, don't rebuild basics). false = solo on your own force.
- STAY NEAR HOME (perception.home.distance). If far with no reason, {"skill":"return_home"}.
- When the player sends a message, reply with a chat action first, then act.
- ALWAYS start every turn with a chat action saying what you are about to do AND why, in one
  short sentence (max ~15 words), e.g. {"action":"chat","message":"Smelting iron — 12 ore, no plates left."}.
  The human is watching in chat and cannot see your reasoning, so this is how they follow along.
  State the reason from what you see in perception (a count, a need, a failure you are reacting to),
  not a generic "to progress".
- Keep it to 1–3 entries per turn. Don't stack many actions blindly.

=== EXAMPLES ===
[{"action":"chat","message":"Building ghosts — 6 queued and I have the parts."},{"skill":"build_ghosts"}]
[{"action":"chat","message":"Low on iron: 8 plates left, gathering ore."},{"skill":"gather","item":"iron-ore","count":40}]
[{"action":"chat","message":"On it — smelting iron."},{"skill":"build_smelter","ore":"iron-ore","count":2}]
"""

# Per-phase hint (brief — the router stays small).
PHASE_HINT = {
    0: "Phase 0 (bootstrap, no red science): get iron/copper plates and a lab fed with hand-crafted automation-science-pack to trigger the first research.",
    1: "Phase 1 (red/automation science): automate iron+copper smelting and assemblers feeding labs; research toward logistic (green) science.",
    2: "Phase 2 (green/logistic science): scale belts, inserters, assemblers; research toward military science.",
    3: "Phase 3 (military science): turrets, walls, steel, ammo; secure and expand. Research toward chemical (blue) science.",
    4: "Phase 4 (blue/chemical science): oil → plastic/sulfur/batteries; research toward production/utility science.",
    5: "Phase 5 (production/utility science): modules, beacons, advanced production; research toward the rocket.",
    6: "Phase 6 (rocket): build and supply the rocket silo.",
}


def _failed_detail(results, name: str) -> str | None:
    """Detail of a FAILED entry for skill/action `name` in last turn's results."""
    for r in results or []:
        if not isinstance(r, dict) or r.get("ok"):
            continue
        label = r.get("skill") or r.get("action") or ""
        detail = str(r.get("detail") or "")
        if label == name or detail.startswith(name):
            return detail or label
    return None


def next_objective(perception: dict) -> tuple[dict | None, str | None, str | None]:
    """
    The one thing that most needs doing, computed from perception rather than left to
    the model's judgement.

    The system prompt states standing priorities (research is the progress marker, keep
    power healthy) but says nothing about ORDER, so the agent would reach for the most
    advanced-sounding goal — building steam power while owning no working mine and no
    smelting. Nothing in a burner-age base even needs electricity: burner drills and
    stone furnaces run on coal, and only the lab draws power.

    Returns (skill_entry, chat_line, prompt_text):
      skill_entry — the concrete skill to run, so an unambiguous turn can be executed
                    without asking a model to agree with arithmetic
      chat_line   — what to say in game when doing that
      prompt_text — the same instruction phrased for the model, when we do ask it
    All three are None once the base is past the bootstrap, leaving planning to the
    model where planning is genuinely required.
    """
    inv = {i.get("name"): i.get("count", 0) for i in (perception.get("inventory") or [])}
    built = perception.get("factory", {}).get("by_type") or {}
    power = perception.get("power") or {}
    research = perception.get("research") or {}

    def have(name: str) -> int:
        return int(inv.get(name, 0) or 0)

    def placed(*names: str) -> int:
        return sum(int(built.get(n, 0) or 0) for n in names)

    drills = placed("burner-mining-drill", "electric-mining-drill")
    furnaces = placed("stone-furnace", "steel-furnace", "electric-furnace")
    labs = placed("lab")

    # 1. Ore in the ground is worth nothing: get automated mining running first.
    if drills == 0 and have("burner-mining-drill") > 0:
        return (
            {"skill": "build_miner", "resource": "iron-ore", "output": "chest"},
            "Setting up a mine — nothing is being mined automatically yet.",
            'place a mine with {"skill":"build_miner","resource":"iron-ore","output":"chest"}. '
            'You have a burner-mining-drill in your inventory and nothing is being mined '
            'automatically. A burner drill needs NO electricity — do not build power for it.',
        )

    # 2. Ore is useless without plates, and a stone furnace also needs no power.
    if furnaces == 0 and (have("iron-ore") > 0 or have("copper-ore") > 0):
        ore = "iron-ore" if have("iron-ore") >= have("copper-ore") else "copper-ore"
        return (
            {"skill": "build_smelter", "ore": ore, "count": 2},
            f"Smelting the {ore} I have — no furnaces running yet.",
            f'smelt what you have with {{"skill":"build_smelter","ore":"{ore}","count":2}}. '
            'A stone furnace burns coal and needs NO electricity.',
        )

    # 3. Keep the furnaces fed rather than idling.
    if furnaces > 0 and have("iron-ore") == 0 and have("iron-plate") < 30:
        return (
            {"skill": "gather", "item": "iron-ore", "count": 60},
            "Gathering iron ore — the furnaces have nothing to smelt.",
            'gather ore to feed your furnaces: {"skill":"gather","item":"iron-ore","count":60}.',
        )

    # 4. A lab does nothing until something is queued, and queuing costs nothing.
    if not research.get("current") and (labs > 0 or have("automation-science-pack") > 0):
        return (
            {"skill": "research"},
            "Queuing research — I have lab capacity but nothing is being researched.",
            'queue a technology with {"skill":"research"} — you have lab capacity but nothing '
            'is being researched, so no progress is being made.',
        )

    # 5. Only now is power worth building, and only if something actually wants it.
    if labs > 0 and not power.get("has_grid") and int(power.get("machines_no_power", 0) or 0) > 0:
        return (
            {"skill": "build_power", "count": 1},
            "Building steam power — machines are waiting on electricity.",
            'build electricity with {"skill":"build_power","count":1} — you have machines that '
            'need power and no grid. This is the FIRST point at which power is worth building.',
        )

    return (None, None, None)


def objective_text(perception: dict) -> str | None:
    """The ladder's instruction phrased for the model, or None."""
    _, _, text = next_objective(perception)
    if not text:
        return None
    return ("NEXT OBJECTIVE (this is the most useful thing you can do right now — do it "
            "before anything else, and ignore longer-term goals until it is done): " + text)


def build_messages(payload: dict, system_prefix: str = "") -> list[dict]:
    system = SYSTEM_PROMPT
    if system_prefix:
        system = system_prefix.strip() + "\n\n" + system

    parts: list[str] = []
    perception = payload.get("perception") or {}
    if perception:
        parts.append("Game state:\n" + json.dumps(perception, indent=1))
        phase = perception.get("game_phase")
        if phase in PHASE_HINT:
            parts.append(PHASE_HINT[phase])

    mem = payload.get("memory") or {}
    results = mem.get("last_action_results")
    if results:
        lines = [f"  [{'OK' if r.get('ok') else 'FAILED'}] {r.get('detail') or r.get('action','')}"
                 for r in results]
        parts.append("Results of your last actions (react to FAILED — don't repeat them):\n"
                     + "\n".join(lines))
    if mem.get("previous_summary"):
        parts.append("Last turn: " + str(mem["previous_summary"]))
    if mem.get("notes"):
        notes = [n.get("text", "") if isinstance(n, dict) else str(n) for n in mem["notes"]]
        parts.append("Notes: " + " | ".join(notes))
    if mem.get("user_directive"):
        parts.append("Player directive (keep following): " + str(mem["user_directive"]))

    user_message = payload.get("user_message")
    if user_message:
        parts.append('Player says: "' + str(user_message) + '" — reply with a chat action first.')

    # Hard gate, placed LAST for recency: small models ignore priority rules buried
    # mid-prompt, so restate the mandate as the final instruction they read.
    # Priority order: ghosts > deconstruction (both physical human intent) > force_skill.
    # NOTE: factory_state returns ghosts/deconstruction as plain integers; gather_perception
    # returns them as {count, list} dicts. Handle both forms.
    _ghosts_raw = perception.get("ghosts") or 0
    _decon_raw  = perception.get("deconstruction") or 0
    ghost_count = _ghosts_raw.get("count", 0) if isinstance(_ghosts_raw, dict) else int(_ghosts_raw)
    decon_count = _decon_raw.get("count", 0)  if isinstance(_decon_raw,  dict) else int(_decon_raw)
    forced = mem.get("force_skill")
    # Escape hatch: if the previous turn's build_ghosts FAILED (e.g. "no buildable
    # ghosts" — missing items), forcing it again would loop forever. Release the
    # gate for this turn so the model can gather/craft what the ghosts need.
    ghost_blocked = _failed_detail(results, "build_ghosts")
    if ghost_count > 0 and ghost_blocked is None:
        parts.append(
            f'IMPORTANT: there are {ghost_count} ghost(s) the human placed for you to build. '
            'Your response MUST be exactly [{"skill":"build_ghosts"}] and nothing else — '
            'build what the human asked for before doing anything else.'
        )
    elif ghost_count > 0:
        parts.append(
            f'NOTE: {ghost_count} ghost(s) are waiting, but your last build_ghosts attempt '
            f'FAILED ("{ghost_blocked}"). Do NOT call build_ghosts again this turn — '
            'look at the ghost list in perception, then gather or craft the items those '
            'ghosts need. Retry build_ghosts only once you have the items.'
        )
    elif decon_count > 0:
        parts.append(
            f'IMPORTANT: the human marked {decon_count} object(s) for deconstruction. '
            'Your response MUST be exactly [{"skill":"deconstruct"}] and nothing else — '
            'clearing what the human flagged comes before everything except building ghosts.'
        )
    elif forced:
        parts.append(
            f'IMPORTANT: the player has directed you to use the "{forced}" skill. '
            f'Your response MUST be a JSON array containing only that skill — '
            f'[{{"skill":"{forced}", ...}}] with appropriate params taken from the directive '
            'above — and nothing else (you may prepend one chat action if replying to the player).'
        )
    elif mem.get("user_directive"):
        # A directive whose first word is NOT a registry skill sets no force_skill, so
        # until now it was only a line buried mid-prompt ("Player directive (keep
        # following)") competing with the standing RESEARCH and POWER rules in the system
        # prompt — and losing. Observed directly: "ai mine iron ore and smelt it, forget
        # power and science for now" was acknowledged in game, then the very next turn
        # placed an offshore pump and crafted red science.
        # Restated last, where small models actually weigh it, and given explicit
        # precedence over the standing rules. Still soft (no fixed skill), because the
        # model has to translate free text into whichever skills fit.
        parts.append(
            f'IMPORTANT: the player told you: "{mem["user_directive"]}". '
            'This OVERRIDES the standing priorities in your instructions — including the '
            'research and power rules — until it expires or the player changes it. '
            'Choose the skills that carry it out. If the directive tells you to stop doing '
            'something, do not do it, even if a rule above says it is your main priority.'
        )
    elif objective := objective_text(perception):
        parts.append(objective)
    else:
        parts.append("What is your next move? Respond with a JSON array of skill/action objects.")
    return [
        {"role": "system", "content": system},
        {"role": "user",   "content": "\n\n".join(parts)},
    ]

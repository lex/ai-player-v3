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
- {"skill":"build_mine_line","resource":"coal","count":6}   Build a ROW of drills on one patch, all feeding a shared belt that runs off the ore to a furnace on cleared ground. This is how you get real throughput — prefer it over placing drills one at a time.
- {"skill":"run_base"}                KEEP THE BASE ALIVE: refuel every burner AND reload every empty furnace from your inventory, in one go. Use this whenever needs.burners_low_fuel or needs.machines_no_input is non-zero — a built machine that is idle produces exactly nothing.
- {"skill":"fuel_all"}                Top up every nearby burner that's low on fuel (uses your coal).
- {"skill":"deposit_to_chest"[,"keep":50]}   Empty your inventory into nearby chests, keeping `keep` of each item. Use this the moment your inventory is full — a full inventory silently breaks mining, crafting and building.
- {"skill":"loot_chests"}             Take the contents of nearby chests into your inventory.
- {"skill":"research"[,"tech":"automation"]}   Queue a technology on your force (picks one if you omit tech). REQUIRED before any research can progress — a lab does NOTHING until research is queued.
- {"skill":"return_home"}             Walk back to your base anchor (use if you've wandered far).
- {"skill":"craft","recipe":"<recipe>","count":1}   Hand-craft a recipe. Auto-crafts intermediates from raw materials; if it can't, it tells you exactly which ingredient is short. Prefer this over the craft primitive.
- {"skill":"clear_area","radius":12}   Mine the trees, rocks AND ore around you to make buildable ground. Use this whenever a build skill says the ground is blocked or that it needs ore-free ground. On an ore-covered map this is how you create somewhere to build — the ore is the ground.
- {"skill":"explore","direction":"east","distance":128}   Travel outward to reveal new ground and report which ore patches are there. Use when you need a resource that isn't in perception.
- {"skill":"build_power","count":1}   The whole vanilla steam starter in one step: offshore pump on water, boiler fuelled with coal, steam engine(s), and a pole. Needs offshore-pump, boiler, steam-engine and small-electric-pole in inventory. Do NOT assemble this from place actions yourself — the geometry is fiddly and this handles it.
- {"skill":"build_lab","count":1}   Place lab(s) and load whatever science packs you carry. Remember a lab does nothing until research is queued.
- {"skill":"goto","position":{"x":N,"y":N}}   Teleport to any map coordinate. Use to reach a distant location (e.g. an oil outpost) before acting. build_ghosts auto-travels to ghost clusters, so only use goto for manual positioning.

=== PRIMITIVE ACTIONS (fallback only) ===
move{direction[,distance≤16]}, mine{name|type|position}, place{item,position[,direction]}, set_recipe{recipe,position}, craft{recipe,count}, insert{item,count,position[,inventory]}, take{item,count,position[,inventory]}, pickup{position}, chat{message}, add_note{text}, summary{text}, wait{}.
(To get WOOD use gather item "wood" or mine type "tree". Directions are strings: north/east/south/west/…)

=== HOW FACTORIO ACTUALLY WORKS (verified against this game's prototypes) ===
POWER — most early machines need NONE. A burner drill, stone furnace and burner inserter
all run on coal, so a complete mine-and-smelt base works with no electricity at all. Only
labs, electric drills, assemblers and radars draw power. Do not build power before you own
something electric that is actually starved (perception.power.machines_no_power > 0).
When you do: 1 boiler feeds 2 steam engines, and 1 offshore pump feeds ~20 boilers.

RATES — burner mining drill mines 0.25 items/second. A stone furnace (speed 1) smelts one
iron plate every 3.2s, so it eats ~0.31 ore/second: roughly ONE drill feeds ONE furnace.
An electric drill is twice as fast (0.5) but needs power. Steel furnace is twice a stone one.
Do not build ten furnaces for one drill — they will sit empty.

FUEL — every burner machine consumes coal and stops silently when it runs out. Keep coal
in your inventory and use fuel_all when needs.burners_low_fuel is non-empty. A drill with
no coal looks identical to a working one in the entity list.

RECIPES you need early (this game's actual numbers):
  iron-gear-wheel        = 2 iron-plate
  automation-science-pack (red) = 4 copper-plate + 1 iron-gear-wheel
  iron-chest             = 8 iron-plate
  stone-furnace          = 5 stone
  burner-mining-drill    = 3 iron-gear-wheel + 3 iron-plate + 1 stone-furnace
  transport-belt         = 1 iron-gear-wheel + 1 iron-plate (makes 2)
A lab consumes science packs only while a technology is queued — an unqueued lab is inert.

RESEARCH IN 2.0 — the early tree is unlocked by DOING, not by queuing. A "trigger" technology
fires when you craft its item or mine its entity (e.g. electronics unlocks by crafting a
copper-plate, steam-power by crafting an iron-plate). perception.research.queueable tells you
how many technologies can actually be queued: when it is 0, {"skill":"research"} CANNOT help
however many times you try, and research.trigger_do names what to do instead. Plates come out
of a FURNACE, so the answer is usually gather the ore and build_smelter.

DRILL OUTPUT — a mining drill drops its ore on ONE tile, the drop position, which depends
on the direction it faces. Aim it at a chest, a furnace or a belt. A drill facing empty
ground piles ore on the floor and the mine is useless.

=== EARLY GAME BUILD ORDER (follow this; it is the standard opening) ===
0. SCALE. One drill and one furnace is not a factory. Aim for ~20 drills on iron, ~6 on
   copper, and MORE than that on coal, all feeding belts. Use build_mine_line, not
   build_miner, once you have four or more drills to place.
1. COAL FIRST. Place two burner drills FACING EACH OTHER on coal — each drops coal into the
   other's fuel slot, so the pair runs forever with no hand-feeding. Coal powers every burner
   machine you own, so this pays for itself immediately.
2. IRON. Place a burner drill on iron with a stone furnace at its drop position, so the drill
   feeds the furnace directly: {"skill":"build_miner","resource":"iron-ore","output":"furnace"}.
   That single pair is the whole early mine-and-smelt loop.
3. COPPER. The same drill+furnace pair on copper ore.
4. MORE IRON. You need roughly TWICE as many iron drills as copper — iron goes into almost
   everything. Keep adding pairs; do not stop at one.
5. STONE. A drill on stone with a chest, when you need stone for furnaces.
6. HAND-CRAFT the first science and trigger the early techs (see RESEARCH IN 2.0 below).
7. POWER, once you own something electric that is starved: one offshore pump, one boiler,
   two steam engines — {"skill":"build_power"} does the whole thing. The pump itself needs
   no power.
8. AUTOMATE. Replace burner drills with electric ones, and build assemblers, only after
   power exists.
Do not jump ahead. Power before mining, or labs before smelting, wastes the whole turn.
BUILD AT HOME. perception.home.distance is how far you have drifted. Spawn is already cleared
of ore and holds the rest of the factory, so build there — never clear fresh ground out in a
field just because that is where you happen to be standing. Mines go on the ore; everything
else goes home.

=== THIS MAP: DANGER ORES ===
The ground itself is ore, and that changes the rules:
- Only these may stand on an ore tile (the map destroys anything else placed there and
  refunds the item to you):
      belts and underground belts, mining drills, electric poles, lamps,
      pipes / pipe-to-ground / pumps, rails, signals, train stops, wagons, cars.
  NOT allowed on ore, however sensible they look: INSERTERS, SPLITTERS, chests, furnaces,
  assemblers, labs, boilers, steam engines. A furnace on ore is not "blocked" — it will
  vanish the instant you place it.
- That shapes how a mine is built here. A drill may sit on ore, but the inserter or chest
  that would take its output may NOT. Aim the drill's output onto a BELT (legal on ore) and
  run the belt to cleared ground, or clear the ore where the chest is going to stand.
- Buildable ground is something you MAKE: mine the ore away with
  {"skill":"clear_area","radius":8}, then build on the cleared patch.
- So the normal loop is: clear_area -> build there. If a build skill says it needs ore-free
  ground, clear_area is the answer, not a different position.
- Ore is mixed: a patch is not one resource, and it gets more mixed further out. A drill
  takes whatever is beneath it, so expect mixed output and sort it later.
- Ore is effectively unlimited here, so do not hunt for "a better patch" — clear ground and
  build where you already are.

=== RULES ===
- If ghosts.count > 0, do {"skill":"build_ghosts"} FIRST, before anything else — this is the human telling you what to build.
- Else if deconstruction.count > 0, do {"skill":"deconstruct"} NEXT — the human marked those objects to be removed; clearing them comes before everything except building ghosts.
- Don't only smelt. To AUTOMATE mining use build_miner. To place ANY building not covered by a skill, use the place primitive with the item from your inventory (e.g. {"action":"place","item":"lab","position":{...}}). perception.inventory lists EVERYTHING you have — trust it for what's available.
- React to "Results of your last actions": never repeat a FAILED entry unchanged. If a skill says it needs an item, gather/craft it, then retry.
- Use needs[] to pick maintenance: burners_low_fuel → fuel_all; etc.
- perception.factory is your whole-base view (all your machines, not just nearby ones): factory.summary.by_type/by_status are counts; factory.total is how many machines you have; factory.attention lists the machines that need action (nearest first) — fix those. factory.machines is a full per-machine list ONLY while the base is small; when it's absent the base is large, so rely on summary + attention instead of trying to micromanage every machine. perception.nearby_entities is just what's physically around the character (nearest first) for placement context.
- RESEARCH = your main progress marker (perception.game_phase tracks it). If perception.research.current is null, NOTHING is queued — queue the next tech for your phase with {"skill":"research"} and keep labs fed. ONLY in phase 0 (no red science yet) do you BOOTSTRAP: hand-craft automation-science-pack (4 copper-plate + 1 iron-gear-wheel; gear = 2 iron-plate) to auto-trigger the first tech, then place a lab and feed it. Past phase 0 do NOT hand-craft red science to "restart" — just queue research.
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


# Fields that are large and rarely decisive. The whole-base view already arrives
# summarised (factory.summary/by_type/attention); the full per-machine roster and a long
# list of scenery are detail the model does not act on.
_TRIM_LISTS = {
    "nearby_entities": 8,
    "nearby_resources": 4,
    "inventory": 20,
    "enemies": 3,
    "nearby_water": 2,
}


def _trim_perception(perception: dict) -> dict:
    """
    Shrink the per-turn payload.

    Latency here is dominated by PREFILL, not generation: the server log showed ~6000
    tokens re-prefilled in 20.3s to produce an 8-token reply, missing the KV cache every
    turn because this half of the prompt changes. The system prompt is stable and stays
    cached, so the only lever is making the changing half smaller.

    Pretty-printing cost about a third of it on its own — indentation and newlines
    tokenise badly — and factory.machines plus a 25-entry scenery list accounted for most
    of the rest.
    """
    trimmed = dict(perception)

    for key, limit in _TRIM_LISTS.items():
        value = trimmed.get(key)
        if isinstance(value, list) and len(value) > limit:
            trimmed[key] = value[:limit]

    factory = trimmed.get("factory")
    if isinstance(factory, dict):
        factory = dict(factory)
        machines = factory.get("machines")
        # The per-machine roster is only useful while the base is tiny; past that the
        # summary and the attention list say the same thing in a fraction of the space.
        if isinstance(machines, list) and len(machines) > 6:
            factory.pop("machines", None)
        attention = factory.get("attention")
        if isinstance(attention, list) and len(attention) > 6:
            factory["attention"] = attention[:6]
        trimmed["factory"] = factory

    needs = trimmed.get("needs")
    if isinstance(needs, dict):
        # needs is routing information: how many machines want each thing, not which.
        trimmed["needs"] = {
            k: (len(v) if isinstance(v, list) else v) for k, v in needs.items()
        }

    return trimmed


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

    machines = perception.get("factory", {}).get("machines") or []

    def placed_on(resource: str) -> int:
        """Drills currently mining `resource`. by_type only counts entity names, and the
        difference between a coal drill and an iron drill is the whole early game."""
        n = 0
        for m in machines:
            if "drill" in str(m.get("name", "")) and resource in str(m.get("mining") or m.get("resource") or ""):
                n += 1
        return n

    drills = placed("burner-mining-drill", "electric-mining-drill")
    furnaces = placed("stone-furnace", "steel-furnace", "electric-furnace")
    labs = placed("lab")

    # 0a. Wandered off. explore teleports a long way, and building where you happen to be
    #     standing means clearing fresh ore in a field when spawn is already clear and is
    #     where the rest of the base is. Go back before building anything.
    home = perception.get("home") or {}
    if int(home.get("distance", 0) or 0) > 80:
        return (
            {"skill": "return_home"},
            "Heading back to base — no point building out here.",
            'you are far from your base. Go back with {"skill":"return_home"} before building '
            'anything: spawn is already clear of ore and is where the rest of your factory is, '
            'so building out here means clearing ground you already have.',
        )

    # 0. A full inventory breaks everything downstream — mining stops yielding, crafting has
    #    nowhere to put output, placement fails for want of a slot — and it does so silently,
    #    so it looks like the other skills are broken. Clear it before anything else.
    free = perception.get("inventory_free_slots")
    if free is not None and int(free) <= 4:
        return (
            {"skill": "deposit_to_chest"},
            "Inventory is full — dumping into a chest before doing anything else.",
            'your inventory is FULL, which silently breaks mining, crafting and building. '
            'Empty it with {"skill":"deposit_to_chest"} before anything else. If there is no '
            'chest, craft and place one on cleared ground first.',
        )

    # 1. COAL first. Everything in the burner age eats coal — the drills, the furnaces, the
    #    inserters — and a coal drill feeds the rest of the base, including itself. Mining
    #    iron first just means hand-feeding coal to the machine that mines it.
    # 1a. Cannot expand without drills to place. They are cheap and made from what the
    #     furnaces are already producing, so make a batch rather than stalling.
    if drills < 20 and have("burner-mining-drill") == 0 and have("iron-plate") >= 12:
        return (
            {"skill": "craft", "recipe": "burner-mining-drill", "count": 4},
            "Crafting more drills — can't expand mining without them.",
            'craft drills: {"skill":"craft","recipe":"burner-mining-drill","count":4}. You have '
            'no drills to place and a base this small needs many more. Each is 3 iron-gear-wheel '
            '+ 3 iron-plate + 1 stone-furnace, all of which you can make from plates.',
        )

    if placed_on("coal") < 6 and have("burner-mining-drill") >= 4:
        return (
            {"skill": "build_mine_line", "resource": "coal", "count": 6},
            "Building a row of coal drills — everything burns coal.",
            'build a coal ROW first: {"skill":"build_mine_line","resource":"coal","count":6}. '
            'Every burner machine you own eats coal, so you need MORE drills on coal than on '
            'anything else — a base that cannot fuel itself simply stops.',
        )

    if placed_on("coal") == 0 and have("burner-mining-drill") > 0:
        return (
            {"skill": "build_miner", "resource": "coal", "output": "chest"},
            "Mining coal first — every burner machine runs on it, including the drills.",
            'put a drill on COAL first: {"skill":"build_miner","resource":"coal","output":"chest"}. '
            'Coal fuels every burner machine you own, so a coal mine feeds the rest of the base '
            'and itself. Iron can wait one turn.',
        )

    # 2. Then iron, in quantity. One drill is not a base: a working factory wants roughly
    #    twenty drills on iron, a handful on copper, and MORE than that on coal, because
    #    every burner machine eats coal and a base that cannot fuel itself stops.
    if drills < 20 and have("burner-mining-drill") >= 4:
        return (
            {"skill": "build_mine_line", "resource": "iron-ore", "count": 6},
            "Building a row of iron drills onto a shared belt.",
            'build a ROW, not one drill: {"skill":"build_mine_line","resource":"iron-ore",'
            '"count":6}. You want roughly twenty drills on iron before this base is fed. '
            'The belt carries the ore off the patch to a furnace on cleared ground.',
        )

    if drills < 2 and have("burner-mining-drill") > 0:
        return (
            {"skill": "build_miner", "resource": "iron-ore", "output": "furnace"},
            "Adding an iron mine feeding a furnace — the standard opening pair.",
            'now mine iron, feeding a furnace directly: '
            '{"skill":"build_miner","resource":"iron-ore","output":"furnace"}. That drill+furnace '
            'pair is the whole early loop. A burner drill needs NO electricity.',
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

    # 2b. A built base that is idle is worth nothing. This outranks building anything new:
    #     twelve furnaces at "no_ingredients" with 933 ore in the character's pockets
    #     produce exactly as much as no furnaces at all.
    needs = perception.get("needs") or {}

    def need_count(key: str) -> int:
        v = needs.get(key)
        return len(v) if isinstance(v, list) else int(v or 0)

    idle_inputs = need_count("machines_no_input")
    low_fuel = need_count("burners_low_fuel")
    ore_on_hand = have("iron-ore") + have("copper-ore") + have("stone")

    if (idle_inputs > 0 and ore_on_hand > 0) or (low_fuel > 0 and have("coal") > 0):
        return (
            {"skill": "run_base"},
            f"Feeding the base — {idle_inputs} machine(s) idle, {low_fuel} out of fuel.",
            f'run your existing base first: {{"skill":"run_base"}}. {idle_inputs} machine(s) have '
            f'no input and {low_fuel} burner(s) are out of fuel, while you are carrying the ore '
            'and coal they need. Idle machines produce nothing, so this beats building more.',
        )

    # 2c. Out of coal with burners starving: everything in the burner age stops without it.
    if low_fuel > 0 and have("coal") == 0:
        return (
            {"skill": "gather", "item": "coal", "count": 100},
            "Mining coal — the burners have run dry.",
            'mine coal: {"skill":"gather","item":"coal","count":100}. Burners are out of fuel and '
            'you have none. Every drill and furnace you own stops without it.',
        )

    # 3. Keep the furnaces fed rather than idling.
    if furnaces > 0 and have("iron-ore") == 0 and have("iron-plate") < 30:
        return (
            {"skill": "gather", "item": "iron-ore", "count": 60},
            "Gathering iron ore — the furnaces have nothing to smelt.",
            'gather ore to feed your furnaces: {"skill":"gather","item":"iron-ore","count":60}.',
        )

    # 4. Research. Two very different cases, and confusing them wastes every turn:
    #    a queueable tech just needs queuing, but a 2.0 TRIGGER tech is unlocked by doing
    #    the thing — and early on there may be nothing queueable at all.
    if not research.get("current"):
        queueable = int(research.get("queueable", 0) or 0)
        trigger_do = research.get("trigger_do") or ""
        if queueable > 0 and (labs > 0 or have("automation-science-pack") > 0):
            return (
                {"skill": "research"},
                "Queuing research — I have lab capacity but nothing is being researched.",
                'queue a technology with {"skill":"research"} — you have lab capacity but '
                'nothing is being researched, so no progress is being made.',
            )
        if trigger_do.startswith("craft:"):
            item = trigger_do.split(":", 1)[1]
            ore = {"copper-plate": "copper-ore", "iron-plate": "iron-ore"}.get(item)
            if not ore:
                # Any other trigger item is just something to build: ask for it directly and
                # let craft report the exact shortfall if the ingredients are not there.
                return (
                    {"skill": "craft", "recipe": item, "count": 1},
                    f"Crafting a {item} — that unlocks the next technology.",
                    f'craft it: {{"skill":"craft","recipe":"{item}","count":1}}. Nothing is '
                    f'queueable — the next technology ({research.get("trigger")}) unlocks by '
                    f'CRAFTING {item}. If you lack the ingredients, craft will say exactly '
                    'which, and you make those first.',
                )
            if ore:
                if have(ore) == 0:
                    return (
                        {"skill": "gather", "item": ore, "count": 50},
                        f"Mining {ore} — smelting it is what unlocks the next technology.",
                        f'mine {ore} with {{"skill":"gather","item":"{ore}","count":50}}. Nothing '
                        f'is queueable: the next technology ({research.get("trigger")}) unlocks by '
                        f'CRAFTING {item}, and {item} is made by smelting {ore} in a furnace.',
                    )
                return (
                    {"skill": "build_smelter", "ore": ore, "count": 2},
                    f"Smelting {ore} — that unlocks the next technology.",
                    f'smelt it with {{"skill":"build_smelter","ore":"{ore}","count":2}}. Nothing is '
                    f'queueable: {research.get("trigger")} unlocks by CRAFTING {item}, which means '
                    f'producing it in a furnace. Queuing research cannot help.',
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


def build_messages(payload: dict, system_prefix: str = "", goal_note: str | None = None) -> list[dict]:
    system = SYSTEM_PROMPT
    if system_prefix:
        system = system_prefix.strip() + "\n\n" + system

    parts: list[str] = []
    perception = payload.get("perception") or {}
    if perception:
        parts.append("Game state:\n" + json.dumps(_trim_perception(perception),
                                                   separators=(",", ":")))
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

    if goal_note:
        parts.append(goal_note)

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

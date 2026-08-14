"""
Skill catalogue as OpenAI tool definitions.

The skills were always the tool layer; they were just invoked by the model writing JSON
into free text, which needed two hand-rolled parsers to survive — a multi-strategy one
here (fenced blocks, balanced-bracket scanning, <think> stripping) and a regex JSON matcher
in Lua, because Lua has no JSON at runtime. Declaring them as tools moves schema
enforcement to the server, where a malformed call cannot happen in the first place.

Parameter schemas live here rather than in api.SKILLS because SKILLS only records which
params are REQUIRED; a tool definition also needs types and descriptions. api.SKILLS stays
the validation authority for the text path, and test_tools_match_skills keeps the two in
step.
"""

from .factorio.api import SKILLS

# name -> (description, {param: (json_type, description, required)})
_SPEC: dict[str, tuple[str, dict]] = {
    "build_ghosts": ("Build every ghost the human placed. Highest priority when ghosts exist.", {}),
    "deconstruct": ("Mine everything the human marked for deconstruction.", {}),
    "gather": ("Hand-mine the nearest sources until you hold `count` of an item.", {
        "item": ("string", "What to mine, e.g. coal, iron-ore, copper-ore, stone, wood", True),
        "count": ("integer", "How many to end up holding (default 50)", False),
    }),
    "build_miner": ("Place ONE burner drill on a resource with a collector at its output.", {
        "resource": ("string", "Ore to mine, e.g. iron-ore, coal", False),
        "output": ("string", "Where output goes: chest, furnace or belt", False),
    }),
    "build_mine_line": ("Place a ROW of drills sharing one belt, carried off the ore to a "
                        "furnace on clear ground. Prefer this over build_miner for real "
                        "throughput.", {
        "resource": ("string", "Ore to mine, e.g. iron-ore, coal, copper-ore", False),
        "count": ("integer", "How many drills in the row (1-20)", False),
    }),
    "build_smelter": ("Place stone furnaces on clear ground and load them with ore.", {
        "ore": ("string", "Ore to smelt, e.g. iron-ore", False),
        "count": ("integer", "How many furnaces", False),
    }),
    "run_base": ("Refuel every burner and reload every empty furnace from your inventory. "
                 "Use whenever machines are idle — an idle machine produces nothing.", {}),
    "fuel_all": ("Top up nearby burners that are low on coal.", {}),
    "loot_chests": ("Take the contents of nearby chests into your inventory.", {}),
    "deposit_to_chest": ("Empty your inventory into nearby chests. Use when full.", {
        "keep": ("integer", "How many of each item to keep (default 50)", False),
    }),
    "craft": ("Hand-craft a recipe, reporting exactly which ingredient is short if it "
              "cannot be made.", {
        "recipe": ("string", "Recipe name, e.g. burner-mining-drill, iron-chest, lab", True),
        "count": ("integer", "How many (default 1)", False),
    }),
    "clear_area": ("Mine the trees, rocks and ORE around you to make buildable ground. On an "
                   "ore-covered map this is how you create somewhere to build.", {
        "radius": ("integer", "Tiles to clear around you (4-32)", False),
    }),
    "explore": ("Travel outward to reveal new ground and report the ore found there.", {
        "direction": ("string", "north, south, east, west or a diagonal", False),
        "distance": ("integer", "How far to travel (32-512)", False),
    }),
    "build_power": ("Build the whole steam starter: offshore pump, boiler, steam engines "
                    "and a pole. Only worth doing once something electric is starved.", {
        "count": ("integer", "How many steam engines", False),
    }),
    "build_lab": ("Place labs on clear ground and load any science packs you carry.", {
        "count": ("integer", "How many labs", False),
    }),
    "research": ("Queue a technology. Does nothing when research.queueable is 0 — those "
                 "technologies unlock by crafting or mining instead.", {
        "tech": ("string", "Technology name; omit to pick automatically", False),
    }),
    "return_home": ("Walk back to the base anchor. Build at home, not where you wandered to.", {}),
    "goto": ("Teleport to a map coordinate.", {
        "position": ("object", "Target as {\"x\": N, \"y\": N}", True),
    }),
}


def skill_tools() -> list[dict]:
    """The skill set as OpenAI tool definitions."""
    tools = []
    for name in sorted(SKILLS):
        description, params = _SPEC.get(name, (f"Run the {name} skill.", {}))
        properties, required = {}, []
        for param, (ptype, pdesc, is_required) in params.items():
            properties[param] = {"type": ptype, "description": pdesc}
            if is_required:
                required.append(param)
        tools.append({
            "type": "function",
            "function": {
                "name": name,
                "description": description,
                "parameters": {
                    "type": "object",
                    "properties": properties,
                    "required": required,
                },
            },
        })
    return tools


def undocumented_skills() -> list[str]:
    """Skills with no tool spec — they would reach the model as a bare name."""
    return sorted(set(SKILLS) - set(_SPEC))

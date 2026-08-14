-- Skill layer (v3).
--
-- A "skill" is a parameterized basic loop. Skills own the deterministic MECHANICS
-- (positions, orientation, fuelling, drop-positions); the LLM only chooses which
-- skill and its params. Skills orchestrate the proven PRIMITIVE handlers
-- (AIActions.run) wherever possible, so placement legality / slot resolution /
-- mining all stay in one place (primitives.lua).
--
-- Each skill: function(character, params) -> (ok:boolean, detail:string)
-- detail feeds the E1 result loop, so make it specific and actionable.

AISkills = {}

local function inv_of(character)
  return character.get_inventory(defines.inventory.character_main)
end

-- Find a spot for `proto` that is both physically free AND clear of ore.
--
-- find_non_colliding_position alone is not enough on a Danger Ores map: ore entities have
-- no collision box, so it happily returns a tile buried in iron. The scenario then destroys
-- whatever is built there, because those maps allow only belts, drills and power poles on
-- ore — the building silently vanishes and the skill looks like it worked.
--
-- Falls back to the plain non-colliding position when nothing ore-free is within range, so
-- ordinary maps behave exactly as before.
local function find_clear_position(surface, proto, anchor, radius)
  local fallback = surface.find_non_colliding_position(proto, anchor, radius, 1)
  for r = 0, radius, 2 do
    for _, off in ipairs({{r, 0}, {-r, 0}, {0, r}, {0, -r}, {r, r}, {-r, -r}, {r, -r}, {-r, r}}) do
      local probe = {x = anchor.x + off[1], y = anchor.y + off[2]}
      local pos = surface.find_non_colliding_position(proto, probe, 3, 1)
      if pos then
        local box = prototypes.entity[proto] and prototypes.entity[proto].selection_box
        local area = box
          and {{pos.x + box.left_top.x, pos.y + box.left_top.y},
               {pos.x + box.right_bottom.x, pos.y + box.right_bottom.y}}
          or {{pos.x - 0.5, pos.y - 0.5}, {pos.x + 0.5, pos.y + 0.5}}
        if #surface.find_entities_filtered{area = area, type = "resource"} == 0 then
          return pos, true
        end
      end
    end
  end
  return fallback, false
end

-- -------------------------------------------------------------------------
-- gather(item, count) — mine the nearest sources of `item` until `count`.
-- Handles wood (mine trees by type) and ores/rocks (mine by name).
-- -------------------------------------------------------------------------
local function skill_gather(character, p)
  local item = p.item
  if not item then return false, "gather: missing 'item'" end
  local need = math.min(p.count or 50, 300)
  local surface = character.surface
  local inv = inv_of(character)
  local is_wood = (item == "wood")
  local gained = 0

  for _ = 1, 150 do
    if inv.get_item_count(item) >= need then break end
    local filter = {position = character.position, radius = 40, limit = 60}
    if is_wood then filter.type = "tree" else filter.name = item end
    local sources = surface.find_entities_filtered(filter)
    local src, sd = nil, math.huge
    for _, e in ipairs(sources) do
      if e.valid and e.minable and e ~= character then
        local dx, dy = e.position.x - character.position.x, e.position.y - character.position.y
        local d = dx * dx + dy * dy
        if d < sd then sd = d; src = e end
      end
    end
    if not src then break end
    -- Teleport adjacent so the source is within mining reach, then mine.
    local sp = surface.find_non_colliding_position("character", src.position, 3, 0.5)
    if sp then character.teleport(sp) end
    local before = inv.get_item_count()
    character.mine_entity(src, true)
    local delta = inv.get_item_count() - before
    if delta <= 0 then break end  -- inventory full or stuck
    gained = gained + delta
  end

  local have = inv.get_item_count(item)
  if gained == 0 then
    return false, "gather: no reachable " .. item .. " sources within 40 tiles"
  end
  return true, string.format("gathered %d %s (now have %d)", gained, item, have)
end

-- -------------------------------------------------------------------------
-- build_smelter(ore, count) — place stone-furnaces, fuel them, feed ore.
-- Orchestrates the place + insert primitives at computed positions.
-- -------------------------------------------------------------------------
local function skill_build_smelter(character, p)
  local ore = p.ore or p.item or "iron-ore"
  local want = math.min(p.count or 2, 6)
  local surface = character.surface
  local inv = inv_of(character)

  local have_furnace = inv.get_item_count("stone-furnace")
  if have_furnace == 0 then
    local queued = character.begin_crafting{recipe = "stone-furnace", count = 1}
    if queued > 0 then
      return false, "build_smelter: out of stone-furnaces — hand-crafting one, retry next turn"
    end
    return false, "build_smelter: no stone-furnace and can't craft one (need stone)"
  end

  local count = math.min(want, have_furnace)
  local base = character.position
  local placed = 0
  for i = 1, count do
    local anchor = {x = base.x + i * 2, y = base.y - 1}
    local pos, clear = find_clear_position(surface, "stone-furnace", anchor, 12)
    if pos and not clear then
      -- Every nearby spot is on ore; a furnace there would be destroyed by the map rule.
      return false, "build_smelter: no ore-free ground within 12 tiles — furnaces cannot be " ..
                    "built on ore on this map. Run {\"skill\":\"clear_area\",\"radius\":8} to mine " ..
                    "the ore away, then retry."
    end
    if pos then
      local ok = AIActions.run(character, {action = "place", item = "stone-furnace", position = pos})
      if ok then
        placed = placed + 1
        if inv.get_item_count("coal") > 0 then
          AIActions.run(character, {action = "insert", item = "coal", count = 8, position = pos, inventory = "fuel"})
        end
        if inv.get_item_count(ore) > 0 then
          AIActions.run(character, {action = "insert", item = ore, count = 12, position = pos, inventory = "input"})
        end
      end
    end
  end

  if placed == 0 then
    return false, "build_smelter: couldn't place any furnace (no clear space nearby)"
  end
  local detail = string.format("built %d stone-furnace(s) for %s", placed, ore)
  if inv.get_item_count(ore) == 0 then
    detail = detail .. " — but you have no " .. ore .. " to smelt; gather " .. ore .. " first"
  end
  return true, detail
end

-- -------------------------------------------------------------------------
-- build_miner(resource, output) — place a burner-mining-drill ON the nearest
-- resource patch, fuel it, and place a collector (chest/furnace/belt) at its
-- drop_position. The drill→output basic loop.
-- -------------------------------------------------------------------------
local OUTPUT_ITEM = {chest = "iron-chest", furnace = "stone-furnace", belt = "transport-belt"}

local function skill_build_miner(character, p)
  local resource = p.resource or p.item or "iron-ore"
  local out_kind = (p.output or "chest"):lower()
  local out_item = OUTPUT_ITEM[out_kind] or "iron-chest"
  local surface = character.surface
  local inv = inv_of(character)

  if inv.get_item_count("burner-mining-drill") == 0 then
    character.begin_crafting{recipe = "burner-mining-drill", count = 1}
    return false, "build_miner: no burner-mining-drill in inventory — crafting one, retry next turn"
  end

  -- Nearest tile of the resource that no drill already covers. Without the occupancy
  -- test every call picks the same nearest tile, so repeated build_miner turns pile
  -- drills onto one spot instead of spreading across the patch.
  local occupied = {}
  for _, d in ipairs(surface.find_entities_filtered{type = "mining-drill",
                                                    position = character.position, radius = 80}) do
    local b = d.bounding_box
    occupied[#occupied + 1] = b
  end
  local function covered(pos)
    for _, b in ipairs(occupied) do
      if pos.x >= b.left_top.x - 0.5 and pos.x <= b.right_bottom.x + 0.5
         and pos.y >= b.left_top.y - 0.5 and pos.y <= b.right_bottom.y + 0.5 then
        return true
      end
    end
    return false
  end

  -- Candidate tiles in distance order. Trying only the single nearest tile is what
  -- wedged this skill in play: leftover collector chests from an earlier mine sat next
  -- to the closest ore, so placement failed there every single turn while thousands of
  -- free tiles waited a few metres away.
  local candidates = {}
  local skipped = 0
  for _, e in ipairs(surface.find_entities_filtered{name = resource, type = "resource",
                                                    position = character.position, radius = 64}) do
    if covered(e.position) then
      skipped = skipped + 1
    else
      local dx, dy = e.position.x - character.position.x, e.position.y - character.position.y
      candidates[#candidates + 1] = {pos = e.position, d = dx * dx + dy * dy}
    end
  end
  table.sort(candidates, function(a, b) return a.d < b.d end)

  if #candidates == 0 then
    if skipped > 0 then
      return false, string.format(
        "build_miner: every '%s' tile within 64 tiles is already under a drill (%d checked) " ..
        "— explore for a new patch, or build something else", resource, skipped)
    end
    return false, "build_miner: no '" .. resource .. "' patch within 64 tiles — gather/explore first"
  end

  -- Do NOT teleport onto the patch first: ore has no collision box, so
  -- find_non_colliding_position returns the patch tile itself and the character
  -- ends up standing on it — then can_place(manual) fails and the drill can't be
  -- placed. place/insert here all use explicit positions (find_entity searches
  -- around action.position, not the character), so no character reach is needed.

  -- Place the drill (the place primitive enforces drill-on-resource). Walk the candidate
  -- tiles until one takes it, and keep the primitive's own reason for the last failure:
  -- "(blocked?)" told the model nothing it could act on, so it simply retried forever.
  local drill, last_error
  for i = 1, math.min(#candidates, 24) do
    local pos = candidates[i].pos
    for _, dir in ipairs({"south", "north", "east", "west"}) do
      local ok, detail = AIActions.run(character, {action = "place", item = "burner-mining-drill",
                                                   position = pos, direction = dir})
      if ok then
        drill = surface.find_entities_filtered{name = "burner-mining-drill",
                                               position = pos, radius = 2}[1]
        if drill then break end
      else
        last_error = detail or last_error
      end
    end
    if drill then break end
  end
  if not drill then
    return false, string.format(
      "build_miner: no room for a drill on the nearest %d '%s' tiles — last reason: %s. " ..
      "Try clear_area, or explore for a different patch.",
      math.min(#candidates, 24), resource, last_error or "unknown")
  end

  -- fuel the drill
  AIActions.run(character, {action = "insert", item = "coal", count = 5,
                            position = drill.position, inventory = "fuel"})

  -- Aim the drill before choosing a collector. Placement used to take the first
  -- direction that happened to fit, which is always "south", so every drill faced the
  -- same way and dropped its ore wherever that landed — often onto more ore, where a
  -- chest cannot go.
  --
  -- That matters beyond tidiness on an ore-covered map. Danger Ores scenarios allow only
  -- belts, drills and power poles on ore tiles and destroy anything else placed there, so
  -- a chest on the drop tile is not merely blocked, it is against the rules of the map.
  -- Rotate to a facing whose drop tile is clear of ore, and fall back to a belt (always
  -- legal on ore) when every facing drops onto the patch.
  local function ore_at(pos)
    return #surface.find_entities_filtered{position = pos, radius = 0.4, type = "resource"} > 0
  end

  local ALL_DIRS = {defines.direction.north, defines.direction.east,
                    defines.direction.south, defines.direction.west}
  local chosen_drop, on_ore = nil, false
  for _, dir in ipairs(ALL_DIRS) do
    drill.direction = dir
    local d = drill.drop_position
    if not ore_at(d) then
      chosen_drop = d
      break
    end
    chosen_drop = chosen_drop or d   -- remember one, in case every facing is on ore
    on_ore = true
  end
  if chosen_drop and not ore_at(chosen_drop) then on_ore = false end

  local drop = chosen_drop or drill.drop_position
  local detail = "placed burner-mining-drill on " .. resource

  -- On ore, only a belt is legal; elsewhere use what was asked for.
  local collector = on_ore and "transport-belt" or out_item
  if on_ore then
    detail = detail .. " (every facing drops onto ore, so using a belt — chests are not"
                    .. " allowed on ore here)"
  end

  if inv.get_item_count(collector) == 0 and collector == "iron-chest" then
    -- 8 iron plates; cheap enough to just make one rather than fail the whole loop.
    if character.begin_crafting{recipe = "iron-chest", count = 1} > 0 then
      detail = detail .. " — out of iron-chest, crafting one; re-run to attach it"
      return true, detail
    end
  end

  if inv.get_item_count(collector) > 0 then
    if AIActions.run(character, {action = "place", item = collector, position = drop}) then
      detail = detail .. " + " .. collector .. " at its drop position"
      if collector == "stone-furnace" and inv.get_item_count("coal") > 0 then
        AIActions.run(character, {action = "insert", item = "coal", count = 5,
                                  position = drop, inventory = "fuel"})
      end
    else
      detail = detail .. string.format(" (couldn't place %s at drop {%d,%d})",
        collector, math.floor(drop.x), math.floor(drop.y))
    end
  else
    detail = detail .. string.format(" — no %s to collect output; place one at {%d,%d}",
      collector, math.floor(drop.x), math.floor(drop.y))
  end
  return true, detail
end

-- -------------------------------------------------------------------------
-- fuel_all() — top up every nearby AI-force burner that's low on fuel.
-- -------------------------------------------------------------------------
local function skill_fuel_all(character, _)
  local surface = character.surface
  local inv = inv_of(character)
  if inv.get_item_count("coal") == 0 then
    return false, "fuel_all: no coal in inventory"
  end
  local force = AICharacter.get_force()
  local fueled = 0
  for _, e in ipairs(surface.find_entities_filtered{force = force, position = character.position, radius = 64}) do
    if e.valid and e.type ~= "character" then
      local fb = e.get_fuel_inventory and e.get_fuel_inventory()
      if fb and fb.valid and fb.get_item_count("coal") < 5 then
        local avail = inv.get_item_count("coal")
        if avail > 0 then
          local ins = fb.insert{name = "coal", count = math.min(5, avail)}
          if ins > 0 then inv.remove{name = "coal", count = ins}; fueled = fueled + 1 end
        end
      end
    end
  end
  if fueled == 0 then return false, "fuel_all: nothing nearby needed fuel" end
  return true, string.format("fueled %d burner(s)", fueled)
end

-- -------------------------------------------------------------------------
-- loot_chests(radius?, items?) — pull items from nearby chests (any force)
-- into the character's inventory. Enables human→AI resource sharing (coal,
-- building materials, etc.) and AI self-restocking before build_ghosts.
-- items: comma-separated item names to restrict looting; empty = take all.
-- -------------------------------------------------------------------------
local function skill_loot_chests(character, p)
  local surface = character.surface
  local radius  = math.min(p.radius or 32, 128)
  local inv     = inv_of(character)

  local filter = nil
  if p.items and p.items ~= "" then
    filter = {}
    for name in p.items:gmatch("[^,]+") do
      filter[name:match("^%s*(.-)%s*$")] = true
    end
  end

  local chests = surface.find_entities_filtered{
    type = {"container", "logistic-container"},
    position = character.position, radius = radius,
  }
  if #chests == 0 then
    return false, "loot_chests: no chests within " .. radius .. " tiles"
  end

  local taken = {}
  for _, chest in ipairs(chests) do
    if chest.valid then
      local ci = chest.get_inventory(defines.inventory.chest)
      if ci then
        for _, slot in ipairs(ci.get_contents()) do
          local name, avail = slot.name, slot.count
          if not filter or filter[name] then
            local n = inv.insert{name = name, count = avail}
            if n > 0 then
              ci.remove{name = name, count = n}
              taken[name] = (taken[name] or 0) + n
            end
          end
        end
      end
    end
  end

  if not next(taken) then
    return false, "loot_chests: nothing taken (chests empty, inventory full, or filter matched nothing)"
  end
  local parts = {}
  for name, count in pairs(taken) do parts[#parts + 1] = count .. "x " .. name end
  table.sort(parts)
  return true, "looted " .. table.concat(parts, ", ")
end

-- -------------------------------------------------------------------------
-- deposit_to_chest(radius?, keep?) — deposit excess inventory into a nearby
-- chest. Keeps `keep` of each item; deposits the rest. Use for inventory
-- management and AI→human resource sharing.
-- -------------------------------------------------------------------------
local function skill_deposit_to_chest(character, p)
  local surface = character.surface
  local radius  = math.min(p.radius or 32, 128)
  local keep    = math.max(p.keep or 50, 0)
  local inv     = inv_of(character)

  local chests = surface.find_entities_filtered{
    type = {"container", "logistic-container"},
    position = character.position, radius = radius,
  }
  if #chests == 0 then
    return false, "deposit_to_chest: no chests within " .. radius .. " tiles"
  end

  local cp = character.position
  table.sort(chests, function(a, b)
    local da = (a.position.x - cp.x)^2 + (a.position.y - cp.y)^2
    local db = (b.position.x - cp.x)^2 + (b.position.y - cp.y)^2
    return da < db
  end)

  local deposited = {}
  for _, slot in ipairs(inv.get_contents()) do
    local name, have = slot.name, slot.count
    local excess = have - keep
    if excess > 0 then
      for _, chest in ipairs(chests) do
        if chest.valid then
          local ci = chest.get_inventory(defines.inventory.chest)
          if ci then
            local n = ci.insert{name = name, count = excess}
            if n > 0 then
              inv.remove{name = name, count = n}
              deposited[name] = (deposited[name] or 0) + n
              excess = excess - n
            end
          end
        end
        if excess <= 0 then break end
      end
    end
  end

  if not next(deposited) then
    return false, "deposit_to_chest: nothing deposited (nothing exceeds keep=" .. keep .. " or chests full)"
  end
  local parts = {}
  for name, count in pairs(deposited) do parts[#parts + 1] = count .. "x " .. name end
  table.sort(parts)
  return true, "deposited " .. table.concat(parts, ", ")
end

-- -------------------------------------------------------------------------
-- build_ghosts() — build the human's placed entity-ghosts (validated mechanic).
-- Highest-priority skill: ghosts are explicit human intent.
-- -------------------------------------------------------------------------
local function skill_build_ghosts(character, _)
  local surface = character.surface
  local inv = inv_of(character)
  -- Search the ENTIRE surface — ghosts may be far from the character's current
  -- position (e.g. an oil outpost blueprinted 200+ tiles away). We teleport to
  -- the nearest ghost cluster before attempting revive.
  local ghosts = surface.find_entities_filtered{type = "entity-ghost"}
  if #ghosts == 0 then return false, "build_ghosts: no ghosts on surface to build" end

  -- Find nearest ghost so we can teleport to it.
  local nearest, nd = nil, math.huge
  for _, g in ipairs(ghosts) do
    if g.valid then
      local dx = g.position.x - character.position.x
      local dy = g.position.y - character.position.y
      local d = dx * dx + dy * dy
      if d < nd then nd = d; nearest = g end
    end
  end
  if nearest then
    -- Teleport to a spot near the nearest ghost cluster so revive() can fire.
    local tp = surface.find_non_colliding_position(
      "character", {x = nearest.position.x + 3, y = nearest.position.y + 3}, 12, 0.5)
    if tp then character.teleport(tp) end
  end

  local built = 0
  local missing = {}
  for _, g in ipairs(ghosts) do
    if g.valid then
      local proto = prototypes.entity[g.ghost_name]
      local item = proto and proto.items_to_place_this and proto.items_to_place_this[1]
        and proto.items_to_place_this[1].name
      if item and inv.get_item_count(item) > 0 then
        -- NB: do NOT teleport the character to the ghost first. Ghosts have no
        -- collision box, so find_non_colliding_position returns the ghost's own
        -- tile; teleporting there makes the CHARACTER block the spot and revive()
        -- fails. revive() is a force-level op and needs no character reach.
        local _, ent = g.revive{raise_revive = false}
        if not (ent and ent.valid) then
          -- The character may be standing ON this ghost (e.g. its home tile).
          -- Step aside to a spot clear of the ghost footprint and retry once.
          local aside = surface.find_non_colliding_position(
            "character", {x = g.position.x + 3, y = g.position.y + 3}, 8, 0.5)
          if aside then
            character.teleport(aside)
            _, ent = g.revive{raise_revive = false}
          end
        end
        if ent and ent.valid then
          inv.remove{name = item, count = 1}
          built = built + 1
        end
      elseif item then
        missing[item] = (missing[item] or 0) + 1
      end
    end
  end

  local parts = {}
  for it, c in pairs(missing) do parts[#parts + 1] = c .. "x " .. it end
  local detail = string.format("built %d ghost(s)", built)
  if #parts > 0 then detail = detail .. "; need items: " .. table.concat(parts, ", ") end
  if built == 0 and #parts == 0 then return false, "build_ghosts: no buildable ghosts" end
  return true, detail
end

-- -------------------------------------------------------------------------
-- deconstruct() — mine everything the human marked for deconstruction
-- (buildings, trees, rocks). SECOND priority after build_ghosts: a
-- deconstruction mark is explicit human "remove this" intent, the mirror of a
-- ghost. Unlike ghosts/ore, these targets HAVE collision, so teleporting
-- adjacent (the gather pattern) is safe — find_non_colliding_position lands the
-- character beside the target, not on it, and mine_entity collects the products.
-- -------------------------------------------------------------------------
local function skill_deconstruct(character, p)
  local surface = character.surface
  local inv = inv_of(character)
  local radius = math.min(p.radius or 96, 200)
  local marked = surface.find_entities_filtered{
    to_be_deconstructed = true, position = character.position, radius = radius, limit = 100}
  if #marked == 0 then
    return false, "deconstruct: nothing marked for deconstruction within " .. radius .. " tiles"
  end

  -- Nearest-first so the character walks an efficient path and stays near base.
  local cp = character.position
  table.sort(marked, function(a, b)
    local dax, day = a.position.x - cp.x, a.position.y - cp.y
    local dbx, dby = b.position.x - cp.x, b.position.y - cp.y
    return (dax * dax + day * day) < (dbx * dbx + dby * dby)
  end)

  local removed, skipped = 0, 0
  for _, m in ipairs(marked) do
    if m.valid and m ~= character then
      if not m.minable then
        skipped = skipped + 1
      else
        local sp = surface.find_non_colliding_position("character", m.position, 3, 0.5)
        if sp then character.teleport(sp) end
        local ok = character.mine_entity(m, true)
        if ok and not m.valid then
          removed = removed + 1
        elseif m.valid then
          break  -- inventory full or out of reach — stop rather than spin
        end
      end
    end
  end

  if removed == 0 then
    if skipped > 0 then return false, "deconstruct: marked objects can't be mined (unminable)" end
    return false, "deconstruct: couldn't mine any marked object (inventory full?)"
  end
  local detail = string.format("deconstructed %d marked object(s)", removed)
  if skipped > 0 then detail = detail .. string.format("; %d unminable skipped", skipped) end
  return true, detail
end

-- -------------------------------------------------------------------------
-- return_home() — walk back to the home anchor.
-- -------------------------------------------------------------------------
local function skill_return_home(character, _)
  local home = storage.ai_player and storage.ai_player.home_position
  if not home then return false, "return_home: no home anchor set" end
  local surface = character.surface
  local sp = surface.find_non_colliding_position("character", {x = home.x, y = home.y}, 8, 0.5)
  if not sp then return false, "return_home: home area is blocked" end
  character.teleport(sp)
  return true, string.format("returned home to {%d,%d}", home.x, home.y)
end

-- -------------------------------------------------------------------------
-- research(tech?) — queue a technology on the AI force. WITHOUT this, a fed
-- lab does nothing: a separate force researches nothing unless something is
-- queued. Picks a sensible next tech if none is given.
-- -------------------------------------------------------------------------
local PREFERRED_TECH = {
  "automation", "electronics", "steel-processing", "logistics",
  "fast-inserter", "logistic-science-pack",
}

local function prereqs_met(tech)
  for _, pre in pairs(tech.prerequisites) do
    if not pre.researched then return false end
  end
  return true
end

-- A tech is QUEUEABLE only if it isn't a research_trigger tech (those are
-- completed by crafting/doing something, not by add_research) and add_research
-- actually accepts it. Returns true on success (it queues as a side effect).
local function try_queue(force, tech)
  if not (tech and tech.enabled and not tech.researched and prereqs_met(tech)) then return false end
  if tech.prototype.research_trigger ~= nil then return false end
  return force.add_research(tech)
end

local function skill_research(character, p)
  local force = character.force

  if p.tech then
    if try_queue(force, force.technologies[p.tech]) then
      return true, "queued research: " .. p.tech .. " — feed a lab with science packs to progress"
    end
  end
  for _, name in ipairs(PREFERRED_TECH) do
    if try_queue(force, force.technologies[name]) then
      return true, "queued research: " .. name .. " — feed a lab with science packs to progress"
    end
  end
  for _, t in pairs(force.technologies) do
    if try_queue(force, t) then
      return true, "queued research: " .. t.name .. " — feed a lab with science packs to progress"
    end
  end

  -- Nothing queueable. In Factorio 2.0 the early tree is unlocked by DOING things, not by
  -- queuing them: a trigger technology fires when its item is crafted or its entity mined.
  -- Report the exact trigger rather than a guessed recipe — the old message named a recipe
  -- that does not even match this game, and told the model to hand-craft a plate, which is
  -- impossible since plates are smelted.
  local triggers = {}
  for _, t in pairs(force.technologies) do
    if t.enabled and not t.researched and prereqs_met(t) then
      local rt = t.prototype.research_trigger
      if rt then
        local what
        if rt.item then
          what = "craft " .. (type(rt.item) == "table" and rt.item.name or tostring(rt.item))
        elseif rt.entity then
          what = "mine " .. (type(rt.entity) == "table" and rt.entity.name or tostring(rt.entity))
        elseif rt.fluid then
          what = "produce " .. (type(rt.fluid) == "table" and rt.fluid.name or tostring(rt.fluid))
        else
          what = tostring(rt.type)
        end
        triggers[#triggers + 1] = t.name .. " (" .. what .. ")"
      end
    end
  end

  if #triggers > 0 then
    return false, "research: there is NOTHING to queue — every available technology is a 2.0 " ..
      "trigger tech, unlocked by doing the thing rather than by research. Do one of: " ..
      table.concat(triggers, ", ", 1, math.min(#triggers, 4)) ..
      ". Plates are made in a FURNACE, so build_smelter is usually the move; queuing cannot help here."
  end
  return false, "research: nothing to queue right now"
end

-- -------------------------------------------------------------------------
-- goto(position) — teleport the character to an arbitrary map coordinate.
-- Use when you need to reach a location before performing other actions
-- (e.g. inspecting a distant outpost or approaching a ghost cluster manually).
-- -------------------------------------------------------------------------
local function skill_goto(character, p)
  local pos = p.position
  if not pos or pos.x == nil or pos.y == nil then
    return false, "goto: 'position' must be {x=N, y=N}"
  end
  local surface = character.surface
  local target = {x = tonumber(pos.x), y = tonumber(pos.y)}
  local safe = surface.find_non_colliding_position("character", target, 5, 0.5) or target
  character.teleport(safe)
  return true, string.format("moved to (%.0f, %.0f)", safe.x, safe.y)
end

-- -------------------------------------------------------------------------
-- craft(recipe, count) — hand-craft, reporting what is actually missing.
-- The craft primitive queues and returns; this checks feasibility first so a
-- failure says which ingredient is short instead of silently queueing nothing.
-- Factorio hand-crafting auto-queues intermediates, so get_craftable_count is
-- the honest measure of what can be made from the raw items on hand.
-- -------------------------------------------------------------------------
local function skill_craft(character, p)
  local recipe_name = p.recipe or p.item
  if not recipe_name then return false, "craft: missing 'recipe'" end
  local want = math.max(1, math.min(tonumber(p.count) or 1, 100))

  local recipe = prototypes.recipe[recipe_name]
  if not recipe then return false, "craft: no such recipe '" .. recipe_name .. "'" end

  -- get_craftable_count lives on LuaControl (the character), NOT on LuaForce. Indexing a
  -- key a Lua object does not have raises an error rather than returning nil, so an
  -- `x.foo and x.foo()` guard does not protect anything here — ask the character directly.
  local got, craftable = pcall(function() return character.get_craftable_count(recipe_name) end)
  if not got then
    return false, "craft: cannot determine craftability of " .. recipe_name ..
                  " (" .. tostring(craftable) .. ")"
  end
  if craftable == 0 then
    local inv = inv_of(character)
    local missing = {}
    for _, ing in pairs(recipe.ingredients) do
      if ing.type == "item" then
        local have = inv.get_item_count(ing.name)
        if have < ing.amount then
          missing[#missing + 1] = string.format("%s %d/%d", ing.name, have, ing.amount)
        end
      end
    end
    return false, "craft: cannot craft " .. recipe_name ..
      (#missing > 0 and (" — short: " .. table.concat(missing, ", ")) or
       " — needs a machine, not hand-craftable")
  end

  local queued = character.begin_crafting{recipe = recipe_name, count = math.min(want, craftable)}
  if queued == 0 then
    return false, "craft: " .. recipe_name .. " could not be queued"
  end
  return true, string.format("crafting %d x %s%s", queued, recipe_name,
    queued < want and (" (wanted " .. want .. ", materials for " .. craftable .. ")") or "")
end

-- -------------------------------------------------------------------------
-- clear_area(radius) — mine trees, rocks and (on ore-covered maps) the ore
-- itself, to make buildable ground.
--
-- On a Danger Ores map this is the core loop of the whole scenario: the ground is
-- ore, only belts/drills/poles may be built on ore, and the way you get somewhere
-- to build is to mine the ore away. The ore also becomes MIXED as the map goes on,
-- so late on there may be no naturally clear ground anywhere near the base — which
-- makes "mine it clear" the only option rather than an optimisation. Ore is mined
-- last so trees and rocks (cheap, and blocking) go first.
-- -------------------------------------------------------------------------
local function skill_clear_area(character, p)
  local radius = math.max(4, math.min(tonumber(p.radius) or 12, 32))
  local surface = character.surface
  local inv = inv_of(character)
  local cleared = 0
  local mined_units = 0
  -- include_ore defaults ON: the caller asking to clear ground on an ore map means
  -- the ore too, and on a normal map there is simply no ore to find.
  local include_ore = p.include_ore ~= false

  for _ = 1, 120 do
    local types = include_ore and {"tree", "simple-entity", "resource"}
                               or {"tree", "simple-entity"}
    local blockers = surface.find_entities_filtered{
      position = character.position, radius = radius,
      type = types, limit = 40,
    }
    local target, td = nil, math.huge
    local ore_target, ore_d = nil, math.huge
    for _, e in ipairs(blockers) do
      if e.valid and e.minable then
        local dx, dy = e.position.x - character.position.x, e.position.y - character.position.y
        local d = dx * dx + dy * dy
        if e.type == "resource" then
          if d < ore_d then ore_d = d; ore_target = e end
        elseif d < td then
          td = d; target = e
        end
      end
    end
    target = target or ore_target   -- trees and rocks first, then dig into the ore
    if not target then break end
    local sp = surface.find_non_colliding_position("character", target.position, 3, 0.5)
    if sp then character.teleport(sp) end

    -- Do NOT trust mine_entity's return value. On a resource it reports false whenever the
    -- tile still holds ore after the swing — which is almost always, since one tile carries
    -- hundreds — even though the swing succeeded and the ore is in your inventory. Judge by
    -- what the inventory gained, the same way gather does.
    -- An ore tile also needs many swings to disappear, and a tile that is merely reduced is
    -- still unbuildable, so keep going until the entity is actually gone.
    -- Stop before the inventory is packed. Clearing ore yields thousands of items, and a
    -- full inventory silently breaks every later skill: mining stops yielding, crafting has
    -- nowhere to put output, and placement fails for want of a slot. Leave headroom.
    if inv.count_empty_stacks() <= 4 then
      return true, string.format(
        "cleared %d obstacle(s) (%d items) then STOPPED — inventory nearly full. " ..
        "Deposit into a chest with {\"skill\":\"deposit_to_chest\"} before clearing more.",
        cleared, mined_units)
    end

    local finished = false
    for _ = 1, 400 do
      if not target.valid then finished = true break end
      if inv.count_empty_stacks() <= 2 then break end
      local before = inv.get_item_count()
      character.mine_entity(target, true)
      if inv.get_item_count() == before then break end   -- inventory full, or unmineable
      mined_units = mined_units + 1
    end
    if not finished and target.valid then
      -- Could not finish this one; stop rather than spin on it forever.
      break
    end
    cleared = cleared + 1
  end

  if cleared == 0 then
    local left = #surface.find_entities_filtered{
      position = character.position, radius = radius,
      type = include_ore and {"tree", "simple-entity", "resource"} or {"tree", "simple-entity"},
      limit = 1,
    }
    if left > 0 then
      return false, string.format(
        "clear_area: found things to clear within %d tiles but could not mine them — " ..
        "inventory is probably full; deposit into a chest and retry", radius)
    end
    return true, string.format("clear_area: nothing to clear within %d tiles", radius)
  end
  return true, string.format(
    "cleared %d obstacle(s)%s within %d tiles (%d items mined) — there should be buildable "
    .. "ground here now", cleared, include_ore and " including ore" or "", radius, mined_units)
end

-- -------------------------------------------------------------------------
-- explore(direction, distance) — teleport outward in steps, letting chunks
-- generate, to find resources that are not in perception yet. Reports what ore
-- patches turned up so the next turn can act on them.
-- -------------------------------------------------------------------------
local DIR_VECTORS = {
  north = {0, -1}, south = {0, 1}, east = {1, 0}, west = {-1, 0},
  northeast = {1, -1}, northwest = {-1, -1}, southeast = {1, 1}, southwest = {-1, 1},
}

local function skill_explore(character, p)
  local dir = tostring(p.direction or "east"):lower()
  local vec = DIR_VECTORS[dir]
  if not vec then
    return false, "explore: direction must be one of north/south/east/west/northeast/…"
  end
  local distance = math.max(32, math.min(tonumber(p.distance) or 128, 512))
  local surface = character.surface
  local start = character.position
  local target = {x = start.x + vec[1] * distance, y = start.y + vec[2] * distance}

  surface.request_to_generate_chunks(target, 2)
  surface.force_generate_chunk_requests()

  local safe = surface.find_non_colliding_position("character", target, 16, 0.5)
  if not safe then
    return false, string.format("explore: nowhere to stand %d tiles %s (water or cliffs?)",
                                distance, dir)
  end
  character.teleport(safe)

  local found = {}
  for _, res in ipairs(surface.find_entities_filtered{
    position = safe, radius = 64, type = "resource", limit = 200,
  }) do
    found[res.name] = (found[res.name] or 0) + 1
  end
  local parts = {}
  for name, n in pairs(found) do parts[#parts + 1] = name .. " x" .. n end

  return true, string.format("explored %d tiles %s to {%d,%d}; %s",
    distance, dir, safe.x, safe.y,
    #parts > 0 and ("found " .. table.concat(parts, ", ")) or "no resources in sight")
end

-- -------------------------------------------------------------------------
-- build_power() — the vanilla steam starter: offshore pump on water, boiler
-- fed with coal, steam engine, and a pole to carry the output.
--
-- The model repeatedly tried to assemble this from primitives and failed on the
-- geometry: the three buildings must sit in a line along the pump's facing, and
-- an offshore pump only places on a water tile that has land behind it. Doing it
-- here means the model asks for "power" and the mechanics are fixed and testable.
-- -------------------------------------------------------------------------
local WATER_TILES = {"water", "deepwater", "water-green", "deepwater-green",
                     "water-shallow", "water-mud"}

local function skill_build_power(character, p)
  local surface = character.surface
  local inv = inv_of(character)
  local engines = math.max(1, math.min(tonumber(p.count) or 1, 4))

  local needs = {
    ["offshore-pump"] = 1, ["boiler"] = 1,
    ["steam-engine"] = engines, ["small-electric-pole"] = 1,
  }
  local short = {}
  for item, n in pairs(needs) do
    local have = inv.get_item_count(item)
    if have < n then short[#short + 1] = string.format("%s %d/%d", item, have, n) end
  end
  if #short > 0 then
    return false, "build_power: missing " .. table.concat(short, ", ") ..
                  " — craft or gather those first"
  end

  local water = surface.find_tiles_filtered{
    position = character.position, radius = 48, name = WATER_TILES, limit = 400,
  }
  if #water == 0 then
    return false, "build_power: no water within 48 tiles — explore for a lake first"
  end

  -- A pump needs land behind it: try each shore tile, facing away from the water.
  for _, tile in ipairs(water) do
    local tp = tile.position
    for dir_name, v in pairs({north = {0, -1}, south = {0, 1}, east = {1, 0}, west = {-1, 0}}) do
      local behind = surface.get_tile(tp.x + v[1], tp.y + v[2])
      if behind and not behind.collides_with("water_tile") then
        local placed = AIActions.run(character, {
          action = "place", item = "offshore-pump",
          position = {x = tp.x + 0.5, y = tp.y + 0.5}, direction = dir_name,
        })
        if placed then
          local built = {"pump"}
          -- Boiler and engines march inland along the pump's facing.
          local bx, by = tp.x + v[1] * 3, tp.y + v[2] * 3
          local boiler_ok = AIActions.run(character, {
            action = "place", item = "boiler",
            position = {x = bx + 0.5, y = by + 0.5}, direction = dir_name,
          })
          if boiler_ok then
            built[#built + 1] = "boiler"
            AIActions.run(character, {action = "insert", item = "coal", count = 20,
                                      position = {x = bx + 0.5, y = by + 0.5}})
            local n = 0
            for i = 1, engines do
              local ex, ey = bx + v[1] * (3 + i * 3), by + v[2] * (3 + i * 3)
              if AIActions.run(character, {action = "place", item = "steam-engine",
                                           position = {x = ex + 0.5, y = ey + 0.5},
                                           direction = dir_name}) then
                n = n + 1
                AIActions.run(character, {action = "place", item = "small-electric-pole",
                                          position = {x = ex + 2.5, y = ey + 0.5}})
              end
            end
            if n > 0 then
              built[#built + 1] = n .. " steam-engine"
              return true, "build_power: placed " .. table.concat(built, " + ") ..
                           ", boiler fuelled with coal"
            end
            return false, "build_power: pump and boiler placed, but no room for a steam " ..
                          "engine inland — clear_area then retry"
          end
          return false, "build_power: pump placed, but the boiler spot 3 tiles inland is " ..
                        "blocked — clear_area then retry"
        end
      end
    end
  end
  return false, "build_power: found water but no shore tile with land behind it to place " ..
                "the pump — try another lake"
end

-- -------------------------------------------------------------------------
-- build_lab(count) — place labs near home and load whatever science is on hand.
-- A lab still does nothing until research is queued, so this reminds the caller.
-- -------------------------------------------------------------------------
local SCIENCE_PACKS = {"automation-science-pack", "logistic-science-pack",
                       "military-science-pack", "chemical-science-pack"}

local function skill_build_lab(character, p)
  local inv = inv_of(character)
  local want = math.max(1, math.min(tonumber(p.count) or 1, 4))
  local have = inv.get_item_count("lab")
  if have == 0 then
    return false, "build_lab: no lab in inventory — craft one first " ..
                  "(10 iron-gear-wheel, 10 electronic-circuit, 4 transport-belt)"
  end

  local surface = character.surface
  local placed = 0
  for i = 1, math.min(want, have) do
    local spot, clear = find_clear_position(surface, "lab",
      {x = character.position.x + i * 4, y = character.position.y + 4}, 12)
    if spot and not clear then
      return false, "build_lab: no ore-free ground within 12 tiles — a lab on ore would be " ..
                    "destroyed by this map's rules. Run {\"skill\":\"clear_area\",\"radius\":8} " ..
                    "first, then retry."
    end
    if spot and AIActions.run(character, {action = "place", item = "lab", position = spot}) then
      placed = placed + 1
      for _, pack in ipairs(SCIENCE_PACKS) do
        if inv.get_item_count(pack) > 0 then
          AIActions.run(character, {action = "insert", item = pack,
                                    count = math.min(inv.get_item_count(pack), 10),
                                    position = spot})
        end
      end
    end
  end

  if placed == 0 then
    return false, "build_lab: no free space for a lab nearby — clear_area then retry"
  end
  local queued = character.force.current_research ~= nil
  return true, string.format("placed %d lab(s) and loaded available science%s", placed,
    queued and "" or " — nothing is being researched, queue it with the research skill")
end

-- -------------------------------------------------------------------------
-- Registry + required params (mirrored in the bridge router prompt/validation)
-- -------------------------------------------------------------------------
AISkills.REGISTRY = {
  build_ghosts     = skill_build_ghosts,
  deconstruct      = skill_deconstruct,
  gather           = skill_gather,
  build_miner      = skill_build_miner,
  build_smelter    = skill_build_smelter,
  fuel_all         = skill_fuel_all,
  loot_chests      = skill_loot_chests,
  deposit_to_chest = skill_deposit_to_chest,
  return_home      = skill_return_home,
  research         = skill_research,
  ["goto"]         = skill_goto,
  craft            = skill_craft,
  clear_area       = skill_clear_area,
  explore          = skill_explore,
  build_power      = skill_build_power,
  build_lab        = skill_build_lab,
}

-- -------------------------------------------------------------------------
-- Unified executor: a response entry is either a skill {skill=...} or a
-- primitive {action=...}. Dispatch each, collect E1 results.
-- -------------------------------------------------------------------------
-- Run a single entry (skill OR primitive) with error isolation.
-- Returns (ok, detail, label). Shared by execute() and the external run()
-- entrypoint so there is exactly one dispatch path to keep correct.
local function run_entry(character, entry)
  local ok, detail, label
  if entry.skill then
    label = "skill:" .. tostring(entry.skill)
    local handler = AISkills.REGISTRY[entry.skill]
    if handler then
      local call_ok, rok, rdetail = pcall(handler, character, entry)
      if not call_ok then ok, detail = false, "error: " .. tostring(rok)
      else ok, detail = (rok ~= false), rdetail end
    else
      ok, detail = false, "unknown skill '" .. tostring(entry.skill) .. "'"
    end
  elseif entry.action then
    label = entry.action
    ok, detail = AIActions.run(character, entry)
  else
    label = "?"
    ok, detail = false, "entry has neither 'skill' nor 'action'"
  end
  return (ok ~= false), detail, label
end

function AISkills.execute(character, entries)
  if not character or not character.valid then return end
  local results = {}
  for _, entry in ipairs(entries) do
    local ok, detail, label = run_entry(character, entry)
    results[#results + 1] = {action = label, ok = ok, detail = detail}
  end
  storage.ai_player.memory.last_action_results = results
end

-- Single-entry runner for external (RCON/remote) callers. Same dispatch and
-- error isolation as execute(), but returns (ok, detail) directly instead of
-- recording into memory. Used by the "ai_player" remote interface (control.lua).
function AISkills.run(character, entry)
  if not character or not character.valid then
    return false, "no valid character"
  end
  local ok, detail = run_entry(character, entry)
  return ok, detail or ""
end

return AISkills

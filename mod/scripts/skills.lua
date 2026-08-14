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
    local pos = surface.find_non_colliding_position("stone-furnace", anchor, 6, 1)
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

  -- place the collector at the drill's drop_position
  local drop = drill.drop_position
  local detail = "placed burner-mining-drill on " .. resource
  if inv.get_item_count(out_item) > 0 then
    if AIActions.run(character, {action = "place", item = out_item, position = drop}) then
      detail = detail .. " + " .. out_item .. " at drop position"
      if out_item == "stone-furnace" and inv.get_item_count("coal") > 0 then
        AIActions.run(character, {action = "insert", item = "coal", count = 5,
                                  position = drop, inventory = "fuel"})
      end
    else
      detail = detail .. string.format(" (couldn't place %s at drop {%d,%d})",
        out_item, math.floor(drop.x), math.floor(drop.y))
    end
  else
    detail = detail .. string.format(" — no %s to collect output; place one at {%d,%d}",
      out_item, math.floor(drop.x), math.floor(drop.y))
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

  -- Nothing queueable: the next research is likely a TRIGGER tech (Factorio 2.0
  -- bootstraps via crafting, not queuing). Tell the model to craft the science.
  for _, t in pairs(force.technologies) do
    if t.enabled and not t.researched and prereqs_met(t) and t.prototype.research_trigger ~= nil then
      return false, "research: '" .. t.name .. "' is unlocked by CRAFTING, not queuing — hand-craft "
        .. "automation-science-pack (1 copper-plate + 1 iron-gear-wheel) to trigger it; then more tech becomes queueable"
    end
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

  local craftable = character.force.get_craftable_count and
                    character.force.get_craftable_count(recipe_name) or nil
  if craftable == nil then
    -- Older/other API shape: fall back to asking the character directly.
    craftable = character.get_craftable_count(recipe_name)
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
-- clear_area(radius) — mine trees and rocks around the character to make room.
-- Placement fails on blocked tiles, so this is the fix when a build skill keeps
-- reporting it cannot place anything.
-- -------------------------------------------------------------------------
local function skill_clear_area(character, p)
  local radius = math.max(4, math.min(tonumber(p.radius) or 12, 32))
  local surface = character.surface
  local inv = inv_of(character)
  local cleared = 0

  for _ = 1, 120 do
    local blockers = surface.find_entities_filtered{
      position = character.position, radius = radius,
      type = {"tree", "simple-entity"}, limit = 40,
    }
    local target, td = nil, math.huge
    for _, e in ipairs(blockers) do
      if e.valid and e.minable then
        local dx, dy = e.position.x - character.position.x, e.position.y - character.position.y
        local d = dx * dx + dy * dy
        if d < td then td = d; target = e end
      end
    end
    if not target then break end
    local sp = surface.find_non_colliding_position("character", target.position, 3, 0.5)
    if sp then character.teleport(sp) end
    local before = inv.get_item_count()
    if not character.mine_entity(target, true) then break end
    if inv.get_item_count() == before then
      -- Mined but gained nothing: inventory is full, so stop rather than spin.
      cleared = cleared + 1
      break
    end
    cleared = cleared + 1
  end

  if cleared == 0 then
    return true, string.format("clear_area: nothing to clear within %d tiles", radius)
  end
  return true, string.format("cleared %d obstacle(s) within %d tiles", cleared, radius)
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
    local spot = surface.find_non_colliding_position("lab",
      {x = character.position.x + i * 4, y = character.position.y + 4}, 12, 1)
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

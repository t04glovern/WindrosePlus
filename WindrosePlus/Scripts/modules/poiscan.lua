-- WindrosePlus POI Scanner
-- Walks spawned actors and writes POI positions to pois.json.
-- First version runs in discovery mode: writes poi_discovered_classes.json
-- listing every distinct POI-candidate class seen, so patterns can be refined.
--
-- POIs are static once the world streams in, so this scans once after the first
-- player connects, then again every 4 hours. Manual refresh via a trigger file.

local json = require("modules.json")
local Log = require("modules.log")

local POIScan = {}
POIScan._path = nil
POIScan._tmpPath = nil
POIScan._classesPath = nil
POIScan._triggerPath = nil
POIScan._refreshInterval = 4 * 60 * 60  -- re-scan every 4h to catch dynamic POIs (boss respawns, etc.)
POIScan._lastWrite = 0
POIScan._wroteOnce = false
POIScan._discovered = {}                -- class -> count
POIScan._discoveredCap = 500            -- hard cap on distinct classes tracked

-- Substring patterns mapped to {category, type}. Order matters — first match wins.
-- These match against the EXTRACTED CLASS NAME (last "<name>_C" segment of the
-- UObject full name), not the full path, so we avoid false positives from
-- package or outer names.
POIScan._tags = {
    -- Camps
    { pat = "Tortuga",          cat = "Camps",              type = "Tortuga"        },
    { pat = "Brethren_Camp",    cat = "Camps",              type = "Brethren_Camp"  },
    { pat = "Buccaneer_Camp",   cat = "Camps",              type = "Buccaneer_Camp" },
    { pat = "Civilian_Camp",    cat = "Camps",              type = "Civilian_Camp"  },
    { pat = "Smuggler_Camp",    cat = "Camps",              type = "Smuggler_Camp"  },
    { pat = "CoastalCamp",      cat = "Camps",              type = "CoastalCamp"    },
    { pat = "BadCamp",          cat = "Camps",              type = "BadCamp"        },
    { pat = "_Outpost_",        cat = "Camps",              type = "Outpost"        },
    { pat = "_Hut_",            cat = "Camps",              type = "Hut"            },
    { pat = "_Farm_",           cat = "Camps",              type = "Farm"           },
    -- Resources
    { pat = "_Mine_",           cat = "Resources",          type = "Mine"           },
    -- Ruins & Corruption
    { pat = "PannoRuins",       cat = "Ruins & Corruption", type = "PannoRuins"     },
    { pat = "FireSanctuary",    cat = "Ruins & Corruption", type = "FireSanctuary"  },
    { pat = "Firebowl",         cat = "Ruins & Corruption", type = "Firebowl"       },
    { pat = "AncientTable",     cat = "Ruins & Corruption", type = "AncientTable"   },
    { pat = "_Altar_",          cat = "Ruins & Corruption", type = "Altar"          },
    { pat = "_Ruins_",          cat = "Ruins & Corruption", type = "Ruins"          },
    { pat = "Corrupted",        cat = "Ruins & Corruption", type = "Corrupted"      },
    -- Wrecks
    { pat = "ShipBattle",       cat = "Wrecks",             type = "ShipBattle"     },
    { pat = "Shipwreck",        cat = "Wrecks",             type = "Shipwreck"      },
    -- Exploration
    { pat = "AncientPool",      cat = "Exploration",        type = "AncientPool"    },
    { pat = "BossArena",        cat = "Exploration",        type = "BossArena"      },
    { pat = "_Cave_",           cat = "Exploration",        type = "Cave"           },
    { pat = "Dungeon",          cat = "Exploration",        type = "Dungeon"        },
    { pat = "Mystery",          cat = "Exploration",        type = "Mystery"        },
    { pat = "StargazerTower",   cat = "Exploration",        type = "StargazerTower" },
    -- Quests
    { pat = "MainQuest",        cat = "Quests",             type = "MainQuest"      },
    { pat = "SideQuest",        cat = "Quests",             type = "SideQuest"      },
    { pat = "TreasureMap",      cat = "Quests",             type = "TreasureMap"    },
    { pat = "QuestPOI",         cat = "Quests",             type = "QuestPOI"       },
    { pat = "MarkerModel",      cat = "Quests",             type = "Marker"         },
}

-- Any extracted class name containing one of these is logged in the discovery file
POIScan._discoveryPatterns = {
    "POI", "Camp", "Quest", "Marker", "Mine", "Ruin", "Dungeon", "Cave",
    "Altar", "Wreck", "ShipBattle", "Tortuga", "Outpost", "Pool", "Boss",
    "Stargazer", "Tower", "Sanctuary", "Treasure", "Hut", "Farm", "Smuggler",
    "Brethren", "Buccaneer", "Bad",
}

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function isDiscoveryCandidate(s)
    for _, p in ipairs(POIScan._discoveryPatterns) do
        if s:find(p, 1, true) then return true end
    end
    return false
end

local function classify(className)
    for _, t in ipairs(POIScan._tags) do
        if className:find(t.pat, 1, true) then
            return t.cat, t.type
        end
    end
    return nil, nil
end

local function extractClassName(fullName)
    -- UObject:GetFullName() returns e.g. "BP_Tortuga_C /Game/.../BP_Tortuga.BP_Tortuga_C_0"
    -- We want just the BP_*_C class identifier (without trailing _<instance number>).
    local name = fullName:match("([%w_]+_C) ") or fullName:match("([%w_]+_C)$")
    if name then return name end
    -- Fallback: trim path/leaf so we don't accumulate per-instance keys
    return fullName:match("([%w_]+)%.([%w_]+)$") or fullName
end

local function getActorLocation(actor)
    local x, y, z
    pcall(function()
        local loc = actor.ReplicatedMovement.Location
        if loc then x, y, z = loc.X, loc.Y, loc.Z end
    end)
    if not x then
        pcall(function()
            local root = actor.RootComponent
            if root and root:IsValid() then
                local rel = root.RelativeLocation
                if rel then x, y, z = rel.X, rel.Y, rel.Z end
            end
        end)
    end
    return x, y, z
end

function POIScan.init(gameDir, config)
    local dataDir = gameDir .. "windrose_plus_data"
    POIScan._path = dataDir .. "\\pois.json"
    POIScan._tmpPath = dataDir .. "\\pois.json.tmp"
    POIScan._classesPath = dataDir .. "\\poi_discovered_classes.json"
    POIScan._triggerPath = dataDir .. "\\poiscan_refresh"
    Log.info("POIScan", "POI writer ready")
end

function POIScan.writeIfDue()
    if not POIScan._path then return end

    -- Manual refresh trigger (drop a file at <dataDir>\poiscan_refresh to force a rescan)
    local triggered = false
    if POIScan._triggerPath then
        local f = io.open(POIScan._triggerPath, "r")
        if f then
            f:close()
            os.remove(POIScan._triggerPath)
            triggered = true
        end
    end

    -- First scan only happens after a player has connected (the world isn't fully
    -- streamed in until then). Subsequent scans run on a long interval.
    if not POIScan._wroteOnce then
        if not (WindrosePlus and WindrosePlus.state.playerCount > 0) then return end
    elseif not triggered then
        local now = os.time()
        if (now - POIScan._lastWrite) < POIScan._refreshInterval then return end
    end

    POIScan._scanAndWrite()
end

function POIScan._scanAndWrite()
    local actors
    local ok, err = pcall(function() actors = FindAllOf("Actor") end)
    if not ok or not actors then
        Log.warn("POIScan", "FindAllOf(Actor) failed: " .. tostring(err))
        return
    end

    local pois = {}
    local categoryCounts = {}
    local typeCounts = {}
    local newDiscoveries = false
    local total = 0
    local errors = 0

    for _, a in ipairs(actors) do
        local ok2 = pcall(function()
            if not a:IsValid() then return end
            total = total + 1
            local fn = a:GetFullName()
            local className = extractClassName(fn)

            -- Discovery log: any class matching POI keywords (capped at _discoveredCap)
            if isDiscoveryCandidate(className) then
                local prev = POIScan._discovered[className]
                if prev == nil and countKeys(POIScan._discovered) < POIScan._discoveredCap then
                    POIScan._discovered[className] = 1
                    newDiscoveries = true
                elseif prev ~= nil then
                    POIScan._discovered[className] = prev + 1
                end
            end

            -- Hard classification → POI entry
            local cat, ptype = classify(className)
            if cat then
                local x, y, z = getActorLocation(a)
                if x and y then
                    table.insert(pois, {
                        type = ptype,
                        category = cat,
                        name = className,
                        poiId = fn,
                        x = x, y = y, z = z,
                    })
                    categoryCounts[cat] = (categoryCounts[cat] or 0) + 1
                    typeCounts[ptype] = (typeCounts[ptype] or 0) + 1
                end
            end
        end)
        if not ok2 then errors = errors + 1 end
    end

    local payload = json.encode({
        pois = pois,
        category_counts = categoryCounts,
        type_counts = typeCounts,
        total_pois = #pois,
        actors_scanned = total,
        actor_errors = errors,
        timestamp = os.time(),
    })
    local f = io.open(POIScan._tmpPath, "w")
    if not f then
        Log.warn("POIScan", "Could not open " .. tostring(POIScan._tmpPath))
        return
    end
    f:write(payload)
    f:close()
    os.remove(POIScan._path)
    os.rename(POIScan._tmpPath, POIScan._path)

    -- Only mark success after the file is on disk
    POIScan._wroteOnce = true
    POIScan._lastWrite = os.time()

    if newDiscoveries then
        local sorted = {}
        for cn, count in pairs(POIScan._discovered) do
            table.insert(sorted, { class = cn, count = count })
        end
        table.sort(sorted, function(x, y) return x.count > y.count end)
        local cf = io.open(POIScan._classesPath, "w")
        if cf then
            cf:write(json.encode({ classes = sorted, last_updated = os.time() }))
            cf:close()
        end
        Log.info("POIScan", string.format("New POI-candidate classes (%d distinct now)", #sorted))
    end

    Log.info("POIScan", string.format("Wrote %d POIs across %d categories (%d actors scanned, %d errors)",
        #pois, countKeys(categoryCounts), total, errors))
end

return POIScan

-- SmartStorage Excluded
-- Manages chest identifiers that SmartStorage should ignore.

local Excluded = {}

-- Records are keyed by their stable chest identifier for constant-time lookup.
local excluded = {}

-- Returns the stored record, or nil when the chest is included.
function Excluded.isExcluded(identifier)
    return excluded[identifier]
end

-- Flips a chest's exclusion state and returns the new boolean state.
function Excluded.toggle(record)
    local identifier = record.identifier

    if excluded[identifier] then
        excluded[identifier] = nil
        return false
    end

    excluded[identifier] = record
    return true
end

-- Exposes the complete set for persistence and server synchronization.
function Excluded.getAll()
    return excluded
end

-- Replaces the in-memory set with data loaded for the current world.
function Excluded.load(data)
    excluded = data or {}
end

return Excluded

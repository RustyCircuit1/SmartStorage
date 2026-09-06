-- SmartStorage Persistence
-- Stores and validates per-world chest exclusions as JSON files.

local json = require('dkjson')
local Log = require('logger')

local UEHelpers = require('UEHelpers')

local SCRIPT_PATH =
    debug.getinfo(1, 'S').source:match('^@?(.*[/\\])') or ''

local MOD_PATH =
    SCRIPT_PATH .. '../'

local DATA_PATH =
    MOD_PATH .. 'Data/exclusions'

local Persistence = {}

-- Creates the exclusions directory when it does not already exist.
local function ensureDirectoryExists()
    os.execute(
        string.format(
            'mkdir "%s" 2>nul',
            DATA_PATH
        )
    )
end

-- Reads the active island ID, which scopes exclusions to one world.
function Persistence.getWorldId()
    local world = UEHelpers:GetWorld()

    if not world or not world:IsValid() then
        return nil
    end

    local gameState = world.GameState

    if not gameState or not gameState:IsValid() then
        return nil
    end

    local islandId = gameState.islandId

    if not islandId or not islandId.ID then
        return nil
    end

    local worldId =
    islandId.ID:ToString()

    if not worldId or worldId == '' then
        return nil
    end

    return worldId
end

-- Builds the JSON path for the active world.
function Persistence.getExclusionsPath()
    local worldId = Persistence.getWorldId()

    if not worldId then
        return nil
    end

    return string.format(
        '%s/%s.json',
        DATA_PATH,
        worldId
    )
end

-- Serializes and writes the current exclusion data.
function Persistence.saveExclusions(data)
    ensureDirectoryExists()

    local path = Persistence.getExclusionsPath()

    if not path then
        return false, 'Could not determine exclusions path'
    end

    local encoded = json.encode(data, {
        indent = true,
        keyorder = {
            'schemaVersion',
            'worldId',
            'excludedChests'
        }
    })

    local file, errorMessage = io.open(path, 'w')

    if not file then
        return false, errorMessage
    end

    file:write(encoded)
    file:close()

    return true, path
end

-- Loads the active world's exclusions and discards malformed records.
function Persistence.loadExclusions()
    local path = Persistence.getExclusionsPath()

    if not path then
        return nil, 'Could not determine exclusions path'
    end

    local file = io.open(path, 'r')

    if not file then
        return {
            schemaVersion = 1,
            worldId = Persistence.getWorldId(),
            excludedChests = {}
        }
    end

    local contents = file:read('*a')
    file:close()

    local data, _, decodeError =
        json.decode(contents, 1, nil)

    if decodeError then
        return nil, decodeError
    end

    if type(data) ~= 'table' then
        return nil, 'Invalid exclusions data'
    end

    if data.schemaVersion ~= 1 then
        return nil, 'Unsupported schema version'
    end

    local currentWorldId = Persistence.getWorldId()

    if data.worldId ~= currentWorldId then
        return nil, 'World ID mismatch'
    end

    if type(data.excludedChests) ~= 'table' then
        return nil, 'Invalid excludedChests data'
    end

    local validChests = {}
    local invalidCount = 0

    for identifier, record in pairs(data.excludedChests) do
        if type(identifier) == 'string'
            and type(record) == 'table'
            and record.identifier == identifier
            and type(record.classFullName) == 'string'
            and type(record.buildingGraphNodeId) == 'number'
            and identifier:match('_G%d+$') ~= nil
            and type(record.location) == 'table'
            and type(record.location.x) == 'number'
            and type(record.location.y) == 'number'
            and type(record.location.z) == 'number'
        then
            validChests[identifier] = record
        else
            invalidCount = invalidCount + 1
        end
    end

    data.excludedChests = validChests

    if invalidCount > 0 then
        Log.warning(
            'Ignored %d invalid exclusion record(s)',
            invalidCount
        )
    end

    return data
end

return Persistence

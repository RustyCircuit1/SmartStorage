-- SmartStorage
-- Extends storage behavior in Windrose using UE4SS.

local VERSION = '0.9.95'

-----------------------------------------------------------------------
-- Resolves the directory containing this script.
--
-- UE4SS prefixes file-backed Lua sources with '@'. The pattern removes
-- that prefix and returns the directory containing main.lua.
-----------------------------------------------------------------------
local SCRIPT_PATH = 
    debug.getinfo(1, 'S').source:match('^@?(.*[/\\])') or ''

-----------------------------------------------------------------------
-- Adds SmartStorage's Scripts directory to Lua's module search path.
--
-- This allows modules in this directory to be loaded with require().
-----------------------------------------------------------------------
package.path = SCRIPT_PATH .. '?.lua;' .. package.path

local Config = require('config')
local Log = require('logger')
local Chest = require('chest')
local Excluded = require('excluded')
local UEHelpers = require('UEHelpers')
local Persistence = require('persistence')
local exclusionsLoaded = false

-- Lazily loads the current world's exclusions once its island ID is ready.
local function ensureWorldExclusionsLoaded()
    if exclusionsLoaded then
        return true
    end

        if not Persistence.getWorldId() then
            return false
        end

    local data, errorMessage =
        Persistence.loadExclusions()

    if not data then
        Log.error(
            'Could not load exclusions: %s',
            tostring(errorMessage)
        )
        return false
    end

    Excluded.load(
        data.excludedChests or {}
    )

    exclusionsLoaded = true

    Log.debug(
        'Loaded exclusions for world: %s',
        tostring(data.worldId)
    )

    return true
end

-- Persists the current exclusion set for the active world.
local function saveWorldExclusions()
    local data = {
        schemaVersion = 1,
        worldId = Persistence.getWorldId(),
        excludedChests = Excluded.getAll()
    }

    local success, result =
        Persistence.saveExclusions(data)

    if not success then
        Log.error(
            'Could not save exclusions: %s',
            tostring(result)
        )
        return
    end

    Log.debug(
        'Saved exclusions for world: %s',
        tostring(data.worldId)
    )
end

Config.load()

Log.setMode(
    Config.getLoggingMode()
)

local QuickDeposit = require('quick_deposit')

-----------------------------------------------------------------------
-- Keybinds
-----------------------------------------------------------------------

if Config.getModMode() == 'keybind' then
    RegisterKeyBind(
        Config.getDepositAllKeyValue(),
        function()
            ExecuteInGameThread(function()
                if not ensureWorldExclusionsLoaded() then
                    return
                end

                local chest =
                    Chest.findLookedAt()

                if not chest then
                    Log.info(
                        'No storage selected'
                    )
                    return
                end

                local playerController =
                    UEHelpers:GetPlayerController()

                if not playerController
                    or not playerController:IsValid()
                then
                    Log.debug(
                        'Could not arm Keybind: PlayerController not found'
                    )
                    return
                end

                local record =
                    Chest.getExclusionRecord(chest)

                if not playerController:HasAuthority() then
                    playerController:ServerExecRPC(
                        string.format(
                            'SmartStorageArm|%s',
                            record.identifier
                        )
                    )
                end

                QuickDeposit.deposit(
                    chest
                )
            end)
        end
    )
end

RegisterKeyBind(Config.getExclusionKeyValue(), function()
    ExecuteInGameThread(function()
        if not ensureWorldExclusionsLoaded() then
            return
        end

        local chest = Chest.findLookedAt()

        if not chest then
            Log.info('No storage selected')
            return
        end

        local record = Chest.getExclusionRecord(chest)

        local identifier = record.identifier
        local isExcluded = Excluded.toggle(record)

        local playerController =
            UEHelpers:GetPlayerController()

        if not playerController
            or not playerController:IsValid()
        then
            Log.debug(
                'F6 PlayerController not found'
            )
        else
            playerController:ServerExecRPC(
                string.format(
                    'SmartStorage|%s|%s',
                    identifier,
                    isExcluded and '1' or '0'
                )
            )
            
        end

        if isExcluded then
            Log.info('Storage excluded: %s', identifier)
        else
            Log.info('Storage included: %s', identifier)
        end

        saveWorldExclusions()
        QuickDeposit.refreshExclusionLabel(
            isExcluded
        )
    end)

end)

-----------------------------------------------------------------------
-- Startup
-----------------------------------------------------------------------
-- Sends the active mode and exclusion set to the authoritative server.
local function syncPlayerSettingsToServer()
    local playerController =
        UEHelpers:GetPlayerController()

    if not playerController
        or not playerController:IsValid()
    then
        Log.debug(
            'Could not sync player settings: PlayerController not found'
        )
        return
    end

    playerController:ServerExecRPC(
        string.format(
            'SmartStorageMode|%s',
            Config.getModMode()
        )
    )

    playerController:ServerExecRPC(
        'SmartStorageClear'
    )

    local exclusions =
        Excluded.getAll()

    for identifier in pairs(exclusions) do
        playerController:ServerExecRPC(
            string.format(
                'SmartStorage|%s|1',
                identifier
            )
        )
    end
end

-- Re-synchronizes settings after the local player pawn is restarted.
-- Exclusion loading is retried while the new world finishes initializing.
local function registerClientRestartSync()

    local function retryWorldExclusionsLoad(attemptsLeft)
        if ensureWorldExclusionsLoaded() then
            syncPlayerSettingsToServer()
            return
        end

        if attemptsLeft <= 1 then
            Log.warning(
                'Could not preload exclusions because world ID was not ready'
            )
            return
        end

        ExecuteWithDelay(
            1000,
            function()
                ExecuteInGameThread(function()
                    retryWorldExclusionsLoad(
                        attemptsLeft - 1
                    )
                end)
            end
        )
    end

    RegisterHook(
        '/Script/Engine.PlayerController:ClientRestart',
        function(_, pPawn)
            local pawn =
                pPawn:get()

            if not pawn
                or not pawn:IsValid()
            then
                return
            end

            local className =
                pawn:GetClass():GetFullName()

            if not className:find(
                'BP_R5Character_C',
                1,
                true
            ) then
                return
            end

            ExecuteWithDelay(
                1000,
                function()
                    ExecuteInGameThread(function()

                        QuickDeposit.cachePlayerController()

                        retryWorldExclusionsLoad(
                            5
                        )

                end)
            end
        )
    end
    )
end

registerClientRestartSync()

Log.info('Version %s loaded. Wuhuuuuuuu. My first mod :)', VERSION)

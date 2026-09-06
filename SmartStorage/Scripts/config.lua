-- SmartStorage Configuration
-- Loads config.ini, validates its values, and exposes typed settings.

local Log = require('logger')

local Config = {}

local SCRIPT_PATH =
    debug.getinfo(1, 'S').source:match('^@?(.*[/\\])') or ''

local MOD_PATH =
    SCRIPT_PATH .. '../'

local CONFIG_PATH =
    MOD_PATH .. 'config.ini'

local config = {
    modMode = 'keybind',
    depositAllKey = 'f5',
    exclusionKey = 'f6',
    loggingMode = 'default'
}

-- Removes leading and trailing whitespace from an INI value.
local function trim(value)
    return value
        :match('^%s*(.-)%s*$')
end

-- Accepts only the interaction modes implemented by SmartStorage.
local function validateModMode(value)
    if value == 'keybind'
        or value == 'expand'
    then
        return value
    end

    Log.warning(
        'Invalid ModMode "%s". Supported values: Keybind, Expand. Using default: Keybind.',
        tostring(value)
    )

    return 'keybind'
end

-- Keeps logging modes aligned with the logger module.
local function validateLoggingMode(value)
    if value == 'default'
        or value == 'debug'
    then
        return value
    end

    Log.warning(
        'Invalid LoggingMode "%s". Supported values: Default, Debug. Using default: Default.',
        tostring(value)
    )

    return 'default'
end

-- Resolves a configured key name or falls back when UE4SS does not know it.
local function validateKey(value, defaultValue, settingName)
    local keyName = value:upper()

    if Key[keyName] then
        return value
    end

    Log.warning(
        'Invalid %s "%s". Using default: %s.',
        settingName,
        tostring(value),
        defaultValue:upper()
    )

    return defaultValue
end

-- Converts a validated key name into the UE4SS key value used by keybinds.
local function resolveKey(value)
    return Key[value:upper()]
end

-- Reads config.ini and applies recognized settings over the defaults.
function Config.load()
    local file, errorMessage =
        io.open(CONFIG_PATH, 'r')

    if not file then
        Log.warning(
            'Could not read config.ini: %s. Using defaults.',
            tostring(errorMessage)
        )

        return
    end

    local section = nil

    for line in file:lines() do
        line = trim(line)

        if line ~= ''
            and not line:match('^;')
            and not line:match('^#')
        then
            local sectionName =
                line:match('^%[(.-)%]$')

            if sectionName then
                section =
                    sectionName:lower()
            else
                local key, value =
                    line:match('^([^=]+)=(.*)$')

                if key and value then
                    key = trim(key):lower()
                    value = trim(value):lower()

                    if section == 'general'
                        and key == 'modmode'
                    then
                        config.modMode = validateModMode(value)

                    elseif section == 'keybinds'
                        and key == 'depositallkey'
                    then
                        config.depositAllKey =
                            validateKey(
                                value,
                                'f5',
                                'DepositAllKey'
                            )

                    elseif section == 'keybinds'
                        and key == 'exclusionkey'
                    then
                        config.exclusionKey =
                            validateKey(
                                value,
                                'f6',
                                'ExclusionKey'
                            )

                    elseif section == 'logging'
                        and key == 'loggingmode'
                    then
                        config.loggingMode = validateLoggingMode(value)
                    end
                end
            end
        end
    end

    file:close()
end

-- The following getters keep the parsed configuration private to this module.
function Config.getModMode()
    return config.modMode
end

function Config.getDepositAllKey()
    return config.depositAllKey
end

function Config.getExclusionKey()
    return config.exclusionKey
end

function Config.getLoggingMode()
    return config.loggingMode
end

function Config.getDepositAllKeyValue()
    return resolveKey(config.depositAllKey)
end

function Config.getExclusionKeyValue()
    return resolveKey(config.exclusionKey)
end

return Config

-- SmartStorage Logger
-- Provides consistent logging for every SmartStorage module.
local loggingMode = 'default'
local Logger = {}

-- Updates the active mode used to filter optional debug messages.
function Logger.setMode(mode)
    loggingMode = mode
end

local MOD_NAME = 'SmartStorage'


-----------------------------------------------------------------------
-- Writes a formatted message with the mod name and log level.
--
-- @param level  Log level shown in the prefix.
-- @param fmt    Message or string.format pattern.
-- @param ...    Optional values used by string.format.
-----------------------------------------------------------------------
local function writeLog(level, fmt, ...)
    local message = fmt

    if select('#', ...) > 0 then
        message = string.format(fmt, ...)
    end

    print(string.format('[%s][%s] %s\n', MOD_NAME, level, message))
end

-----------------------------------------------------------------------
-- Writes a normal informational message.
-----------------------------------------------------------------------
function Logger.info(fmt, ...)
    writeLog('INFO', fmt, ...)
end

-----------------------------------------------------------------------
-- Writes a warning message.
-----------------------------------------------------------------------
function Logger.warning(fmt, ...)
    writeLog('WARNING', fmt, ...)
end

-----------------------------------------------------------------------
-- Writes an error message.
-----------------------------------------------------------------------
function Logger.error(fmt, ...)
    writeLog('ERROR', fmt, ...)
end

-----------------------------------------------------------------------
-- Writes a debug message only when debug logging is enabled.
-----------------------------------------------------------------------
function Logger.debug(fmt, ...)
    if loggingMode ~= 'debug' then
        return
    end

    writeLog('DEBUG', fmt, ...)
end

return Logger

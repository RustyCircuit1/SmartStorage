-- SmartStorage Chest
-- Contains discovery and helper functions for storage chests.
local UEHelpers = require('UEHelpers')
local kismetMathLibrary = StaticFindObject('/Script/Engine.Default__KismetMathLibrary')
local kismetSystemLibrary = StaticFindObject('/Script/Engine.Default__KismetSystemLibrary')
local campChestClass = StaticFindObject('/Script/R5.R5LootableInventoryBox')
local Chest = {}

local CAMP_CHEST_CLASS = 'R5LootableInventoryBox'

-----------------------------------------------------------------------
-- Finds all currently loaded camp chest objects.
--
-- FindAllOf is supplied by UE4SS. It searches Unreal's live object
-- registry for non-default instances of the requested class.
--
-- @return table  A numerically indexed table of chest objects.
--                Returns an empty table when none are found.
-----------------------------------------------------------------------
function Chest.findAll()
    local chests = FindAllOf(CAMP_CHEST_CLASS)

    if not chests then
        return {}
    end

    return chests
end

-----------------------------------------------------------------------
-- Captures the class and world position that make up a chest's identity.
--
-- @return table
-----------------------------------------------------------------------
function Chest.getIdentity(chest)

    local location = chest:K2_GetActorLocation()
    local class = chest:GetClass():GetFullName()

    local identity = {
        class = class,
        location = {
            x = location.X,
            y = location.Y,
            z = location.Z
        }
    }
    return identity
end

-----------------------------------------------------------------------
-- Creates a stable, human-readable identifier for a chest identity.
--
-- @param identity  A table returned by Chest.getIdentity().
--
-- @return string
-----------------------------------------------------------------------
function Chest.getIdentifier(identity)
    local className = identity.class
        :match('([^./]+)_C$')
        :gsub('^BP_Storage_', '')

    local text = string.format(
        '%s_X%.0f_Y%.0f_Z%.0f',
        className,
        identity.location.x,
        identity.location.y,
        identity.location.z
    )
    return text
end

function Chest.getExclusionIdentifier(chest)
    local className =
        chest:GetClass():GetFullName()
            :match('([^./]+)_C$')
            :gsub('^BP_Storage_', '')

    return string.format(
        '%s_G%s',
        className,
        tostring(chest.BuildingGraphNodeId)
    )
end

function Chest.getExclusionRecord(chest)
    local identity =
        Chest.getIdentity(chest)

    return {
        identifier =
            Chest.getExclusionIdentifier(chest),

        classFullName =
            identity.class,

        buildingGraphNodeId =
            chest.BuildingGraphNodeId,

        location = {
            x = identity.location.x,
            y = identity.location.y,
            z = identity.location.z
        }
    }
end

-----------------------------------------------------------------------
-- Traces forward from the player camera and returns the targeted chest.
-- Invalid actors and non-storage hits are ignored.
-----------------------------------------------------------------------
function Chest.findLookedAt()
    local playerController = UEHelpers:GetPlayerController()

    if not playerController or not playerController:IsValid() then
        return nil
    end

    local cameraManager = playerController.PlayerCameraManager

    if not cameraManager or not cameraManager:IsValid() then
        return nil
    end

    local playerPawn = playerController.Pawn

    if not playerPawn or not playerPawn:IsValid() then
        return nil
    end
    local traceDistance = 5000.0 -- Long enough to reach the storage the player is looking at.
    local actorsToIgnore = {}
    local hitResult = {}

    local startVector = cameraManager:GetCameraLocation()
    local cameraRotation = cameraManager:GetCameraRotation()
    local forwardVector = kismetMathLibrary:GetForwardVector(cameraRotation)
    local traceOffset = kismetMathLibrary:Multiply_VectorInt(
        forwardVector,
        traceDistance
    )

    local endVector = kismetMathLibrary:Add_VectorVector(
        startVector,
        traceOffset
    )

    local transparentColor = {
        R = 0,
        G = 0,
        B = 0,
        A = 0
        }
    
    local wasHit = kismetSystemLibrary:LineTraceSingle(
        playerPawn,
        startVector,
        endVector,
        0, -- ETraceTypeQuery_TraceTypeQuery1
        false, -- traceComplex.  Use simple collision.
        actorsToIgnore,
        0, -- EDrawDebugTrace_Type_None. Shows no debug line.
        hitResult,
        true, -- IgnoreSelf. Prevents the trace from hitting the player's own pawn.
        transparentColor,
        transparentColor,
        0.0 -- DrawTime. Unused because debug drawing is disabled.
        )

    if not wasHit then
        return nil
    end

    local componentOk, hitComponent = pcall(function()
    return hitResult.HitObjectHandle.ReferenceObject:Get()
    end)

    if not componentOk
        or not hitComponent
        or not hitComponent:IsValid()
    then
        return nil
    end

    local ownerOk, owner = pcall(function()
        return hitComponent:GetOwner()
    end)

    if not ownerOk
        or not owner
        or not owner:IsValid()
        or not owner:IsA(campChestClass)
    then
        return nil
    end

    return owner

end

-----------------------------------------------------------------------
-- Checks whether a chest belongs to a specific camp storage center.
-----------------------------------------------------------------------
function Chest.isInBuildingCenter(chest, storageCenter)
    if not chest
        or not chest:IsValid()
        or not storageCenter
        or not storageCenter:IsValid()
    then
        return false
    end

    return storageCenter.BuildingGraphIds:Contains(
        chest.BuildingGraphNodeId
    )
end

-----------------------------------------------------------------------
-- Finds the building center whose graph contains the supplied chest.
-----------------------------------------------------------------------
function Chest.findBuildingCenterFor(chest)
    local centers =
        FindAllOf('R5BuildingBlock_BuildingCenter')

    if not centers then
        return nil
    end

    for _, center in ipairs(centers) do
        local storageCenter =
            center.StorageCenter

        if Chest.isInBuildingCenter(
            chest,
            storageCenter
        ) then
            return center
        end
    end

    return nil
end

-----------------------------------------------------------------------
-- Returns whether two chests belong to the same camp graph.
-----------------------------------------------------------------------
function Chest.isInSameCamp(originChest, targetChest)
    local center =
        Chest.findBuildingCenterFor(originChest)

    if not center then
        return false
    end

    return Chest.isInBuildingCenter(
        targetChest,
        center.StorageCenter
    )
end

return Chest

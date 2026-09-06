-- SmartStorage Quick Deposit
-- Handles integration with Windrose's vanilla Quick Deposit ability.
local Log = require('logger')
local Chest = require('chest')
local Excluded = require('excluded')
local Config = require('config')
local UEHelpers = require('UEHelpers')

local QuickDeposit = {}

local campChestClass =
    StaticFindObject('/Script/R5.R5LootableInventoryBox')

-- Confirmed offset of ActorComponent's owner pointer in Windrose.
local OWNER_POINTER_OFFSET = 0xA0

-- Exposes the native owner pointer through a UE4SS custom property.
local function registerOwnerPointerProperty()

    local ok, err = pcall(function()
        RegisterCustomProperty({
            ['Name'] = string.format(
                'SmartStorage_CompProbe_%X',
                OWNER_POINTER_OFFSET
            ),
            ['Type'] = PropertyTypes.Int64Property,
            ['BelongsToClass'] =
                '/Script/Engine.ActorComponent',
            ['OffsetInternal'] = OWNER_POINTER_OFFSET,
        })
    end)

    if not ok then
        Log.error(
            'RegisterCustomProperty failed, '
            .. 'mod cannot function: %s',
            tostring(err)
        )
    end
end

-- Reads the native owner address from an interaction component.
local function readOwnerPointer(component)
    
    local propertyName = string.format(
        'SmartStorage_CompProbe_%X',
        OWNER_POINTER_OFFSET
    )

    local ok, value = pcall(function()
        return component[propertyName]
    end)

    if not ok then
        return nil
    end

    return tonumber(value)
end

-- Temporarily assigns an interaction component to another chest.
local function writeOwnerPointer(component, ownerAddress)

    local propertyName = string.format(
        'SmartStorage_CompProbe_%X',
        OWNER_POINTER_OFFSET
    )

    return pcall(function()
        component[propertyName] = ownerAddress
    end)
end

-- Safely obtains the component used by Windrose for chest interaction.
local function getInteractComponent(chest)
    local ok, component = pcall(function() return chest.InteractTargetComponent end)
    if ok and component and component:IsValid() then return component end
    return nil
end

-- Replays the captured target-data RPC against the component's current owner.
local function replayDeposit(
    abilitySystemComponent,
    abilityHandle,
    originalPredictionKey,
    targetData,
    applicationTag,
    currentPredictionKey
)
    return pcall(function()
        abilitySystemComponent:ServerSetReplicatedTargetData(
            abilityHandle,
            originalPredictionKey,
            targetData,
            applicationTag,
            currentPredictionKey
        )
    end)
end

local inMultipass = false

-- Keybind bruger fortsat en one-shot origin.
local pendingOriginChests = {}

-- Expand husker den storage, klienten aktuelt interagerer med.
local expandOriginChests = {}

-- Sidste behandlede prediction key pr. spiller.
-- Bruges til at ignorere RPC nr. 2 fra samme Q-tryk.
local lastExpandPredictionKeys = {}

-- Fallback til singleplayer/listen host, hvis prediction key ikke kan læses.
local expandActivationReady = {}

local playerExclusions = {}
local playerModes = {}

-- Returns the server-side exclusion set for one player.
local function getPlayerExclusions(playerId)
    if not playerExclusions[playerId] then
        playerExclusions[playerId] = {}
    end

    return playerExclusions[playerId]
end

-- Applies an exclusion update received from a client.
local function setPlayerExcluded(
    playerId,
    identifier,
    excluded
)
    local exclusions =
        getPlayerExclusions(playerId)

    if excluded then
        exclusions[identifier] = true
    else
        exclusions[identifier] = nil
    end
end

-- Finds valid, non-excluded target chests in the origin chest's camp.
local function findTargetChests(
    originChest,
    playerExclusions
)
    local originAddress =
        originChest:GetAddress()

    local targets = {}

    local center =
        Chest.findBuildingCenterFor(
            originChest
        )

    if not center then
        return targets
    end

    local storageCenter =
        center.StorageCenter

    for _, chest in ipairs(Chest.findAll()) do
        if chest:IsValid()
            and chest:GetAddress() ~= originAddress
            and Chest.isInBuildingCenter(
                chest,
                storageCenter
            )
        then
            local identity =
                Chest.getIdentity(chest)

            local identifier =
                Chest.getIdentifier(identity)

            if not playerExclusions
                or not playerExclusions[identifier]
            then
                table.insert(
                    targets,
                    chest
                )
            end
        end
    end

    return targets
end

-- Verifies that the origin chest's interaction owner can be safely swapped.
local function getOwnerPointerInfo(originChest)
    local component = getInteractComponent(originChest)

    if not component then
        return nil
    end

    local originAddress = originChest:GetAddress()

    if readOwnerPointer(component) ~= originAddress then
        Log.warning(
            'Interact component owner pointer was not found at 0x%X',
            OWNER_POINTER_OFFSET
        )
    return nil
end

return component, originAddress
end

-- Consumes a pending origin exactly once for the captured player action.
local function consumePendingOriginChest(playerKey)
    local originChest =
        pendingOriginChests[playerKey]

    pendingOriginChests[playerKey] = nil

    if not originChest
        or not originChest:IsValid()
    then
        return nil
    end

    return originChest
end

-- Reads the useful numeric part of an Unreal Gameplay Ability prediction key.
local function getPredictionKeyNumber(predictionKey)
    if not predictionKey then
        return nil
    end

    local ok, value = pcall(function()
        return predictionKey.Current
    end)

    if not ok then
        return nil
    end

    value = tonumber(value)

    if not value or value == 0 then
        return nil
    end

    return value
end


-- Returns true only once for one expand ability activation.
--
-- Remote multiplayer:
--     Uses Unreal's prediction key.
--
-- Singleplayer/listen host fallback:
--     Uses the locally observed Deposit Similar ability object.
local function shouldProcessExpandTargetData(
    playerKey,
    currentPredictionKey
)
    local predictionKey =
        getPredictionKeyNumber(
            currentPredictionKey
        )

    if predictionKey then
        if lastExpandPredictionKeys[playerKey]
            == predictionKey
        then
            return false
        end

        lastExpandPredictionKeys[playerKey] =
            predictionKey

        -- A usable prediction key is better than the local fallback.
        expandActivationReady[playerKey] = nil

        return true
    end

    -- In singleplayer/listen-host the ability object is local to the
    -- authoritative process, so this remains a safe fallback.
    if expandActivationReady[playerKey] then
        expandActivationReady[playerKey] = nil
        return true
    end

    return false
end

-- Swaps the component owner, replays one deposit, and always attempts restore.
local function replayToTargetChest(
    component,
    originAddress,
    targetChest,
    abilitySystemComponent,
    abilityHandle,
    originalPredictionKey,
    targetData,
    applicationTag,
    currentPredictionKey
)
    local targetAddress = targetChest:GetAddress()

    inMultipass = true

    local switchOk, switchError =
        writeOwnerPointer(component, targetAddress)

    if not switchOk then
        inMultipass = false

        Log.error(
            'Could not switch interact component owner: %s',
            tostring(switchError)
        )

        return
    end

    local switchedOwnerAddress =
        readOwnerPointer(component)

    if switchedOwnerAddress ~= targetAddress then
        local restoreOk = false
        local restoreError = nil
        local restoredOwnerAddress = nil

        if component:IsValid() then
            restoreOk, restoreError =
                writeOwnerPointer(component, originAddress)

            restoredOwnerAddress =
                readOwnerPointer(component)
        end

        inMultipass = false

        Log.error(
            'Owner switch verification failed. '
            .. 'Expected=%s Actual=%s',
            tostring(targetAddress),
            tostring(switchedOwnerAddress)
        )

        if not restoreOk then
            Log.error(
                'Could not restore interact component owner '
                .. 'after failed switch verification: %s',
                tostring(restoreError)
            )
        elseif restoredOwnerAddress ~= originAddress then
            Log.error(
                'Owner restoration verification failed '
                .. 'after failed switch. Expected=%s Actual=%s',
                tostring(originAddress),
                tostring(restoredOwnerAddress)
            )
        end

        return
    end

    local replayOk, replayError = replayDeposit(
        abilitySystemComponent,
        abilityHandle,
        originalPredictionKey,
        targetData,
        applicationTag,
        currentPredictionKey
    )

    local restoreOk = false
    local restoreError = nil
    local restoredOwnerAddress = nil

    if component:IsValid() then
        restoreOk, restoreError =
            writeOwnerPointer(component, originAddress)

        restoredOwnerAddress =
            readOwnerPointer(component)
    end

    inMultipass = false

    if not restoreOk then
        Log.error(
            'Could not restore interact component owner: %s',
            tostring(restoreError)
        )
    elseif restoredOwnerAddress ~= originAddress then
        Log.error(
            'Owner restoration verification failed. '
            .. 'Expected=%s Actual=%s',
            tostring(originAddress),
            tostring(restoredOwnerAddress)
        )
    end

    if not replayOk then
        Log.error(
            'Quick Deposit replay failed: %s',
            tostring(replayError)
        )
    end
end

-- Resolves the origin for one captured vanilla Quick Deposit action.
-- Keybind mode keeps its explicit one-shot arm. Expand mode instead uses
-- the interaction target synchronized by the client and consumes the
-- ability-created gate so duplicate target-data RPCs are ignored.
local function getOriginForDeposit(
    playerKey,
    playerId,
    currentPredictionKey
)
    if playerModes[playerId] == 'expand' then
        local originChest =
            expandOriginChests[playerKey]

        if not originChest
            or not originChest:IsValid()
        then
            Log.warning(
                'Expand RPC received without synchronized origin. '
                .. 'PlayerKey=%s PlayerId=%s',
                tostring(playerKey),
                tostring(playerId)
            )

            return nil
        end

        if not shouldProcessExpandTargetData(
            playerKey,
            currentPredictionKey
        ) then
            return nil
        end

        return originChest
    end

    return consumePendingOriginChest(playerKey)
end

-- Fans the captured vanilla Quick Deposit RPC out to every eligible target.
local function handleQuickDeposit(
    abilitySystemComponent,
    abilityHandle,
    originalPredictionKey,
    targetData,
    applicationTag,
    currentPredictionKey,
    playerKey,
    playerId
)

    local originChest =
        getOriginForDeposit(
            playerKey,
            playerId,
            currentPredictionKey
        )

    if not originChest then
        return
    end

    local component, originAddress =
        getOwnerPointerInfo(originChest)

    if not component then
        return
    end

    local exclusions =
        getPlayerExclusions(playerId)


    local targetChests =
        findTargetChests(
            originChest,
            exclusions
        )

    if #targetChests == 0 then
        Log.info('No target storages found')
        return
    end

    for _, targetChest in ipairs(targetChests) do
        replayToTargetChest(
            component,
            originAddress,
            targetChest,
            abilitySystemComponent,
            abilityHandle,
            originalPredictionKey,
            targetData,
            applicationTag,
            currentPredictionKey
        )

        local currentOwnerAddress =
            readOwnerPointer(component)

        if currentOwnerAddress ~= originAddress then
            Log.error(
                'Stopping Quick Deposit because the interact '
                .. 'component owner was not safely restored. '
                .. 'Expected=%s Actual=%s',
                tostring(originAddress),
                tostring(currentOwnerAddress)
            )

            break
        end
    end
end

-- Starts a keybind-driven deposit using the currently selected origin chest.
function QuickDeposit.deposit(originChest)
    if not originChest or not originChest:IsValid() then
        Log.warning('No valid origin chest')
        return
    end

    local playerController =
        cachedPlayerController

    if not playerController
        or not playerController:IsValid()
    then
        playerController =
            UEHelpers:GetPlayerController()

        cachedPlayerController =
            playerController
    end

    if playerController
        and playerController:IsValid()
        and playerController:HasAuthority()
    then
        local playerState =
            playerController.PlayerState

        if playerState
            and playerState:IsValid()
        then
            pendingOriginChests[
                playerState:GetFullName()
            ] = originChest
        end
    end

    QuickDeposit.triggerDepositSimilar()
end

-- Captures the vanilla target-data RPC and performs the SmartStorage fan-out.
local function registerTargetDataHook()
    RegisterHook(
        '/Script/GameplayAbilities.AbilitySystemComponent:ServerSetReplicatedTargetData',
        function()
        end,
        function(context, pAbilityHandle, pOrigKey, pTargetData, pAppTag, pCurKey)
            if inMultipass then
                return
            end

            local abilitySystemComponent = context:get()

            local abilityOwner =
                abilitySystemComponent:GetOwner()

            local playerId =
                tostring(abilityOwner.PlayerId)

            local playerKey =
                abilityOwner:GetFullName()

            local abilityHandle = pAbilityHandle:get()
            local originalPredictionKey = pOrigKey:get()
            local targetData = pTargetData:get()
            local applicationTag = pAppTag:get()
            local currentPredictionKey = pCurKey:get()

            handleQuickDeposit(
                abilitySystemComponent,
                abilityHandle,
                originalPredictionKey,
                targetData,
                applicationTag,
                currentPredictionKey,
                playerKey,
                playerId
            )
        end
    )

end

-- Injects the game's secondary-interact action to trigger Deposit Similar.
function QuickDeposit.triggerDepositSimilar()

    local secondaryInteractAction = StaticFindObject(
        '/Game/Gameplay/Game/Input/Actions/'
        .. 'IA_SecondaryInteract.'
        .. 'IA_SecondaryInteract'
    )

    if not secondaryInteractAction
        or not secondaryInteractAction:IsValid()
    then
        Log.warning(
            'Could not find IA_SecondaryInteract'
        )

        return
    end

    local inputSubsystem =
        cachedInputSubsystem

    if not inputSubsystem
        or not inputSubsystem:IsValid()
    then
        local subsystems =
            FindAllOf('EnhancedInputLocalPlayerSubsystem')

        if not subsystems or #subsystems == 0 then
            Log.warning(
                'No EnhancedInputLocalPlayerSubsystem found'
            )
            return
        end

        for _, candidate in ipairs(subsystems) do
            if candidate and candidate:IsValid() then
                inputSubsystem = candidate
                cachedInputSubsystem = candidate
                break
            end
        end
    end

    if not inputSubsystem then

        Log.warning(
            'No valid Enhanced Input subsystem found'
        )
        return
    end

    local okInjection, injectionError = pcall(function()
        inputSubsystem:InjectInputVectorForAction(
            secondaryInteractAction,
            {
                X = 1.0,
                Y = 0.0,
                Z = 0.0,
            },
            {},
            {}
        )
    end)

    if not okInjection then
        Log.warning(
            'IA_SecondaryInteract injection failed: %s',
            tostring(injectionError)
        )
    end
end

-- Arms exactly one SmartStorage fan-out when the vanilla Deposit Similar
-- ability appears. The actual chest is synchronized separately by the
-- client interaction model, so the dedicated server never needs a camera
-- trace for a remote player.
local function registerDepositSimilarObject()
    NotifyOnNewObject(
        '/Script/R5.R5Ability_InteractOption_Base',
        function(option)
            if not option or not option:IsValid() then
                return
            end

            if inMultipass then
                return
            end

            local className =
                option:GetClass():GetFullName()

            if not className:find(
                'GA_InteractOption_DepositSimilar_C',
                1,
                true
            ) then
                return
            end

            local owner =
                option:GetOuter()

            if not owner
                or not owner:IsValid()
            then
                return
            end

            local playerKey =
                owner:GetFullName()

            local playerId =
                tostring(owner.PlayerId)

            if playerModes[playerId] ~= 'expand' then
                return
            end

            expandActivationReady[playerKey] = true

        end
    )
end

local cachedContextHint = nil
local lastInteractionTarget = nil
local lastExpandOriginIdentifier = nil
local cachedPlayerController = nil
local cachedInputSubsystem = nil

function QuickDeposit.cachePlayerController()
    local playerController =
        UEHelpers:GetPlayerController()

    if playerController
        and playerController:IsValid()
    then
        cachedPlayerController =
            playerController
    end
end

-- Synchronizes the client's current expand interaction target to the server.
-- This runs when the UI target changes, normally well before Q is pressed.
local function syncExpandOriginToServer(chest)
    if Config.getModMode() ~= 'expand' then
        return
    end

    if not chest
        or not chest:IsValid()
        or not campChestClass
        or not chest:IsA(campChestClass)
    then
        return
    end

    local playerController =
        cachedPlayerController

    if not playerController
        or not playerController:IsValid()
    then
        playerController =
            UEHelpers:GetPlayerController()

        cachedPlayerController =
            playerController
    end

    if not playerController
        or not playerController:IsValid()
    then
        Log.debug(
            'Could not sync expand origin: PlayerController not found'
        )
        return
    end

    if playerController:HasAuthority() then
        local playerState =
            playerController.PlayerState

        if playerState
            and playerState:IsValid()
        then
            local playerKey =
                playerState:GetFullName()

            expandOriginChests[playerKey] =
                chest

            return
        end
    end

    local identity =
        Chest.getIdentity(chest)

    local identifier =
        Chest.getIdentifier(identity)

    if identifier == lastExpandOriginIdentifier then
        return
    end

    lastExpandOriginIdentifier =
        identifier

    playerController:ServerExecRPC(
        string.format(
            'SmartStorageExpandOrigin|%s',
            identifier
        )
    )
end

-- Extends the interaction UI with Deposit All and exclusion controls.
local function registerInteractionOptions()

    pcall(function()
        NotifyOnNewObject(
            '/Game/UI/HUD/Interaction/'
            .. 'WBP_ContextHint.WBP_ContextHint_C',
            function(hint)
                if not hint or not hint:IsValid() then
                    return
                end

                cachedContextHint = hint
            end
        )
    end)

    RegisterHook(
        '/Script/R5.R5InteractionTargetModel:GetInteractionOptions',
        function()
        end,
        function(context)

            local hint =
                cachedContextHint

            if not hint or not hint:IsValid() then

                local hints =
                    FindAllOf('WBP_ContextHint_C')

                if not hints or #hints == 0 then
                    return
                end

                hint = hints[1]

                if not hint or not hint:IsValid() then
                    return
                end

                cachedContextHint = hint
            end

        local box =
            hint.vbox_Options

        if not box or not box:IsValid() then
            return
        end

        local model =
            context:get()

        if not model or not model:IsValid() then
            return
        end

        local chest =
            model:GetInteractionTargetAvatar()

        if not chest or not chest:IsValid() then
            lastInteractionTarget = nil
            return
        end

        if chest == lastInteractionTarget then
            return
        end

        lastInteractionTarget = chest

        syncExpandOriginToServer(chest)

        local childCount =
            box:GetChildrenCount()

        if childCount < 2 then
            return
        end

        local vanillaDepositWidget =
            box:GetChildAt(1)

        if not vanillaDepositWidget
            or not vanillaDepositWidget:IsValid()
        then
            return
        end

        local option =
            vanillaDepositWidget.InteractionOption

        if not option or not option:IsValid() then
            return
        end

        local optionName =
            option:GetFullName()

        if not optionName:find(
            'DA_InteractOption_DepositSimilar',
            1,
            true
        ) then
            return
        end

        childCount =
            box:GetChildrenCount()

        if childCount == 2 then
            hint:CreateContextWidget()

            childCount =
                box:GetChildrenCount()

        end

        if Config.getModMode() == 'keybind'
            and childCount == 3
        then
            hint:CreateContextWidget()

            childCount =
                box:GetChildrenCount()

        end

        if Config.getModMode() == 'keybind' then
            local depositAllWidget =
                box:GetChildAt(2)

            if depositAllWidget
                and depositAllWidget:IsValid()
            then
                if not depositAllWidget.InteractionOption
                    or not depositAllWidget.InteractionOption:IsValid()
                then
                    depositAllWidget:InitOption(
                        option,
                        hint.RequirementContext
                    )
                end

                local depositInputHint =
                    depositAllWidget.uw_InputHint

                if depositInputHint
                    and depositInputHint:IsValid()
                then
                    local actionName =
                        depositInputHint.rtxt_ActionName

                    if actionName
                        and actionName:IsValid()
                    then
                        actionName:SetText(
                            FText('Deposit to all')
                        )
                    end

                    local inputActionShortcut =
                        depositInputHint.WBP_InputActionShortcut

                    if inputActionShortcut
                        and inputActionShortcut:IsValid()
                    then
                        local shortcut =
                            inputActionShortcut.uw_Shortcuts

                        if shortcut
                            and shortcut:IsValid()
                        then
                            local keyName =
                                shortcut.txt_KeyName

                            if keyName
                                and keyName:IsValid()
                            then
                                ExecuteWithDelay(
                                    0,
                                    function()
                                        ExecuteInGameThread(function()
                                            if keyName and keyName:IsValid() then
                                                keyName:SetText(
                                                    FText(
                                                        Config.getDepositAllKey():upper()
                                                    )
                                                )
                                            end
                                        end)
                                    end
                                )
                            end
                        end
                    end
                end
            end
        end

            local exclusionIndex =
                Config.getModMode() == 'keybind'
                and 3
                or 2

            local exclusionWidget =
                box:GetChildAt(exclusionIndex)

            if not exclusionWidget or not exclusionWidget:IsValid() then
                return
            end

            if exclusionWidget.InteractionOption
                and exclusionWidget.InteractionOption:IsValid()
            then
                return
            end

            exclusionWidget:InitOption(
                option,
                hint.RequirementContext
            )

            local inputHint =
                exclusionWidget.uw_InputHint

            if inputHint and inputHint:IsValid() then
                local actionName =
                    inputHint.rtxt_ActionName

                if actionName and actionName:IsValid() then
                    local record =
                        Chest.getExclusionRecord(chest)

                    local label =
                        Excluded.isExcluded(record.identifier)
                        and 'Include in SmartStorage'
                        or 'Exclude from SmartStorage'

                    actionName:SetText(
                        FText(label)
                    )
                end
                local inputActionShortcut =
                    inputHint.WBP_InputActionShortcut

                if inputActionShortcut
                    and inputActionShortcut:IsValid()
                then
                    local shortcut =
                        inputActionShortcut.uw_Shortcuts

                    if shortcut and shortcut:IsValid() then
                        local keyName =
                            shortcut.txt_KeyName

                        if keyName and keyName:IsValid() then
                            ExecuteWithDelay(
                                0,
                                function()
                                    ExecuteInGameThread(function()
                                        if keyName and keyName:IsValid() then
                                            keyName:SetText(
                                                FText(
                                                    Config.getExclusionKey():upper()
                                                )
                                            )
                                        end
                                    end)
                                end
                            )
                        end
                    end
                end
            end
        end
    )
end

-- Matches a client chest identifier to the server's nearby coordinates.
local function resolveServerIdentifier(
    clientIdentifier
)

    local graphChestType, graphNodeId =
        clientIdentifier:match(
            '^(.-)_G(%d+)$'
        )

    if graphChestType and graphNodeId then
        graphNodeId =
            tonumber(graphNodeId)

        for _, chest in ipairs(Chest.findAll()) do
            if chest:IsValid()
                and tonumber(chest.BuildingGraphNodeId) == graphNodeId
            then
                local identity =
                    Chest.getIdentity(chest)

                local serverIdentifier =
                    Chest.getIdentifier(identity)

                local serverChestType =
                    serverIdentifier:match(
                        '^(.-)_X'
                    )

                if serverChestType == graphChestType then
                    return serverIdentifier
                end
            end
        end
    end

    local chestType, x, y, z =
        clientIdentifier:match(
            '^(.-)_X(-?%d+)_Y(-?%d+)_Z(-?%d+)$'
        )

    if not chestType then
        return clientIdentifier
    end

    x = tonumber(x)
    y = tonumber(y)
    z = tonumber(z)

    for _, chest in ipairs(Chest.findAll()) do
        if chest:IsValid() then
            local identity =
                Chest.getIdentity(chest)

            local serverIdentifier =
                Chest.getIdentifier(
                    identity
                )

            local serverChestType =
                serverIdentifier:match(
                    '^(.-)_X'
                )

            if serverChestType == chestType
                and math.abs(identity.location.x - x) <= 1
                and math.abs(identity.location.y - y) <= 1
                and math.abs(identity.location.z - z) <= 1
            then
                return serverIdentifier
            end
        end
    end

    return clientIdentifier
end

-- Receives mode, origin, and exclusion synchronization messages from clients.
local function registerServerExecHook()
    RegisterHook(
        '/Script/Engine.PlayerController:ServerExecRPC',
        function(context, pMsg)
            local playerController =
                context:get()

            if not playerController
                or not playerController:IsValid()
            then
                return
            end

            local msg =
                pMsg:get():ToString()

            local playerMode =
                msg:match(
                    '^SmartStorageMode|(.+)$'
                )

            if playerMode ~= 'keybind'
                and playerMode ~= 'expand'
            then
                playerMode = nil
            end

            if playerMode then
                local playerState =
                    playerController.PlayerState

                if not playerState
                    or not playerState:IsValid()
                then
                    return
                end

                local playerId =
                    tostring(playerState.PlayerId)

                playerModes[playerId] =
                    playerMode

                return
            end

            local expandIdentifier =
                msg:match(
                    '^SmartStorageExpandOrigin|(.+)$'
                )

            if expandIdentifier then
                local playerState =
                    playerController.PlayerState

                if not playerState
                    or not playerState:IsValid()
                then
                    return
                end

                local playerKey =
                    playerState:GetFullName()

                local serverIdentifier =
                    resolveServerIdentifier(
                        expandIdentifier
                    )

                for _, chest in ipairs(Chest.findAll()) do
                    if chest:IsValid() then
                        local identity =
                            Chest.getIdentity(chest)

                        local identifier =
                            Chest.getIdentifier(
                                identity
                            )

                        if identifier == serverIdentifier then
                            expandOriginChests[playerKey] =
                                chest

                            return
                        end
                    end
                end

                Log.warning(
                    'Could not resolve Expand origin: %s',
                    tostring(expandIdentifier)
                )

                return
            end

            local armIdentifier =
                msg:match(
                    '^SmartStorageArm|(.+)$'
                )

            if armIdentifier then
                local playerState =
                    playerController.PlayerState

                if not playerState
                    or not playerState:IsValid()
                then
                    return
                end

                local playerKey =
                    playerState:GetFullName()

                local serverIdentifier =
                    resolveServerIdentifier(
                        armIdentifier
                    )

                for _, chest in ipairs(Chest.findAll()) do
                    if chest:IsValid() then
                        local identity =
                            Chest.getIdentity(chest)

                        local identifier =
                            Chest.getIdentifier(
                                identity
                            )

                        if identifier == serverIdentifier then
                            pendingOriginChests[playerKey] =
                                chest

                            return
                        end
                    end
                end

                Log.warning(
                    'Could not resolve Keybind origin: %s',
                    armIdentifier
                )

                return
            end
            if msg == 'SmartStorageClear' then
                local playerState =
                    playerController.PlayerState

                if not playerState
                    or not playerState:IsValid()
                then
                    return
                end

                local playerId =
                    tostring(playerState.PlayerId)

                playerExclusions[playerId] = {}

                return
            end

            local identifier, excludedValue =
                msg:match(
                    '^SmartStorage|(.+)|([01])$'
                )

            if not identifier then
                return
            end

            local playerState =
                playerController.PlayerState

            if not playerState
                or not playerState:IsValid()
            then
                return
            end

            local playerId =
                tostring(playerState.PlayerId)

            local isExcluded =
                excludedValue == '1'

            local serverIdentifier =
                resolveServerIdentifier(
                    identifier
                )

            setPlayerExcluded(
                playerId,
                serverIdentifier,
                isExcluded
            )
        end
    )
end

registerOwnerPointerProperty()
registerTargetDataHook()
registerInteractionOptions()
registerServerExecHook()

-- Refreshes the visible include/exclude label after a keybind toggle.
function QuickDeposit.refreshExclusionLabel(isExcluded)
    ExecuteWithDelay(
        50,
        function()
            ExecuteInGameThread(function()
                local hint =
                    cachedContextHint

                if not hint or not hint:IsValid() then
                    return
                end

                local box =
                    hint.vbox_Options

                if not box or not box:IsValid() then
                    return
                end

                if box:GetChildrenCount() < 3 then
                    return
                end

                local exclusionIndex =
                    Config.getModMode() == 'keybind'
                    and 3
                    or 2

                local exclusionWidget =
                    box:GetChildAt(exclusionIndex)

                if not exclusionWidget or not exclusionWidget:IsValid() then
                    return
                end

                local inputHint =
                    exclusionWidget.uw_InputHint

                if not inputHint or not inputHint:IsValid() then
                    return
                end

                local actionName =
                    inputHint.rtxt_ActionName

                if not actionName or not actionName:IsValid() then
                    return
                end

                actionName:SetText(
                    FText(
                        isExcluded
                        and 'Include in SmartStorage'
                        or 'Exclude from SmartStorage'
                    )
                )
            end)
        end
    )
end

registerDepositSimilarObject()

return QuickDeposit

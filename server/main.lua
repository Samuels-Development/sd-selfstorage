local Config = require('config')
local unitRentals = {}
local playerRentals = {}
local locale = Locale.T

Locale.LoadLocale('en')

--- Banking Interface - Customize these functions for your banking system
local Banking = {}

--- Get player's bank account identifier
---@param identifier string Player identifier
---@return string|nil accountId Bank account identifier or nil
Banking.GetPlayerAccount = function(identifier)
    -- Example Integration with RxBanking
    --[[ local accountData = exports['RxBanking']:GetPlayerPersonalAccount(identifier)
        if type(accountData) == "table" then
            return accountData.iban
        elseif type(accountData) == "string" then
            return accountData
        end 
    ]]
    return nil 
end

--- Remove money from bank account (for auto-renewal)
---@param accountId string Bank account identifier
---@param amount number Amount to remove
---@param unitId number Storage unit ID
---@return boolean success Whether the transaction was successful
Banking.RemoveAccountMoney = function(accountId, amount, unitId)
    -- Example Integration with RxBanking
    --[[
    return exports['RxBanking']:RemoveAccountMoney(accountId, amount, 'payment', locale('storage_unit_autorenewal', { id = unitId }), nil)
    ]]
    return nil 
end


-- These two functions you can leave untouched.

--- Remove money from player (cash or bank)
---@param source number Player source
---@param paymentMethod string 'cash' or 'bank'
---@param amount number Amount to remove
---@return boolean success Whether the removal was successful
Banking.RemovePlayerMoney = function(source, paymentMethod, amount)
    Money.RemoveMoney(source, paymentMethod, amount)
    return true
end

--- Check if player has enough money
---@param source number Player source
---@param paymentMethod string 'cash' or 'bank'
---@param amount number Amount to check
---@return boolean hasEnough Whether player has enough money
Banking.HasEnoughMoney = function(source, paymentMethod, amount)
    return Money.GetPlayerAccountFunds(source, paymentMethod) >= amount
end

--- Initialize database and create storage tables
CreateThread(function()
    local success, err = pcall(function()
        MySQL.query.await([[
            CREATE TABLE IF NOT EXISTS storage_rentals (
                lockerIdentifier VARCHAR(255) PRIMARY KEY,
                ownerIdentifier VARCHAR(255) NOT NULL,
                unitId INT NOT NULL,
                rentedAt TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                lockerData JSON NOT NULL,
                bankAccount VARCHAR(255) DEFAULT NULL,
                INDEX idx_unit (unitId),
                INDEX idx_owner (ownerIdentifier),
                INDEX idx_unit_owner (unitId, ownerIdentifier)
            );
        ]])
    end)
    if not success then
        print("Error creating storage database:", err)
    else
        print("^2Storage database initialized successfully")
    end

    local rentals = MySQL.query.await('SELECT * FROM storage_rentals', {})
    if rentals then
        for _, rental in pairs(rentals) do
            local lockerData = json.decode(rental.lockerData)

            local currentTime = os.time()
            local expiresAt = lockerData.expiresAt or currentTime + 86400
            local graceEnds = lockerData.paymentGraceEnds

            if lockerData.purchased or expiresAt > currentTime or (graceEnds and graceEnds > currentTime) then
                if not unitRentals[rental.unitId] then
                    unitRentals[rental.unitId] = {}
                end
                
                unitRentals[rental.unitId][rental.ownerIdentifier] = {
                    lockerIdentifier = rental.lockerIdentifier,
                    ownerIdentifier = rental.ownerIdentifier,
                    lockerData = lockerData,
                    bankAccount = rental.bankAccount
                }

                if not playerRentals[rental.ownerIdentifier] then
                    playerRentals[rental.ownerIdentifier] = { owned = nil, accesses = {} }
                end
                
                playerRentals[rental.ownerIdentifier].owned = {
                    unitId = rental.unitId,
                    lockerIdentifier = rental.lockerIdentifier,
                    lockerData = lockerData,
                    bankAccount = rental.bankAccount
                }

                if lockerData.collaborators then
                    for _, collaborator in pairs(lockerData.collaborators) do
                        if not playerRentals[collaborator.identifier] then
                            playerRentals[collaborator.identifier] = { owned = nil, accesses = {} }
                        end
                        
                        table.insert(playerRentals[collaborator.identifier].accesses, {
                            unitId = rental.unitId,
                            ownerIdentifier = rental.ownerIdentifier,
                            lockerIdentifier = rental.lockerIdentifier,
                            lockerData = lockerData
                        })
                    end
                end
                
                local stashId = 'storage_' .. rental.unitId .. '_' .. rental.ownerIdentifier
                local slots = Config.DefaultLimits.slots
                local weight = Config.DefaultLimits.weight
                
                if lockerData.upgrades then
                    for upgradeId, count in pairs(lockerData.upgrades) do
                        local upgradeConfig = Config.Pricing.upgrades[upgradeId]
                        if upgradeConfig and upgradeConfig.effect then
                            if upgradeConfig.effect.type == "slots" then
                                slots = slots + (upgradeConfig.effect.value * count)
                            elseif upgradeConfig.effect.type == "weight" then
                                weight = weight + (upgradeConfig.effect.value * count)
                            end
                        end
                    end
                end
                
                exports.ox_inventory:RegisterStash(stashId, 'Storage Unit #' .. rental.unitId .. ' - ' .. rental.ownerIdentifier:sub(1, 8), slots, weight, rental.ownerIdentifier)
            end
        end
        print("^2Loaded " .. #rentals .. " storage rentals")
    end
end)

--- Update locker data in database
---@param unitId number Unit ID to update
---@param ownerIdentifier string Owner identifier
---@param newData table New data to merge
---@return boolean success Whether the update was successful
local UpdateLockerData = function(unitId, ownerIdentifier, newData)
    if not unitRentals[unitId] or not unitRentals[unitId][ownerIdentifier] then 
        return false 
    end
    
    local rental = unitRentals[unitId][ownerIdentifier]

    for key, value in pairs(newData) do
        rental.lockerData[key] = value
    end

    MySQL.query.await('UPDATE storage_rentals SET lockerData = ? WHERE lockerIdentifier = ?', {
        json.encode(rental.lockerData),
        rental.lockerIdentifier
    })

    return true
end

--- Get total owners for a unit
---@param unitId number Unit ID to check
---@return number count Total number of owners
local GetTotalOwners = function(unitId)
    if not unitRentals[unitId] then return 0 end
    
    local count = 0
    for _ in pairs(unitRentals[unitId]) do
        count = count + 1
    end
    
    return count
end

--- Get total renters for a specific owner's unit
---@param unitId number Unit ID to check
---@param ownerIdentifier string Owner identifier
---@return number count Total number of renters including owner
local GetTotalRenters = function(unitId, ownerIdentifier)
    if not unitRentals[unitId] or not unitRentals[unitId][ownerIdentifier] then 
        return 0 
    end
    
    local rental = unitRentals[unitId][ownerIdentifier]
    return 1 + (rental.lockerData.collaborators and #rental.lockerData.collaborators or 0)
end

--- Get all storages player has access to on a specific unit
---@param source number Player source
---@param unitId number Storage unit ID
---@return table[] storages List of accessible storages
lib.callback.register('storage:getUnitAccesses', function(source, unitId)
    local player = GetPlayer(source)
    if not player then return {} end

    local identifier = GetIdentifier(source)
    local storages = {}
    
    if not playerRentals[identifier] then
        return {}
    end
    
    if playerRentals[identifier].owned and playerRentals[identifier].owned.unitId == unitId then
        table.insert(storages, {
            stashId = 'storage_' .. unitId .. '_' .. identifier,
            label = locale('your_storage'),
            isOwner = true,
            ownerIdentifier = identifier
        })
    end
    
    for _, access in ipairs(playerRentals[identifier].accesses) do
        if access.unitId == unitId then
            local ownerData = GetPlayerFromIdentifier(access.ownerIdentifier)
            local ownerName = ownerData and GetFullName(ownerData.PlayerData.source) or "Unknown"
            
            table.insert(storages, {
                stashId = 'storage_' .. unitId .. '_' .. access.ownerIdentifier,
                label = locale('someones_storage', { name = ownerName }),
                isOwner = false,
                ownerIdentifier = access.ownerIdentifier
            })
        end
    end
    
    return storages
end)

--- Check if player has access to storage unit (backwards compatibility)
---@param source number Player source
---@param unitId number Storage unit ID
---@return boolean hasAccess Whether the player has access
---@return string|nil stashId The stash identifier if player has access
lib.callback.register('storage:hasAccess', function(source, unitId)
    local player = GetPlayer(source)
    if not player then return false, nil end

    local identifier = GetIdentifier(source)
    
    if not playerRentals[identifier] then
        return false, nil
    end
    
    if playerRentals[identifier].owned and playerRentals[identifier].owned.unitId == unitId then
        return true, 'storage_' .. unitId .. '_' .. identifier
    end
    
    for _, access in ipairs(playerRentals[identifier].accesses) do
        if access.unitId == unitId then
            return true, 'storage_' .. unitId .. '_' .. access.ownerIdentifier
        end
    end
    
    return false, nil
end)

--- Get player's rental info
---@param source number Player source
---@return table|nil rentalInfo Rental information or nil if none
lib.callback.register('storage:getRentalInfo', function(source)
    local player = GetPlayer(source)
    if not player then return nil end

    local identifier = GetIdentifier(source)
    
    if not playerRentals[identifier] then
        return nil
    end
    
    local rental = playerRentals[identifier].owned
    
    if rental then
        return {
            unitId = rental.unitId,
            isOwner = true,
            autoRenewal = rental.lockerData.autoRenewal,
            expiresAt = os.date('%Y-%m-%d %H:%M:%S', rental.lockerData.expiresAt),
            purchased = rental.lockerData.purchased,
            lockerIdentifier = rental.lockerIdentifier,
            ownerIdentifier = identifier
        }
    elseif #playerRentals[identifier].accesses > 0 then
        local access = playerRentals[identifier].accesses[1]
        return {
            unitId = access.unitId,
            isOwner = false,
            autoRenewal = access.lockerData.autoRenewal,
            expiresAt = os.date('%Y-%m-%d %H:%M:%S', access.lockerData.expiresAt),
            purchased = access.lockerData.purchased,
            lockerIdentifier = access.lockerIdentifier,
            ownerIdentifier = access.ownerIdentifier
        }
    end

    return nil
end)

--- Get available units (only shows units that haven't reached max owners)
---@param source number Player source
---@return table[] availableUnits List of available units
lib.callback.register('storage:getAvailableUnits', function(source)
    local availableUnits = {}

    for _, storage in pairs(Config.Storages) do
        local totalOwners = GetTotalOwners(storage.id)
        local available = totalOwners < Config.Rental.maxOwnersPerUnit
        
        table.insert(availableUnits, {
            id = storage.id,
            name = storage.name,
            available = available
        })
    end

    return availableUnits
end)

--- Validate stash access before opening
---@param source number Player source
---@param stashId string Stash identifier to validate
---@return boolean canOpen Whether the player can open the stash
lib.callback.register('storage:validateAndOpenStash', function(source, stashId)
    local player = GetPlayer(source)
    if not player then return false end
    
    local identifier = GetIdentifier(source)
    
    if not stashId or not string.find(stashId, "storage_") then
        return false
    end
    
    local parts = {}
    for part in string.gmatch(stashId, "[^_]+") do
        table.insert(parts, part)
    end
    
    if #parts < 3 then return false end
    
    local unitId = tonumber(parts[2])
    local ownerIdentifier = table.concat({table.unpack(parts, 3)}, "_")
    
    if not unitId or not ownerIdentifier then
        return false
    end
    
    if ownerIdentifier == identifier then
        return playerRentals[identifier] and 
               playerRentals[identifier].owned and 
               playerRentals[identifier].owned.unitId == unitId
    end
    
    if playerRentals[identifier] and playerRentals[identifier].accesses then
        for _, access in ipairs(playerRentals[identifier].accesses) do
            if access.unitId == unitId and access.ownerIdentifier == ownerIdentifier then
                return true
            end
        end
    end
    
    return false
end)

--- Rent a storage unit
---@param source number Player source
---@param unitId number Storage unit ID
---@param paymentMethod string Payment method ('cash' or 'bank')
---@return boolean success Whether the rental was successful
---@return string message Response message
lib.callback.register('storage:rentUnit', function(source, unitId, paymentMethod)
    if not Config.Pricing.enableRent then
        return false, locale('rent_disabled')
    end
    
    local player = GetPlayer(source)
    if not player then return false, locale('player_not_found') end

    local identifier = GetIdentifier(source)
    paymentMethod = paymentMethod or 'cash'

    local totalOwners = GetTotalOwners(unitId)
    if totalOwners >= Config.Rental.maxOwnersPerUnit then
        return false, locale('unit_full_max_owners')
    end
    
    if unitRentals[unitId] and unitRentals[unitId][identifier] then
        return false, locale('already_own_on_unit')
    end
    
    if playerRentals[identifier] and playerRentals[identifier].owned then
        return false, locale('already_own_unit', { id = playerRentals[identifier].owned.unitId })
    end

    if not Banking.HasEnoughMoney(source, paymentMethod, Config.Pricing.rent) then
        return false, locale('insufficient_funds', { method = paymentMethod, price = Config.Pricing.rent })
    end

    if not Banking.RemovePlayerMoney(source, paymentMethod, Config.Pricing.rent) then
        return false, locale('payment_failed')
    end
    
    local bankAccount = Banking.GetPlayerAccount(identifier)

    local lockerIdentifier = unitId .. "-" .. identifier
    local currentTime = os.time()
    
    local lockerData = {
        collaborators = {},
        autoRenewal = false,
        expiresAt = currentTime + Config.Rental.duration,
        nextPaymentDue = currentTime + Config.Rental.duration,
        paymentGraceEnds = nil,
        upgrades = {},
        purchased = false,
        rentedAt = currentTime
    }

    MySQL.insert.await('INSERT INTO storage_rentals (lockerIdentifier, ownerIdentifier, unitId, lockerData, bankAccount) VALUES (?, ?, ?, ?, ?)', {
        lockerIdentifier,
        identifier,
        unitId,
        json.encode(lockerData),
        bankAccount
    })

    if not unitRentals[unitId] then
        unitRentals[unitId] = {}
    end
    
    unitRentals[unitId][identifier] = {
        lockerIdentifier = lockerIdentifier,
        ownerIdentifier = identifier,
        lockerData = lockerData,
        bankAccount = bankAccount
    }

    if not playerRentals[identifier] then
        playerRentals[identifier] = { owned = nil, accesses = {} }
    end
    
    playerRentals[identifier].owned = {
        unitId = unitId,
        lockerIdentifier = lockerIdentifier,
        lockerData = lockerData,
        bankAccount = bankAccount
    }
    
    local stashId = 'storage_' .. unitId .. '_' .. identifier
    exports.ox_inventory:RegisterStash(stashId, 'Storage Unit #' .. unitId .. ' - ' .. identifier:sub(1, 8), Config.DefaultLimits.slots, Config.DefaultLimits.weight, identifier)

    return true, locale('rent_success', { id = unitId })
end)

--- Get unit collaborators - owner only
---@param source number Player source
---@param unitId number Storage unit ID
---@return table[]|false collaborators List of collaborators or false on error
---@return string|nil message Error message if applicable
lib.callback.register('storage:getCollaborators', function(source, unitId)
    local player = GetPlayer(source)
    if not player then return false, locale('player_not_found') end

    local identifier = GetIdentifier(source)
    
    if not playerRentals[identifier] or not playerRentals[identifier].owned or 
       playerRentals[identifier].owned.unitId ~= unitId then
        return false, locale('not_owner')
    end

    local collaborators = {}
    
    if unitRentals[unitId] and unitRentals[unitId][identifier] then
        local unitRental = unitRentals[unitId][identifier]
        
        local ownerData = GetPlayerFromIdentifier(identifier)
        local ownerName = ownerData and GetFullName(ownerData.PlayerData.source) or "Unknown"

        table.insert(collaborators, {
            identifier = identifier,
            name = ownerName,
            isOwner = true,
            expiresAt = os.date('%Y-%m-%d %H:%M:%S', unitRental.lockerData.expiresAt)
        })

        if unitRental.lockerData.collaborators then
            for _, collaborator in pairs(unitRental.lockerData.collaborators) do
                local playerData = GetPlayerFromIdentifier(collaborator.identifier)
                local name = playerData and GetFullName(playerData.PlayerData.source) or "Unknown"

                table.insert(collaborators, {
                    identifier = collaborator.identifier,
                    name = collaborator.name or name,
                    isOwner = false
                })
            end
        end
    end

    return collaborators
end)

--- Grant access to player - owner only
---@param source number Player source
---@param unitId number Storage unit ID
---@param targetSource number Target player source
---@return boolean success Whether the operation was successful
---@return string message Response message
lib.callback.register('storage:grantAccess', function(source, unitId, targetSource)
    local player = GetPlayer(source)
    local targetPlayer = GetPlayer(targetSource)

    if not player or not targetPlayer then
        return false, "Player not found"
    end

    local identifier = GetIdentifier(source)
    local targetIdentifier = GetIdentifier(targetSource)
    
    if not playerRentals[identifier] or not playerRentals[identifier].owned or 
       playerRentals[identifier].owned.unitId ~= unitId then
        return false, locale('not_owner')
    end
    
    if not playerRentals[targetIdentifier] then
        playerRentals[targetIdentifier] = { owned = nil, accesses = {} }
    end

    for _, access in ipairs(playerRentals[targetIdentifier].accesses) do
        if access.unitId == unitId and access.ownerIdentifier == identifier then
            return false, locale('already_has_access')
        end
    end

    local currentRenters = GetTotalRenters(unitId, identifier)
    if currentRenters >= Config.Rental.maxRentersPerUnit then
        return false, locale('storage_full_users', { max = Config.Rental.maxRentersPerUnit })
    end

    local unitRental = unitRentals[unitId][identifier]
    if not unitRental then
        return false, locale('storage_not_found')
    end

    local targetName = GetFullName(targetSource)
    
    table.insert(unitRental.lockerData.collaborators, {
        identifier = targetIdentifier,
        name = targetName,
        addedAt = os.time()
    })

    UpdateLockerData(unitId, identifier, { collaborators = unitRental.lockerData.collaborators })

    table.insert(playerRentals[targetIdentifier].accesses, {
        unitId = unitId,
        ownerIdentifier = identifier,
        lockerIdentifier = unitRental.lockerIdentifier,
        lockerData = unitRental.lockerData
    })

    TriggerClientEvent('storage:accessGranted', targetSource, {
        unitId = unitId,
        ownerName = GetFullName(source)
    })

    return true, locale('access_granted_to', { name = targetName })
end)

--- Remove collaborator - owner only
---@param source number Player source
---@param unitId number Storage unit ID
---@param targetIdentifier string Target player identifier
---@return boolean success Whether the operation was successful
---@return string message Response message
lib.callback.register('storage:removeCollaborator', function(source, unitId, targetIdentifier)
    local player = GetPlayer(source)
    if not player then return false, locale('player_not_found') end

    local identifier = GetIdentifier(source)
    
    if not playerRentals[identifier] or not playerRentals[identifier].owned or 
       playerRentals[identifier].owned.unitId ~= unitId then
        return false, locale('not_owner')
    end

    local unitRental = unitRentals[unitId][identifier]
    if not unitRental then
        return false, locale('storage_not_found')
    end

    for i, collaborator in ipairs(unitRental.lockerData.collaborators) do
        if collaborator.identifier == targetIdentifier then
            table.remove(unitRental.lockerData.collaborators, i)
            break
        end
    end

    UpdateLockerData(unitId, identifier, { collaborators = unitRental.lockerData.collaborators })
    
    if playerRentals[targetIdentifier] and playerRentals[targetIdentifier].accesses then
        for i, access in ipairs(playerRentals[targetIdentifier].accesses) do
            if access.unitId == unitId and access.ownerIdentifier == identifier then
                table.remove(playerRentals[targetIdentifier].accesses, i)
                break
            end
        end
    end

    return true, locale('access_removed')
end)

--- Update bank account for storage
---@param source number Player source
---@return boolean success Whether the operation was successful
---@return string message Response message
lib.callback.register('storage:updateBankAccount', function(source)
    local player = GetPlayer(source)
    if not player then return false, locale('player_not_found') end

    local identifier = GetIdentifier(source)
    
    if not playerRentals[identifier] or not playerRentals[identifier].owned then
        return false, locale('no_storage_rented')
    end

    local rental = playerRentals[identifier].owned
    
    local bankAccount = Banking.GetPlayerAccount(identifier)
    
    if not bankAccount then
        return false, locale('no_bank_account')
    end
    
    if unitRentals[rental.unitId] and unitRentals[rental.unitId][identifier] then
        unitRentals[rental.unitId][identifier].bankAccount = bankAccount
        rental.bankAccount = bankAccount
        MySQL.query.await('UPDATE storage_rentals SET bankAccount = ? WHERE lockerIdentifier = ?', {
            bankAccount,
            rental.lockerIdentifier
        })
    end

    return true, locale('bank_account_updated', { account = bankAccount })
end)

--- Toggle auto-renewal
---@param source number Player source
---@return boolean success Whether the operation was successful
---@return string message Response message
lib.callback.register('storage:toggleAutoRenewal', function(source)
    local player = GetPlayer(source)
    if not player then return false, locale('player_not_found') end

    if not Config.Banking.hasStaticIdentifiers then
        return false, Config.Banking.noIdentifierMessage or locale('auto_renewal_not_supported')
    end

    local identifier = GetIdentifier(source)
    
    if not playerRentals[identifier] or not playerRentals[identifier].owned then
        return false, locale('no_storage_rented')
    end

    local rental = playerRentals[identifier].owned
    local newAutoRenewal = not rental.lockerData.autoRenewal
    
    if newAutoRenewal then
        local bankAccount = Banking.GetPlayerAccount(identifier)
        if not bankAccount then
            return false, locale('no_bank_account_for_auto_renewal')
        end
        if bankAccount and unitRentals[rental.unitId] and unitRentals[rental.unitId][identifier] then
            unitRentals[rental.unitId][identifier].bankAccount = bankAccount
            rental.bankAccount = bankAccount
            MySQL.query.await('UPDATE storage_rentals SET bankAccount = ? WHERE lockerIdentifier = ?', {
                bankAccount,
                rental.lockerIdentifier
            })
        end
    end
    
    UpdateLockerData(rental.unitId, identifier, { autoRenewal = newAutoRenewal })

    return true, locale('auto_renewal_toggled', { status = newAutoRenewal and locale('enabled') or locale('disabled') })
end)

--- Purchase storage unit - permanent ownership
---@param source number Player source
---@param unitId number Storage unit ID
---@param paymentMethod string Payment method ('cash' or 'bank')
---@return boolean success Whether the purchase was successful
---@return string message Response message
lib.callback.register('storage:purchaseUnit', function(source, unitId, paymentMethod)
    if not Config.Pricing.enableBuy then
        return false, locale('purchase_disabled')
    end
    
    local player = GetPlayer(source)
    if not player then return false, locale('player_not_found') end

    local identifier = GetIdentifier(source)
    paymentMethod = paymentMethod or 'cash'

    local totalOwners = GetTotalOwners(unitId)
    if totalOwners >= Config.Rental.maxOwnersPerUnit then
        return false, locale('unit_full_max_owners')
    end
    
    -- Check if player already owns storage on this unit
    if unitRentals[unitId] and unitRentals[unitId][identifier] then
        return false, locale('already_own_on_unit')
    end
    
    if playerRentals[identifier] and playerRentals[identifier].owned then
        return false, locale('already_own_unit', { id = playerRentals[identifier].owned.unitId })
    end

    if not Banking.HasEnoughMoney(source, paymentMethod, Config.Pricing.purchase) then
        return false, locale('insufficient_funds', { method = paymentMethod, price = Config.Pricing.purchase })
    end

    if not Banking.RemovePlayerMoney(source, paymentMethod, Config.Pricing.purchase) then
        return false, locale('payment_failed')
    end
    
    local bankAccount = Banking.GetPlayerAccount(identifier)

    local lockerIdentifier = unitId .. "-" .. identifier
    local currentTime = os.time()

    local lockerData = {
        collaborators = {},
        autoRenewal = false,
        expiresAt = currentTime + (100 * 365 * 24 * 60 * 60),
        nextPaymentDue = nil,
        paymentGraceEnds = nil,
        upgrades = {},
        purchased = true,
        purchasedAt = currentTime
    }

    MySQL.insert.await('INSERT INTO storage_rentals (lockerIdentifier, ownerIdentifier, unitId, lockerData, bankAccount) VALUES (?, ?, ?, ?, ?)', {
        lockerIdentifier,
        identifier,
        unitId,
        json.encode(lockerData),
        bankAccount
    })

    if not unitRentals[unitId] then
        unitRentals[unitId] = {}
    end
    
    unitRentals[unitId][identifier] = {
        lockerIdentifier = lockerIdentifier,
        ownerIdentifier = identifier,
        lockerData = lockerData,
        bankAccount = bankAccount
    }

    if not playerRentals[identifier] then
        playerRentals[identifier] = { owned = nil, accesses = {} }
    end
    
    playerRentals[identifier].owned = {
        unitId = unitId,
        lockerIdentifier = lockerIdentifier,
        lockerData = lockerData,
        bankAccount = bankAccount
    }
    
    local stashId = 'storage_' .. unitId .. '_' .. identifier
    exports.ox_inventory:RegisterStash(stashId, 'Storage Unit #' .. unitId .. ' - ' .. identifier:sub(1, 8), Config.DefaultLimits.slots, Config.DefaultLimits.weight, identifier)

    return true, locale('purchase_success', { id = unitId })
end)

--- Delete storage unit - owner only
---@param source number Player source
---@param unitId number Storage unit ID
---@return boolean success Whether the deletion was successful
---@return string message Response message
lib.callback.register('storage:deleteUnit', function(source, unitId)
    local player = GetPlayer(source)
    if not player then return false, locale('player_not_found') end

    local identifier = GetIdentifier(source)
    
    if not playerRentals[identifier] or not playerRentals[identifier].owned or 
       playerRentals[identifier].owned.unitId ~= unitId then
        return false, locale('not_owner')
    end

    local stashId = 'storage_' .. unitId .. '_' .. identifier
    exports.ox_inventory:ClearInventory(stashId)
    
    MySQL.query.await('DELETE FROM storage_rentals WHERE lockerIdentifier = ?', { 
        playerRentals[identifier].owned.lockerIdentifier 
    })

    if unitRentals[unitId] and unitRentals[unitId][identifier] then
        local unitRental = unitRentals[unitId][identifier]
        
        playerRentals[identifier].owned = nil

        if unitRental.lockerData.collaborators then
            for _, collaborator in pairs(unitRental.lockerData.collaborators) do
                if playerRentals[collaborator.identifier] and playerRentals[collaborator.identifier].accesses then
                    for i, access in ipairs(playerRentals[collaborator.identifier].accesses) do
                        if access.unitId == unitId and access.ownerIdentifier == identifier then
                            table.remove(playerRentals[collaborator.identifier].accesses, i)
                            break
                        end
                    end
                end
            end
        end

        unitRentals[unitId][identifier] = nil
        
        local hasOwners = false
        for _ in pairs(unitRentals[unitId]) do
            hasOwners = true
            break
        end
        
        if not hasOwners then
            unitRentals[unitId] = nil
        end
    end

    return true, locale('unit_deleted_success')
end)

--- Get payment information for a player
---@param source number Player source
---@return table|nil paymentInfo Payment information or nil if none
lib.callback.register('storage:getPaymentInfo', function(source)
    local player = GetPlayer(source)
    if not player then return nil end
    
    local identifier = GetIdentifier(source)
    
    if not playerRentals[identifier] or not playerRentals[identifier].owned then
        return nil
    end
    
    local rental = playerRentals[identifier].owned
    
    if rental.lockerData.purchased then
        return nil
    end
    
    local currentTime = os.time()
    local nextPayment = rental.lockerData.nextPaymentDue or currentTime
    local graceEnds = rental.lockerData.paymentGraceEnds
    
    local bankAccount = rental.bankAccount
    if not bankAccount then
        bankAccount = Banking.GetPlayerAccount(identifier)
        if bankAccount and unitRentals[rental.unitId] and unitRentals[rental.unitId][identifier] then
            unitRentals[rental.unitId][identifier].bankAccount = bankAccount
            rental.bankAccount = bankAccount
            MySQL.query.await('UPDATE storage_rentals SET bankAccount = ? WHERE lockerIdentifier = ?', {
                bankAccount,
                rental.lockerIdentifier
            })
        end
    end
    
    return {
        nextPaymentDue = os.date('%Y-%m-%d %H:%M:%S', nextPayment),
        paymentGraceEnds = graceEnds and os.date('%Y-%m-%d %H:%M:%S', graceEnds) or nil,
        timeUntilPayment = nextPayment - currentTime,
        timeUntilDeletion = graceEnds and (graceEnds - currentTime) or nil,
        isOverdue = nextPayment <= currentTime,
        inGracePeriod = graceEnds ~= nil and graceEnds > currentTime,
        bankAccount = bankAccount
    }
end)

--- Make payment
---@param source number Player source
---@param paymentMethod string Payment method ('cash' or 'bank')
---@return boolean success Whether the payment was successful
---@return string message Response message
lib.callback.register('storage:makePayment', function(source, paymentMethod)
    local player = GetPlayer(source)
    if not player then return false, locale('player_not_found') end
    
    local identifier = GetIdentifier(source)
    paymentMethod = paymentMethod or 'cash'
    
    if not playerRentals[identifier] or not playerRentals[identifier].owned then
        return false, locale('no_rental_or_owned')
    end
    
    local rental = playerRentals[identifier].owned
    
    if rental.lockerData.purchased then
        return false, locale('unit_owned_no_payment')
    end
    
    if not Banking.HasEnoughMoney(source, paymentMethod, Config.Pricing.rent) then
        return false, locale('insufficient_funds', { method = paymentMethod, price = Config.Pricing.rent })
    end
    
    if not Banking.RemovePlayerMoney(source, paymentMethod, Config.Pricing.rent) then
        return false, locale('payment_failed')
    end
    
    local nextPayment = os.time() + Config.Rental.duration
    
    UpdateLockerData(rental.unitId, identifier, {
        nextPaymentDue = nextPayment,
        paymentGraceEnds = nil
    })
    
    return true, locale('payment_success', { date = os.date('%Y-%m-%d %H:%M:%S', nextPayment) })
end)

--- Get available upgrades for a unit
---@param source number Player source
---@param unitId number Storage unit ID
---@return table|false upgradeData Upgrade information or false on error
---@return string|nil message Error message if applicable
lib.callback.register('storage:getAvailableUpgrades', function(source, unitId)
    local player = GetPlayer(source)
    if not player then return false, locale('player_not_found') end
    
    local identifier = GetIdentifier(source)
    
    if not playerRentals[identifier] or not playerRentals[identifier].owned or 
       playerRentals[identifier].owned.unitId ~= unitId then
        return false, locale('not_owner')
    end
    
    local rental = playerRentals[identifier].owned
    local currentUpgrades = rental.lockerData.upgrades or {}
    local availableUpgrades = {}
    
    for upgradeId, upgradeConfig in pairs(Config.Pricing.upgrades) do
        local currentCount = currentUpgrades[upgradeId] or 0
        local canPurchase = currentCount < upgradeConfig.maxStack
        
        if canPurchase then
            table.insert(availableUpgrades, {
                id = upgradeId,
                name = upgradeConfig.name,
                description = upgradeConfig.description,
                price = upgradeConfig.price,
                effect = upgradeConfig.effect,
                currentCount = currentCount,
                maxStack = upgradeConfig.maxStack
            })
        end
    end
    
    local currentSlots = Config.DefaultLimits.slots
    local currentWeight = Config.DefaultLimits.weight
    
    for upgradeId, count in pairs(currentUpgrades) do
        local upgradeConfig = Config.Pricing.upgrades[upgradeId]
        if upgradeConfig and upgradeConfig.effect then
            if upgradeConfig.effect.type == "slots" then
                currentSlots = currentSlots + (upgradeConfig.effect.value * count)
            elseif upgradeConfig.effect.type == "weight" then
                currentWeight = currentWeight + (upgradeConfig.effect.value * count)
            end
        end
    end
    
    return {
        upgrades = availableUpgrades,
        currentLimits = {
            slots = currentSlots,
            weight = currentWeight
        },
        currentUpgrades = currentUpgrades
    }
end)

--- Purchase upgrade
---@param source number Player source
---@param unitId number Storage unit ID
---@param upgradeId string Upgrade identifier
---@param paymentMethod string Payment method ('cash' or 'bank')
---@return boolean success Whether the upgrade was purchased
---@return string message Response message
lib.callback.register('storage:purchaseUpgrade', function(source, unitId, upgradeId, paymentMethod)
    local player = GetPlayer(source)
    if not player then return false, locale('player_not_found') end
    
    local identifier = GetIdentifier(source)
    paymentMethod = paymentMethod or 'cash'
    
    if not playerRentals[identifier] or not playerRentals[identifier].owned or 
       playerRentals[identifier].owned.unitId ~= unitId then
        return false, locale('not_owner')
    end
    
    local rental = playerRentals[identifier].owned
    local upgradeConfig = Config.Pricing.upgrades[upgradeId]
    if not upgradeConfig then
        return false, locale('invalid_upgrade')
    end
    
    if not Banking.HasEnoughMoney(source, paymentMethod, upgradeConfig.price) then
        return false, locale('insufficient_funds', { method = paymentMethod, price = upgradeConfig.price })
    end
    
    local currentUpgrades = rental.lockerData.upgrades or {}
    local currentCount = currentUpgrades[upgradeId] or 0
    
    if currentCount >= upgradeConfig.maxStack then
        return false, locale('max_upgrades_purchased')
    end
    
    if not Banking.RemovePlayerMoney(source, paymentMethod, upgradeConfig.price) then
        return false, locale('payment_failed')
    end
    
    currentUpgrades[upgradeId] = currentCount + 1
    UpdateLockerData(unitId, identifier, { upgrades = currentUpgrades })
    
    local newSlots = Config.DefaultLimits.slots
    local newWeight = Config.DefaultLimits.weight
    
    for upgradeId, count in pairs(currentUpgrades) do
        local upgradeConfig = Config.Pricing.upgrades[upgradeId]
        if upgradeConfig and upgradeConfig.effect then
            if upgradeConfig.effect.type == "slots" then
                newSlots = newSlots + (upgradeConfig.effect.value * count)
            elseif upgradeConfig.effect.type == "weight" then
                newWeight = newWeight + (upgradeConfig.effect.value * count)
            end
        end
    end
    
    local stashId = 'storage_' .. unitId .. '_' .. identifier
    exports.ox_inventory:RegisterStash(stashId, 'Storage Unit #' .. unitId .. ' - ' .. identifier:sub(1, 8), newSlots, newWeight, identifier)
    
    return true, locale('upgrade_purchased', { slots = newSlots, weight = (newWeight/1000) })
end)

--- Payment system thread
CreateThread(function()
    while true do
        Wait(60000)
        
        local currentTime = os.time()
        
        for unitId, owners in pairs(unitRentals) do
            for ownerIdentifier, rental in pairs(owners) do
                if not rental.lockerData.purchased then
                    local nextPayment = rental.lockerData.nextPaymentDue or currentTime + 86400
                    local graceEnds = rental.lockerData.paymentGraceEnds
                    
                    if nextPayment <= currentTime and not graceEnds then
                        if rental.lockerData.autoRenewal and Config.Banking.hasStaticIdentifiers then
                            local bankAccount = rental.bankAccount
                            if not bankAccount then
                                bankAccount = Banking.GetPlayerAccount(ownerIdentifier)
                                if bankAccount then
                                    rental.bankAccount = bankAccount
                                    MySQL.query.await('UPDATE storage_rentals SET bankAccount = ? WHERE lockerIdentifier = ?', {
                                        bankAccount,
                                        rental.lockerIdentifier
                                    })
                                end
                            end
                            
                            local paymentSuccess = false
                            local failureReason = 'No bank account linked'
                            
                            if bankAccount then
                                local result = Banking.RemoveAccountMoney(bankAccount, Config.Pricing.rent, unitId)
                                
                                if result then
                                    paymentSuccess = true
                                else
                                    failureReason = 'Insufficient funds in bank account'
                                end
                            end
                            
                            if paymentSuccess then
                                local newNextPayment = currentTime + Config.Rental.duration
                                
                                UpdateLockerData(unitId, ownerIdentifier, { nextPaymentDue = newNextPayment })
                                
                                local ownerPlayer = GetPlayerFromIdentifier(ownerIdentifier)
                                if ownerPlayer then
                                    TriggerClientEvent('storage:autoRenewalSuccess', ownerPlayer.PlayerData.source, {
                                        unitId = unitId,
                                        nextPayment = os.date('%Y-%m-%d %H:%M:%S', newNextPayment),
                                        amount = Config.Pricing.rent
                                    })
                                end
                                
                                print("^2Storage unit #" .. unitId .. " auto-renewed successfully for " .. ownerIdentifier .. " from bank account " .. bankAccount)
                            else
                                local graceEndTime = currentTime + Config.Rental.paymentGracePeriod
                                UpdateLockerData(unitId, ownerIdentifier, { paymentGraceEnds = graceEndTime })
                                
                                local ownerPlayer = GetPlayerFromIdentifier(ownerIdentifier)
                                if ownerPlayer then
                                    TriggerClientEvent('storage:autoRenewalFailed', ownerPlayer.PlayerData.source, {
                                        unitId = unitId,
                                        graceEnds = os.date('%Y-%m-%d %H:%M:%S', graceEndTime),
                                        reason = failureReason
                                    })
                                end
                                
                                print("^3Storage unit #" .. unitId .. " auto-renewal failed for " .. ownerIdentifier .. ", 48-hour grace period started - " .. failureReason)
                            end
                        else
                            local graceEndTime = currentTime + Config.Rental.paymentGracePeriod
                            UpdateLockerData(unitId, ownerIdentifier, { paymentGraceEnds = graceEndTime })
                            
                            local ownerPlayer = exports.qbx_core:GetPlayerByCitizenId(ownerIdentifier)
                            if ownerPlayer then
                                TriggerClientEvent('storage:paymentOverdue', ownerPlayer.PlayerData.source, {
                                    unitId = unitId,
                                    graceEnds = os.date('%Y-%m-%d %H:%M:%S', graceEndTime)
                                })
                            end
                            
                            print("^3Storage unit #" .. unitId .. " payment overdue for " .. ownerIdentifier .. ", 48-hour grace period started")
                        end
                    end
                    
                    if graceEnds and graceEnds <= currentTime then
                        local stashId = 'storage_' .. unitId .. '_' .. ownerIdentifier
                        exports.ox_inventory:ClearInventory(stashId)
                        
                        MySQL.query.await('DELETE FROM storage_rentals WHERE lockerIdentifier = ?', { rental.lockerIdentifier })
                        
                        if playerRentals[ownerIdentifier] then
                            playerRentals[ownerIdentifier].owned = nil
                        end
                        
                        if rental.lockerData.collaborators then
                            for _, collaborator in pairs(rental.lockerData.collaborators) do
                                if playerRentals[collaborator.identifier] and playerRentals[collaborator.identifier].accesses then
                                    for i, access in ipairs(playerRentals[collaborator.identifier].accesses) do
                                        if access.unitId == unitId and access.ownerIdentifier == ownerIdentifier then
                                            table.remove(playerRentals[collaborator.identifier].accesses, i)
                                            break
                                        end
                                    end
                                end
                            end
                        end
                        
                        unitRentals[unitId][ownerIdentifier] = nil
                        
                        local hasOwners = false
                        for _ in pairs(unitRentals[unitId]) do
                            hasOwners = true
                            break
                        end
                        
                        if not hasOwners then
                            unitRentals[unitId] = nil
                        end
                        
                        local ownerPlayer = exports.qbx_core:GetPlayerByCitizenId(ownerIdentifier)
                        if ownerPlayer then
                            TriggerClientEvent('storage:unitDeleted', ownerPlayer.PlayerData.source, {
                                unitId = unitId,
                                reason = locale('payment_overdue_reason')
                            })
                        end
                        
                        print("^1Storage unit #" .. unitId .. " deleted for " .. ownerIdentifier .. " due to payment overdue")
                    end
                end
            end
        end
    end

end)

CheckVersion('Samuels-Development/sd-selfstorage')

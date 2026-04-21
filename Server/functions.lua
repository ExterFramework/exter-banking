local frameworkName = "standalone"
local Framework = nil
local standaloneBalances = {}

local callbacks = {}

local function resourceStarted(name)
    return GetResourceState(name) == "started"
end

local function detectFramework()
    local preferred = string.lower(Config.Framework or "auto")

    if preferred ~= "auto" then
        frameworkName = preferred
    elseif resourceStarted("qbx_core") then
        frameworkName = "qbox"
    elseif resourceStarted("qb-core") then
        frameworkName = "qbcore"
    elseif resourceStarted("es_extended") then
        frameworkName = "esx"
    else
        frameworkName = "standalone"
    end

    if frameworkName == "qbcore" then
        Framework = exports["qb-core"]:GetCoreObject()
    elseif frameworkName == "esx" then
        Framework = exports["es_extended"]:getSharedObject()
    elseif frameworkName == "qbox" then
        Framework = exports["qbx_core"]
    end

    print(("[exter-banking] Framework active: %s"):format(frameworkName))
end

local function fetchAll(query, params)
    if GetResourceState("oxmysql") == "started" then
        return MySQL.query.await(query, params) or {}
    end

    if GetResourceState("mysql-async") == "started" then
        return MySQL.Sync.fetchAll(query, params) or {}
    end

    return {}
end

local function executeQuery(query, params)
    if GetResourceState("oxmysql") == "started" then
        return MySQL.update.await(query, params) or 0
    end

    if GetResourceState("mysql-async") == "started" then
        return MySQL.Sync.execute(query, params) or 0
    end

    return 0
end

local function safeNumber(value)
    local num = tonumber(value)
    if not num then return nil end
    return math.floor(num)
end

local function parseTransactions(raw)
    if type(raw) == "table" then return raw end
    if type(raw) ~= "string" or raw == "" then return {} end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= "table" then
        return {}
    end

    return decoded
end

local function getPlayer(source)
    if frameworkName == "qbcore" then
        return Framework.Functions.GetPlayer(source)
    elseif frameworkName == "esx" then
        return Framework.GetPlayerFromId(source)
    elseif frameworkName == "qbox" then
        if Framework.GetPlayer then
            return Framework:GetPlayer(source)
        end
    end

    return { source = source }
end

local function getIdentifier(source)
    if frameworkName == "qbcore" then
        local player = getPlayer(source)
        return player and player.PlayerData and player.PlayerData.citizenid
    elseif frameworkName == "esx" then
        local player = getPlayer(source)
        return player and player.identifier
    elseif frameworkName == "qbox" then
        local player = getPlayer(source)
        if player and player.PlayerData then
            return player.PlayerData.citizenid or player.PlayerData.license
        end
    end

    local identifiers = GetPlayerIdentifiers(source)
    return identifiers[1] or ("standalone:%s"):format(source)
end

local function getPlayerName(source)
    if frameworkName == "qbcore" then
        local player = getPlayer(source)
        local char = player and player.PlayerData and player.PlayerData.charinfo
        if char then
            return ("%s %s"):format(char.firstname or "", char.lastname or "")
        end
    elseif frameworkName == "esx" then
        local player = getPlayer(source)
        if player and player.getName then return player.getName() end
    elseif frameworkName == "qbox" then
        local player = getPlayer(source)
        local char = player and player.PlayerData and player.PlayerData.charinfo
        if char then
            return ("%s %s"):format(char.firstname or "", char.lastname or "")
        end
    end

    return GetPlayerName(source) or ("Player %s"):format(source)
end

local function getCash(source)
    if frameworkName == "qbcore" then
        local player = getPlayer(source)
        return player and (player.Functions.GetMoney("cash") or 0) or 0
    elseif frameworkName == "esx" then
        local player = getPlayer(source)
        return player and player.getMoney() or 0
    elseif frameworkName == "qbox" then
        local player = getPlayer(source)
        if player and player.Functions and player.Functions.GetMoney then
            return player.Functions.GetMoney("cash") or 0
        end
    end

    standaloneBalances[source] = standaloneBalances[source] or { cash = 0, bank = 0 }
    return standaloneBalances[source].cash
end

local function getBank(source)
    if frameworkName == "qbcore" then
        local player = getPlayer(source)
        return player and (player.Functions.GetMoney("bank") or 0) or 0
    elseif frameworkName == "esx" then
        local player = getPlayer(source)
        local account = player and player.getAccount and player.getAccount("bank")
        return account and account.money or 0
    elseif frameworkName == "qbox" then
        local player = getPlayer(source)
        if player and player.Functions and player.Functions.GetMoney then
            return player.Functions.GetMoney("bank") or 0
        end
    end

    standaloneBalances[source] = standaloneBalances[source] or { cash = 0, bank = 0 }
    return standaloneBalances[source].bank
end

local function addCash(source, amount)
    if amount <= 0 then return false end

    if frameworkName == "qbcore" then
        local player = getPlayer(source)
        return player and player.Functions.AddMoney("cash", amount, "bank-withdraw") or false
    elseif frameworkName == "esx" then
        local player = getPlayer(source)
        if not player then return false end
        player.addMoney(amount)
        return true
    elseif frameworkName == "qbox" then
        local player = getPlayer(source)
        if not player or not player.Functions then return false end
        return player.Functions.AddMoney("cash", amount, "bank-withdraw")
    end

    standaloneBalances[source] = standaloneBalances[source] or { cash = 0, bank = 0 }
    standaloneBalances[source].cash = standaloneBalances[source].cash + amount
    return true
end

local function removeCash(source, amount)
    if amount <= 0 then return false end

    if getCash(source) < amount then return false end

    if frameworkName == "qbcore" then
        local player = getPlayer(source)
        return player and player.Functions.RemoveMoney("cash", amount, "bank-deposit") or false
    elseif frameworkName == "esx" then
        local player = getPlayer(source)
        if not player then return false end
        player.removeMoney(amount)
        return true
    elseif frameworkName == "qbox" then
        local player = getPlayer(source)
        if not player or not player.Functions then return false end
        return player.Functions.RemoveMoney("cash", amount, "bank-deposit")
    end

    standaloneBalances[source] = standaloneBalances[source] or { cash = 0, bank = 0 }
    standaloneBalances[source].cash = standaloneBalances[source].cash - amount
    return true
end

local function addBank(source, amount)
    if amount <= 0 then return false end

    if frameworkName == "qbcore" then
        local player = getPlayer(source)
        return player and player.Functions.AddMoney("bank", amount, "bank-transfer") or false
    elseif frameworkName == "esx" then
        local player = getPlayer(source)
        if not player then return false end
        player.addAccountMoney("bank", amount)
        return true
    elseif frameworkName == "qbox" then
        local player = getPlayer(source)
        if not player or not player.Functions then return false end
        return player.Functions.AddMoney("bank", amount, "bank-transfer")
    end

    standaloneBalances[source] = standaloneBalances[source] or { cash = 0, bank = 0 }
    standaloneBalances[source].bank = standaloneBalances[source].bank + amount
    return true
end

local function removeBank(source, amount)
    if amount <= 0 then return false end

    if getBank(source) < amount then return false end

    if frameworkName == "qbcore" then
        local player = getPlayer(source)
        return player and player.Functions.RemoveMoney("bank", amount, "bank-transfer") or false
    elseif frameworkName == "esx" then
        local player = getPlayer(source)
        if not player then return false end
        player.removeAccountMoney("bank", amount)
        return true
    elseif frameworkName == "qbox" then
        local player = getPlayer(source)
        if not player or not player.Functions then return false end
        return player.Functions.RemoveMoney("bank", amount, "bank-transfer")
    end

    standaloneBalances[source] = standaloneBalances[source] or { cash = 0, bank = 0 }
    standaloneBalances[source].bank = standaloneBalances[source].bank - amount
    return true
end

local function accountByOwner(identifier, accountId)
    local rows = fetchAll("SELECT * FROM accounts WHERE identifier = ? AND id = ?", { identifier, accountId })
    local account = rows[1]
    if not account then return nil end
    account.balance = safeNumber(account.balance) or 0
    account.transactions = parseTransactions(account.transactions)
    return account
end

local function accountById(accountId)
    local rows = fetchAll("SELECT * FROM accounts WHERE id = ?", { accountId })
    local account = rows[1]
    if not account then return nil end
    account.balance = safeNumber(account.balance) or 0
    account.transactions = parseTransactions(account.transactions)
    return account
end

local function saveAccount(account)
    return executeQuery("UPDATE accounts SET balance = ?, transactions = ? WHERE id = ?", {
        account.balance,
        json.encode(account.transactions or {}),
        account.id
    })
end

local function generateAccountId()
    local tries = 0
    while tries < 25 do
        tries = tries + 1
        local candidate = tostring(math.random(10000, 99999999))
        if not accountById(candidate) then
            return candidate
        end
    end

    return tostring(os.time()) .. tostring(math.random(1000, 9999))
end

local function registerServerCallback(name, fn)
    callbacks[name] = fn
end

RegisterNetEvent("exter-banking:Server:Request", function(name, requestId, payload)
    local src = source
    local cb = callbacks[name]

    if not cb then
        TriggerClientEvent("exter-banking:Client:Response", src, requestId, nil)
        return
    end

    cb(src, payload or {}, function(result)
        TriggerClientEvent("exter-banking:Client:Response", src, requestId, result)
    end)
end)

math.randomseed(GetGameTimer())
detectFramework()

ExterBanking = {
    DetectFramework = detectFramework,
    GetFrameworkName = function() return frameworkName end,
    RegisterServerCallback = registerServerCallback,
    SafeNumber = safeNumber,
    GetPlayer = getPlayer,
    GetIdentifier = getIdentifier,
    GetPlayerName = getPlayerName,
    GetCash = getCash,
    GetBank = getBank,
    AddCash = addCash,
    RemoveCash = removeCash,
    AddBank = addBank,
    RemoveBank = removeBank,
    FetchAll = fetchAll,
    Execute = executeQuery,
    GetAccountByOwner = accountByOwner,
    GetAccountById = accountById,
    SaveAccount = saveAccount,
    GenerateAccountId = generateAccountId,
    ParseTransactions = parseTransactions
}

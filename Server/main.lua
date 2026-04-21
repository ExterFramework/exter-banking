local function personalAccount(source)
    return {
        identifier = ExterBanking.GetIdentifier(source),
        id = "si:" .. source,
        name = "Personal Account",
        balance = ExterBanking.GetBank(source),
        transactions = {}
    }
end

local function sanitizeAmount(rawAmount)
    local amount = ExterBanking.SafeNumber(rawAmount)
    if not amount or amount <= 0 then
        return nil
    end

    return amount
end

local function addTransaction(account, payload)
    account.transactions = account.transactions or {}
    table.insert(account.transactions, payload)
end

ExterBanking.RegisterServerCallback("exter-banking:Server:GetUserAccounts", function(source, _, cb)
    local identifier = ExterBanking.GetIdentifier(source)
    if not identifier then
        return cb(nil)
    end

    local accounts = ExterBanking.FetchAll("SELECT * FROM accounts WHERE identifier = ?", { identifier })

    for i = 1, #accounts do
        accounts[i].balance = ExterBanking.SafeNumber(accounts[i].balance) or 0
        accounts[i].transactions = ExterBanking.ParseTransactions(accounts[i].transactions)
    end

    table.insert(accounts, personalAccount(source))

    cb({
        playerName = ExterBanking.GetPlayerName(source),
        totalMoney = (ExterBanking.GetBank(source) + ExterBanking.GetCash(source)),
        accounts = accounts
    })
end)

ExterBanking.RegisterServerCallback("exter-banking:Server:CreateAccount", function(source, data, cb)
    local identifier = ExterBanking.GetIdentifier(source)
    local accountName = data and data.accountName and tostring(data.accountName):sub(1, 64)

    if not identifier or not accountName or accountName:gsub("%s", "") == "" then
        return cb(nil)
    end

    local account = {
        identifier = identifier,
        id = ExterBanking.GenerateAccountId(),
        name = accountName,
        balance = 0,
        transactions = {}
    }

    local inserted = ExterBanking.Execute(
        "INSERT INTO accounts (identifier, id, name, balance, transactions) VALUES (?, ?, ?, ?, ?)",
        { account.identifier, account.id, account.name, account.balance, json.encode(account.transactions) }
    )

    if inserted and inserted > 0 then
        cb(account)
    else
        cb(nil)
    end
end)

ExterBanking.RegisterServerCallback("exter-banking:Server:DeleteAccount", function(source, data, cb)
    local identifier = ExterBanking.GetIdentifier(source)
    local accountId = data and tostring(data.accountId or "")

    if accountId:find("si:", 1, true) == 1 then
        return cb(false)
    end

    local affected = ExterBanking.Execute("DELETE FROM accounts WHERE identifier = ? and id = ?", { identifier, accountId })
    cb(affected and affected > 0)
end)

ExterBanking.RegisterServerCallback("exter-banking:Server:DepositMoney", function(source, data, cb)
    local identifier = ExterBanking.GetIdentifier(source)
    local amount = sanitizeAmount(data and data.amount)
    local accountId = data and data.accountId

    if not identifier or not amount or not accountId then
        return cb(nil)
    end

    if not ExterBanking.RemoveCash(source, amount) then
        return cb(nil)
    end

    if tostring(accountId):find("si:", 1, true) == 1 then
        ExterBanking.AddBank(source, amount)
        return cb({ personalAccount(source) })
    end

    local account = ExterBanking.GetAccountByOwner(identifier, accountId)
    if not account then
        ExterBanking.AddCash(source, amount)
        return cb(nil)
    end

    account.balance = account.balance + amount
    addTransaction(account, { type = "deposit", amount = amount, description = data.description or nil })
    ExterBanking.SaveAccount(account)
    account.playerName = ExterBanking.GetPlayerName(source)

    cb({ account })
end)

ExterBanking.RegisterServerCallback("exter-banking:Server:WithdrawMoney", function(source, data, cb)
    local identifier = ExterBanking.GetIdentifier(source)
    local amount = sanitizeAmount(data and data.amount)
    local accountId = data and data.accountId

    if not identifier or not amount or not accountId then
        return cb(nil)
    end

    if tostring(accountId):find("si:", 1, true) == 1 then
        if not ExterBanking.RemoveBank(source, amount) then
            return cb(nil)
        end

        ExterBanking.AddCash(source, amount)
        return cb({ personalAccount(source) })
    end

    local account = ExterBanking.GetAccountByOwner(identifier, accountId)
    if not account or account.balance < amount then
        return cb(nil)
    end

    account.balance = account.balance - amount
    addTransaction(account, { type = "withdraw", amount = amount, description = data.description or nil })
    ExterBanking.SaveAccount(account)

    ExterBanking.AddCash(source, amount)
    account.playerName = ExterBanking.GetPlayerName(source)

    cb({ account })
end)

ExterBanking.RegisterServerCallback("exter-banking:Server:TransferMoney", function(source, data, cb)
    local identifier = ExterBanking.GetIdentifier(source)
    local amount = sanitizeAmount(data and data.amount)
    local accountId = data and tostring(data.accountId or "")
    local targetId = data and tostring(data.targetId or "")

    if not identifier or not amount or accountId == "" or targetId == "" then
        return cb(nil)
    end

    if accountId == targetId then
        return cb(nil)
    end

    local updates = {}
    local personalSender = accountId:find("si:", 1, true) == 1

    if personalSender then
        if not ExterBanking.RemoveBank(source, amount) then
            return cb(nil)
        end
    else
        local senderAccount = ExterBanking.GetAccountByOwner(identifier, accountId)
        if not senderAccount or senderAccount.balance < amount then
            return cb(nil)
        end

        senderAccount.balance = senderAccount.balance - amount
        addTransaction(senderAccount, { type = "transfer_sent", amount = amount, description = data.description or nil, targetId = targetId })
        ExterBanking.SaveAccount(senderAccount)
        table.insert(updates, senderAccount)
    end

    local targetPersonal = targetId:find("si:", 1, true) == 1

    if targetPersonal then
        if not Config.AllowPersonalAccountTransfer then
            if personalSender then ExterBanking.AddBank(source, amount) end
            return cb(nil)
        end

        local targetSource = ExterBanking.SafeNumber(targetId:match("%d+"))
        if not targetSource or not GetPlayerName(targetSource) then
            if personalSender then ExterBanking.AddBank(source, amount) end
            return cb(nil)
        end

        ExterBanking.AddBank(targetSource, amount)

        if targetSource == source then
            table.insert(updates, personalAccount(source))
        end
    else
        local targetAccount = ExterBanking.GetAccountById(targetId)
        if not targetAccount then
            if personalSender then ExterBanking.AddBank(source, amount) end
            return cb(nil)
        end

        targetAccount.balance = targetAccount.balance + amount
        addTransaction(targetAccount, { type = "transfer_recieved", amount = amount, description = data.description or nil, targetId = accountId })
        ExterBanking.SaveAccount(targetAccount)

        if targetAccount.identifier == identifier then
            table.insert(updates, targetAccount)
        end
    end

    if personalSender then
        table.insert(updates, 1, personalAccount(source))
    end

    cb(#updates > 0 and updates or { personalAccount(source) })
end)

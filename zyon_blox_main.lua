-- Integração do hub: rotinas locais, catálogo dinâmico e chamadas limitadas.
do
    local Players = game:GetService("Players")
    local ReplicatedStorage = game:GetService("ReplicatedStorage")
    local RunService = game:GetService("RunService")
    local Workspace = game:GetService("Workspace")
    local HttpService = game:GetService("HttpService")
    local TeleportService = game:GetService("TeleportService")
    local VirtualUser = game:GetService("VirtualUser")
    local player = Players.LocalPlayer
    assert(player, "Execute no cliente Roblox, depois de entrar no jogo.")
    local playerGui = player:WaitForChild("PlayerGui", 15)
    assert(playerGui, "PlayerGui indisponível. Aguarde o jogo carregar.")
    for _, name in ipairs({ "ZyonMobile", "ZyonBloxFruits" }) do
        local old = playerGui:FindFirstChild(name)
        if old then
            local unload = old:FindFirstChild("Unload")
            if unload and unload:IsA("BindableEvent") then unload:Fire() end
            if old.Parent then old:Destroy() end
        end
    end

    local sea = ({ [2753915549] = 1, [4442272183] = 2, [7449423635] = 3 })[game.PlaceId]
    local alive, ui, motion, visuals, cleanup = true, nil, nil, nil, nil
    local connections, jobs, setters, dropdowns = {}, {}, {}, {}
    local flags = {
        farm = false, attack = false, haki = false, autoQuest = true,
        autoStats = false, autoStore = false, noclip = false, routeNoclip = true,
        antiIdle = false,
    }
    local settings = {
        flySpeed = 60, walkSpeed = 32, jumpPower = 75, fov = 70,
        travelSpeed = 120, farmHeight = 7, attackInterval = 0.4,
        espDistance = 2500, volume = 0.35, sounds = true, theme = "Violet",
        weapon = "Automático", enemy = "Por missão", quest = "Recomendado",
        island = "Nenhuma", stat = "Melee", batch = 5, attackMode = "Tool",
    }
    local catalog, catalogByLabel, islands, enemies = {}, {}, {}, {}
    local catalogStatus = "Carregando…"
    local knownWeapons, knownEnemies = {}, {}
    local serverHopBusy = false
    local currentTarget, bookmark, pendingRemote
    local cooldowns, warned, intervals = {}, {}, {}
    local lastAttack, equippedAt = 0, 0
    local missionAttempt = { id = nil, starts = 0, abandons = 0, lastStart = 0, lastAbandon = 0 }
    local overviewText, farmText, capabilityText

    local function bind(signal, callback)
        local connection = signal:Connect(callback)
        connections[#connections + 1] = connection
        return connection
    end

    local function notify(text, isError)
        if alive and ui then ui:notify(tostring(text), isError) end
    end

    local function warnOnce(key, text, seconds)
        local now = os.clock()
        if now >= (warned[key] or 0) then
            warned[key] = now + (seconds or 15)
            notify(text, true)
        end
    end

    local function spawnJob(callback)
        local count = 0
        for _ in pairs(jobs) do count = count + 1 end
        if count >= 3 then notify("Aguarde as tarefas atuais terminarem.", true); return nil end
        local record = { started = os.clock() }
        jobs[record] = true
        record.thread = task.spawn(function()
            local ok, err = pcall(callback)
            jobs[record] = nil
            if alive and not ok then warnOnce("job:" .. tostring(err), tostring(err)) end
        end)
        return record
    end

    local function setFlag(key, value)
        flags[key] = value == true
        if setters[key] then setters[key](flags[key]) end
    end

    local function remote()
        if not sea then return nil end
        local folder = ReplicatedStorage:FindFirstChild("Remotes")
        local object = folder and folder:FindFirstChild("CommF_")
        return object and object:IsA("RemoteFunction") and object or nil
    end

    -- Apenas uma invocação em voo. Nenhuma chamada remota roda em Render/PreSimulation.
    local function invoke(key, arguments, callback, gap)
        if not alive or pendingRemote or os.clock() < (cooldowns[key] or 0) then return false end
        local object = remote()
        if not object then warnOnce("remote", "CommF_ não encontrado nesta sessão."); return false end
        local record = { started = os.clock(), key = key }
        pendingRemote = record
        cooldowns[key] = os.clock() + (gap or 2)
        record.thread = task.spawn(function()
            local ok, result = pcall(function() return object:InvokeServer(table.unpack(arguments)) end)
            if not alive or pendingRemote ~= record then return end
            pendingRemote = nil
            if not ok then warnOnce("remote:" .. key, "Falha em " .. key .. ": " .. tostring(result)); return end
            if callback then
                local callbackOK, callbackError = pcall(callback, result)
                if not callbackOK then warnOnce("callback:" .. key, tostring(callbackError)) end
            end
        end)
        return true
    end

    local function dataValue(name, default)
        local data = player:FindFirstChild("Data")
        local value = data and data:FindFirstChild(name)
        if value and value:IsA("ValueBase") then return value.Value end
        return default
    end

    local function rootOf(object)
        if typeof(object) ~= "Instance" then return nil end
        if object:IsA("BasePart") then return object end
        local part = object:FindFirstChild("HumanoidRootPart") or object:FindFirstChild("Handle")
            or object:FindFirstChild("Head")
        if part and part:IsA("BasePart") then return part end
        if object:IsA("Model") and object.PrimaryPart then return object.PrimaryPart end
        return object:FindFirstChildWhichIsA("BasePart", true)
    end

    local function positionOf(object)
        if typeof(object) == "Vector3" then return object end
        if typeof(object) == "CFrame" then return object.Position end
        if typeof(object) == "Instance" then
            if object:IsA("BasePart") then return object.Position end
            if object:IsA("Model") then return object:GetPivot().Position end
        end
        return nil
    end

    local function normalize(name)
        return tostring(name):gsub("%b[]", ""):gsub("%s+$", ""):gsub("^%s+", ""):lower()
    end

    local function fruitTool(tool)
        if not tool:IsA("Tool") then return false end
        return tool:FindFirstChild("EatRemote", true) ~= nil
            or (type(tool:GetAttribute("OriginalName")) == "string" and tool.Name:lower():find("fruit", 1, true) ~= nil)
    end

    local function weaponTool(tool)
        local categories = { Melee = true, Sword = true, Gun = true, ["Blox Fruit"] = true }
        return tool:IsA("Tool") and not fruitTool(tool) and categories[tool.ToolTip] == true
    end

    local function tools(includeFruit)
        local result = {}
        local containers = {}
        local backpack = player:FindFirstChild("Backpack")
        if backpack then containers[#containers + 1] = backpack end
        if player.Character then containers[#containers + 1] = player.Character end
        for _, container in ipairs(containers) do
            if container then
                for _, object in ipairs(container:GetChildren()) do
                    if object:IsA("Tool") and (includeFruit or weaponTool(object)) then result[#result + 1] = object end
                end
            end
        end
        return result
    end

    local function refreshTools()
        local names, options = {}, { "Automático" }
        for _, tool in ipairs(tools(false)) do
            knownWeapons[tool.Name] = true
        end
        for name in pairs(knownWeapons) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do options[#options + 1] = name end
        if dropdowns.weapon then dropdowns.weapon:SetOptions(options) end
    end

    local function equipWeapon()
        local humanoid, character = motion:getHumanoid(), motion:getCharacter()
        if not humanoid or not character then return nil end
        local available, chosen = tools(false), nil
        if settings.weapon ~= "Automático" then
            for _, tool in ipairs(available) do if tool.Name == settings.weapon then chosen = tool; break end end
        else
            for _, tool in ipairs(available) do
                if tool.Parent == character then chosen = tool; break end
            end
            if not chosen then
                for _, category in ipairs({ "Melee", "Sword", "Gun", "Blox Fruit" }) do
                    for _, tool in ipairs(available) do if tool.ToolTip == category then chosen = tool; break end end
                    if chosen then break end
                end
            end
            chosen = chosen or available[1]
        end
        if chosen and chosen.Parent ~= character then
            humanoid:EquipTool(chosen)
            equippedAt = os.clock()
        end
        return chosen
    end

    local function scanEnemies()
        local folder = Workspace:FindFirstChild("Enemies")
        local list, options = {}, { "Por missão", "Mais próximo" }
        if folder then
            for _, model in ipairs(folder:GetChildren()) do
                local humanoid = model:FindFirstChildWhichIsA("Humanoid")
                local part = rootOf(model)
                if humanoid and humanoid.Health > 0 and part then
                    list[#list + 1] = { model = model, humanoid = humanoid, root = part, name = normalize(model.Name) }
                    knownEnemies[model.Name] = true
                end
            end
        end
        enemies = list
        local names = {}
        for name in pairs(knownEnemies) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do options[#options + 1] = name end
        if dropdowns.enemy then dropdowns.enemy:SetOptions(options) end
    end

    local function scanIslands()
        local found, names = {}, {}
        local origin = Workspace:FindFirstChild("_WorldOrigin")
        local locations = origin and origin:FindFirstChild("Locations")
        local map = Workspace:FindFirstChild("Map")
        local folders = {}
        if locations then folders[#folders + 1] = locations end
        if map then folders[#folders + 1] = map end
        for _, folder in ipairs(folders) do
            if folder then
                for _, object in ipairs(folder:GetChildren()) do
                    if object:IsA("BasePart") or object:IsA("Model") then
                        local position = positionOf(object)
                        if position and not found[object.Name] then
                            found[object.Name] = { object = object, position = position }
                            names[#names + 1] = object.Name
                        end
                    end
                end
            end
        end
        table.sort(names)
        if #names == 0 then names[1] = "Nenhuma" end
        islands = found
        if not found[settings.island] then settings.island = names[1] end
        if dropdowns.island then
            dropdowns.island:SetOptions(names)
            dropdowns.island:SetValue(settings.island)
        end
    end

    local function giverPosition(entry, key)
        if type(entry) ~= "table" then return nil end
        local position = positionOf(entry.Position) or positionOf(entry.CFrame) or positionOf(key)
        if position then return position end
        local npcs = Workspace:FindFirstChild("NPCs")
        local npc = npcs and type(entry.NPCName) == "string" and npcs:FindFirstChild(entry.NPCName)
        return npc and positionOf(npc) or nil
    end

    local function loadCatalog()
        local source = ReplicatedStorage:FindFirstChild("Quests")
        if not source or not source:IsA("ModuleScript") then
            catalogStatus = "Quests indisponível"; return
        end
        local ok, definitions = pcall(require, source)
        if not alive then return end
        if not ok or type(definitions) ~= "table" then catalogStatus = "Catálogo incompatível"; return end
        local guideSource = ReplicatedStorage:FindFirstChild("GuideModule")
        local guide
        if guideSource and guideSource:IsA("ModuleScript") then
            local guideOK, value = pcall(require, guideSource)
            if not alive then return end
            if guideOK and type(value) == "table" then guide = value end
        end
        local npcList = guide and type(guide.Data) == "table" and guide.Data.NPCList or {}
        if type(npcList) ~= "table" then npcList = {} end
        local built, byLabel = {}, {}
        for questID, variants in pairs(definitions) do
            if type(questID) == "string" and type(variants) == "table" then
                for index, entry in pairs(variants) do
                    if type(index) == "number" and type(entry) == "table" and type(entry.LevelReq) == "number" and type(entry.Task) == "table" then
                        local level, targets, count = entry.LevelReq, {}, 0
                        for name, amount in pairs(entry.Task) do
                            if type(name) == "string" and type(amount) == "number" and amount > 0 then
                                targets[normalize(name)] = true
                                count = count + amount
                            end
                        end
                        local inSea = (sea == 1 and level < 700) or (sea == 2 and level >= 700 and level < 1500) or (sea == 3 and level >= 1500)
                        if inSea and count > 1 and next(targets) then
                            local position
                            for key, giver in pairs(npcList) do
                                if type(giver) == "table" and type(giver.Levels) == "table" then
                                    for _, giverLevel in pairs(giver.Levels) do
                                        if giverLevel == level then position = giverPosition(giver, key); break end
                                    end
                                end
                                if position then break end
                            end
                            local title = string.format("Lv.%d · %s · %s/%d", level, tostring(entry.Name or next(targets)), questID, index)
                            local lowerID = questID:lower()
                            local special = lowerID:find("bartilo", 1, true) or lowerID:find("citizen", 1, true)
                                or lowerID:find("raid", 1, true) or lowerID:find("trial", 1, true)
                            local record = { id = questID, index = index, level = level, targets = targets,
                                giver = position, label = title, recommended = position ~= nil and not special }
                            built[#built + 1], byLabel[title] = record, record
                        end
                    end
                end
            end
        end
        table.sort(built, function(a, b)
            if a.level ~= b.level then return a.level < b.level end
            if a.id ~= b.id then return a.id < b.id end
            return a.index < b.index
        end)
        catalog, catalogByLabel = built, byLabel
        local options = { "Recomendado" }
        for _, quest in ipairs(built) do options[#options + 1] = quest.label end
        catalogStatus = tostring(#built) .. " missões locais"
        if dropdowns.quest then dropdowns.quest:SetOptions(options) end
    end

    local function selectedQuest()
        if settings.quest ~= "Recomendado" then return catalogByLabel[settings.quest] end
        local level, best = tonumber(dataValue("Level", 0)) or 0, nil
        for _, quest in ipairs(catalog) do
            if quest.level > level then break end
            if quest.recommended then best = quest end
        end
        return best
    end

    local function questHUD()
        local main = playerGui:FindFirstChild("Main")
        local quest = main and main:FindFirstChild("Quest")
        if not quest or not quest:IsA("GuiObject") then return nil end
        local title = quest:FindFirstChild("QuestTitle", true)
        local text = title and (title:IsA("TextLabel") and title or title:FindFirstChildWhichIsA("TextLabel", true))
        return { active = quest.Visible, title = text and normalize(text.Text) or "" }
    end

    local function nearestEnemy(quest, requireSelection, forceQuest)
        local root, best, bestDistance = motion:getRoot(), nil, math.huge
        if not root then return nil end
        for _, entry in ipairs(enemies) do
            if entry.model.Parent and entry.root.Parent and entry.humanoid.Health > 0 then
                local matches = not requireSelection or settings.enemy == "Mais próximo"
                    or (settings.enemy == "Por missão" and quest and quest.targets[entry.name])
                    or normalize(settings.enemy) == entry.name
                if forceQuest then matches = quest and quest.targets[entry.name] end
                if matches then
                    local distance = (root.Position - entry.root.Position).Magnitude
                    if distance < bestDistance then best, bestDistance = entry, distance end
                end
            end
        end
        return best, bestDistance
    end

    local function stopFarm()
        setFlag("farm", false)
        currentTarget = nil
        missionAttempt = { id = nil, starts = 0, abandons = 0, lastStart = 0, lastAbandon = 0 }
        if motion then motion:stopTravel() end
    end

    local function route(position, description)
        if not motion:getRoot() then notify("Aguarde o personagem nascer.", true); return end
        stopFarm()
        motion:goTo(position, settings.travelSpeed, false)
        ui:setVisible(false)
        notify(description or "Rota iniciada. Use Parar viagem para interromper.")
    end

    local function attack(entry)
        if os.clock() - lastAttack < settings.attackInterval or not entry then return end
        local root = motion:getRoot()
        if not root or not entry.root.Parent or (root.Position - entry.root.Position).Magnitude > 24 then return end
        local tool = equipWeapon()
        if not tool or not tool.Enabled or os.clock() - equippedAt < 0.2 then return end
        lastAttack = os.clock()
        if settings.attackMode == "Tool" then
            local ok, err = pcall(function() tool:Activate(); tool:Deactivate() end)
            if not ok then warnOnce("attack", "Ativação da arma falhou: " .. tostring(err)) end
        else
            local camera = Workspace.CurrentCamera
            if not camera then return end
            local ok = pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:Button1Down(Vector2.new(0, 0), camera.CFrame)
                VirtualUser:Button1Up(Vector2.new(0, 0), camera.CFrame)
            end)
            if not ok then
                settings.attackMode = "Tool"
                dropdowns.attackMode:SetValue("Tool")
                warnOnce("virtual", "Entrada virtual indisponível. Método alterado para Tool.")
            end
        end
    end

    local function farmStep()
        if not flags.farm then return end
        local root = motion:getRoot()
        if not root then return end
        local quest = selectedQuest()
        if flags.autoQuest then
            if not quest then
                stopFarm(); notify("Nenhuma missão compatível. Atualize o catálogo ou desative Missão automática.", true); return
            end
            local level = tonumber(dataValue("Level", 0)) or 0
            if quest.level > level then
                stopFarm(); notify("A missão exige nível " .. quest.level .. "; seu nível atual é " .. level .. ".", true); return
            end
            local identity = quest.id .. "/" .. tostring(quest.index)
            if missionAttempt.id ~= identity then
                missionAttempt = { id = identity, starts = 0, abandons = 0, lastStart = 0, lastAbandon = 0 }
            end
            local hud = questHUD()
            if not hud then stopFarm(); notify("HUD de missão não encontrado nesta versão.", true); return end
            if not hud.active then
                currentTarget = nil
                missionAttempt.abandons = 0
                if missionAttempt.starts >= 3 then
                    if os.clock() - missionAttempt.lastStart > 4 then
                        stopFarm(); notify("A missão não foi confirmada após três tentativas. Auto farm pausado.", true)
                    end
                    return
                end
                if not quest.giver then
                    stopFarm(); notify("Posição do NPC de missão indisponível. Aceite a missão e desative Missão automática.", true); return
                end
                if (root.Position - quest.giver).Magnitude > 9 then
                    motion:goTo(quest.giver + Vector3.new(0, 2, 0), settings.travelSpeed, true)
                    farmText.Text = "Indo ao NPC · " .. quest.label
                else
                    motion:stopTravel()
                    if invoke("StartQuest", { "StartQuest", quest.id, quest.index }, nil, 3) then
                        missionAttempt.starts = missionAttempt.starts + 1
                        missionAttempt.lastStart = os.clock()
                    end
                    farmText.Text = "Solicitando missão · " .. quest.label
                end
                return
            end
            local matches = false
            for name in pairs(quest.targets) do if hud.title:find(name, 1, true) then matches = true; break end end
            if hud.title == "" then stopFarm(); notify("Título da missão indisponível; automação pausada.", true); return end
            if not matches then
                motion:stopTravel()
                currentTarget = nil
                if missionAttempt.abandons >= 3 then
                    if os.clock() - missionAttempt.lastAbandon > 4 then
                        stopFarm(); notify("O servidor não confirmou a troca de missão. Auto farm pausado.", true)
                    end
                    return
                end
                if invoke("AbandonQuest", { "AbandonQuest" }, nil, 3) then
                    missionAttempt.abandons = missionAttempt.abandons + 1
                    missionAttempt.lastAbandon = os.clock()
                end
                farmText.Text = "Trocando para a missão selecionada…"
                return
            end
            missionAttempt.starts, missionAttempt.abandons = 0, 0
        end
        local target = nearestEnemy(quest, true, flags.autoQuest)
        currentTarget = target
        if target then
            local position = target.root.Position + Vector3.new(0, settings.farmHeight, 3)
            motion:goTo(CFrame.lookAt(position, target.root.Position), settings.travelSpeed, true)
            farmText.Text = "Alvo: " .. target.model.Name .. " · HP " .. tostring(math.floor(target.humanoid.Health))
            attack(target)
        else
            local origin = Workspace:FindFirstChild("_WorldOrigin")
            local spawns = (origin and origin:FindFirstChild("EnemySpawns")) or Workspace:FindFirstChild("EnemySpawns")
            local closest, distance = nil, math.huge
            if spawns then
                for _, marker in ipairs(spawns:GetChildren()) do
                    local name, position = normalize(marker.Name), positionOf(marker)
                    local matches = settings.enemy == "Mais próximo" or normalize(settings.enemy) == name
                        or (settings.enemy == "Por missão" and quest and quest.targets[name])
                    if flags.autoQuest then matches = quest and quest.targets[name] end
                    if position and matches then
                        local candidate = (root.Position - position).Magnitude
                        if candidate < distance then closest, distance = position, candidate end
                    end
                end
            end
            if closest then motion:goTo(closest + Vector3.new(0, 7, 0), settings.travelSpeed, true)
            else motion:stopTravel() end
            farmText.Text = "Aguardando o inimigo selecionado aparecer…"
        end
    end

    local function storeOne()
        for _, tool in ipairs(tools(true)) do
            if fruitTool(tool) then
                local original = tool:GetAttribute("OriginalName")
                if type(original) == "string" and #original > 0 then
                    local sent = invoke("StoreFruit:" .. original, { "StoreFruit", original, tool }, function(result)
                        if result == true then notify("Fruta guardada: " .. tool.Name)
                        elseif not flags.autoStore then notify("Resposta ao guardar fruta: " .. tostring(result)) end
                    end, 15)
                    if sent then return true end
                end
            end
        end
        if not flags.autoStore then notify("Nenhuma fruta disponível, ou solicitação em andamento. Frutas precisam de OriginalName.", true) end
        return false
    end

    local function addStats()
        local points = math.floor(tonumber(dataValue("Points", 0)) or 0)
        if points <= 0 then
            if not flags.autoStats then notify("Nenhum ponto de atributo disponível.") end
            return
        end
        invoke("AddPoint", { "AddPoint", settings.stat, math.min(points, settings.batch) }, function()
            if not flags.autoStats then notify("Pedido de distribuição enviado.") end
        end, 1)
    end

    local function findPickup(kind)
        local root, chosen, distance = motion:getRoot(), nil, math.huge
        if not root then notify("Aguarde o personagem nascer.", true); return end
        local chestNames = { chest = true, chest1 = true, chest2 = true, chest3 = true,
            ["bronze chest"] = true, ["silver chest"] = true, ["gold chest"] = true, ["diamond chest"] = true }
        for _, object in ipairs(Workspace:GetDescendants()) do
            local name = object.Name:lower()
            local matches = kind == "chest" and chestNames[name]
                or (kind == "fruit" and (object:IsA("Tool") and fruitTool(object)
                    or ((object:IsA("Model") or object:IsA("BasePart")) and name:match("fruit$"))))
            if matches then
                local ancestor, characterObject = object.Parent, false
                while ancestor and ancestor ~= Workspace do
                    if ancestor:IsA("Model") and ancestor:FindFirstChildWhichIsA("Humanoid") then characterObject = true; break end
                    ancestor = ancestor.Parent
                end
                local part = not characterObject and rootOf(object)
                if part then
                    local candidate = (root.Position - part.Position).Magnitude
                    if candidate < distance then chosen, distance = part, candidate end
                end
            end
        end
        if chosen then route(chosen.Position + Vector3.new(0, 2, 0), "Indo ao item visível mais próximo.")
        else notify("Nenhum item desse tipo está carregado nesta sessão.", true) end
    end

    ui = createHubUI({ parent = playerGui, title = "ZYON / BLOX FRUITS",
        subtitle = sea and ("SEA " .. sea .. "  ·  MOBILE HUB") or "MOBILE HUB · JOGO NÃO RECONHECIDO",
        onClose = function() if cleanup then cleanup() end end,
    })
    ui.screen.Name = "ZyonBloxFruits"
    local unload = Instance.new("BindableEvent")
    unload.Name, unload.Parent = "Unload", ui.screen
    motion = createMotion({ player = player, gui = ui.screen, notify = notify,
        isPanelVisible = function() return ui:isVisible() end,
        onFlyChanged = function(enabled)
            if setters.fly then setters.fly(enabled) end
            if enabled then stopFarm(); ui:setVisible(false) end
        end,
    })
    visuals = createVisuals({ player = player, gui = ui.screen, notify = notify })

    local home = ui:addTab("home", "Início")
    local combat = ui:addTab("combat", "Combate")
    local movement = ui:addTab("movement", "Movimento")
    local travel = ui:addTab("travel", "Viagem")
    local esp = ui:addTab("esp", "ESP")
    local stats = ui:addTab("stats", "Atributos")
    local config = ui:addTab("config", "Ajustes")
    ui:addSection(home, "SESSÃO AO VIVO")
    overviewText = ui:addText(home, "overview", "Carregando dados do personagem…")
    capabilityText = ui:addText(home, "capabilities", "Verificando recursos locais…")
    ui:addText(home, "build", "ZYON 2.0 · Módulos locais, sem carregar outros scripts. Os recursos automáticos começam desligados.")
    ui:addButton(home, "refresh", "Atualizar dados", "Rebusca armas, NPCs, ilhas e catálogo de missões.", function()
        refreshTools(); scanEnemies(); scanIslands(); visuals:refresh()
        spawnJob(loadCatalog)
        notify("Dados locais atualizados.")
    end)
    ui:addButton(home, "stop", "PARAR AUTOMAÇÕES", "Interrompe combate, missões, atributos, frutas e viagens.", function()
        stopFarm()
        for _, key in ipairs({ "attack", "haki", "autoStats", "autoStore", "antiIdle" }) do setFlag(key, false) end
        motion:setFly(false)
        if pendingRemote then
            local record = pendingRemote
            pendingRemote = nil
            if record.thread then pcall(task.cancel, record.thread) end
        end
        notify("Automações interrompidas.")
    end)

    ui:addSection(combat, "MISSÕES E COMBATE")
    farmText = ui:addText(combat, "farmStatus", "Automação desligada. Selecione arma e alvo antes de ativar.")
    dropdowns.weapon = ui:addDropdown(combat, "weapon", "Arma", "Frutas físicas da mochila não são ativadas pelo ataque.", { "Automático" }, settings.weapon, function(value) settings.weapon = value end)
    dropdowns.enemy = ui:addDropdown(combat, "enemy", "Alvo", "Escolha manual; Missão automática usa os alvos da missão.", { "Por missão", "Mais próximo" }, settings.enemy, function(value) settings.enemy = value end)
    dropdowns.quest = ui:addDropdown(combat, "quest", "Missão", "Recomendação pelo nível e pelo mar atual.", { "Recomendado" }, settings.quest, function(value) settings.quest = value end)
    setters.autoQuest = ui:addToggle(combat, "autoQuest", "Missão automática", "Durante o farm: vai ao NPC, aceita e troca missões.", true, function(value) setFlag("autoQuest", value) end)
    setters.farm = ui:addToggle(combat, "farm", "Auto farm", "Segue o alvo, equipa a arma e executa ataques normais.", false, function(value)
        if value then
            if not sea then setFlag("farm", false); notify("Entre em um dos três mares de Blox Fruits.", true); return end
            if flags.autoQuest and not remote() then setFlag("farm", false); notify("CommF_ indisponível para missões nesta sessão.", true); return end
            if flags.autoQuest and #catalog == 0 then setFlag("farm", false); notify("Catálogo ainda indisponível. Atualize ou escolha farm sem missão automática.", true); return end
            motion:setFly(false); motion:stopTravel(); setFlag("farm", true)
            ui:setVisible(false)
        else stopFarm() end
    end)
    setters.attack = ui:addToggle(combat, "attack", "Ataque automático próximo", "Ataca NPCs em até 24 studs, sem mover o personagem.", false, function(value) setFlag("attack", value) end)
    dropdowns.attackMode = ui:addDropdown(combat, "attackMode", "Método de ataque", "Tool usa a ativação normal; entrada virtual depende do executor.", { "Tool", "Entrada virtual" }, "Tool", function(value) settings.attackMode = value end)
    setters.attackInterval = ui:addNumber(combat, "attackInterval", "Intervalo de ataque", "Segundos entre ativações normais da arma.", 0.4, 0.2, 2, 0.1, function(value) settings.attackInterval = value end)
    setters.farmHeight = ui:addNumber(combat, "farmHeight", "Altura sobre o alvo", "Mantém a distância dentro do alcance normal.", 7, 0, 18, 1, function(value) settings.farmHeight = value end)
    setters.haki = ui:addToggle(combat, "haki", "Haki de armamento automático", "Solicita Buso somente quando HasBuso não está presente.", false, function(value)
        setFlag("haki", value and remote() ~= nil)
        if value and not flags.haki then notify("CommF_ indisponível para Haki.", true) end
    end)
    ui:addButton(combat, "equip", "Equipar arma selecionada", "Atualiza a seleção com a arma disponível na mochila.", function()
        if equipWeapon() then notify("Arma equipada.") else notify("Arma indisponível.", true) end
    end)

    ui:addSection(movement, "PERSONAGEM")
    setters.fly = ui:addToggle(movement, "fly", "Fly", "Joystick horizontal; SUBIR e DESCER controlam a altitude.", false, function(value) motion:setFly(value) end)
    setters.flySpeed = ui:addNumber(movement, "flySpeed", "Velocidade do Fly", "Studs por segundo; ajustável durante o voo.", 60, 10, 180, 10, function(value) settings.flySpeed = value; motion:setFlySpeed(value) end)
    ui:addToggle(movement, "speed", "Velocidade de caminhada", "Restaura a velocidade original ao desligar.", false, function(value) motion:setSpeedEnabled(value) end)
    setters.walkSpeed = ui:addNumber(movement, "walkSpeed", "Valor de caminhada", "Aplique com Velocidade de caminhada ativada.", 32, 8, 100, 4, function(value) settings.walkSpeed = value; motion:setWalkSpeed(value) end)
    ui:addToggle(movement, "jump", "Pulo aumentado", "Compatível com JumpPower e JumpHeight.", false, function(value) motion:setJumpEnabled(value) end)
    setters.jumpPower = ui:addNumber(movement, "jumpPower", "Potência do pulo", "Aplique com Pulo aumentado ativado.", 75, 25, 150, 5, function(value) settings.jumpPower = value; motion:setJumpPower(value) end)
    ui:addToggle(movement, "infiniteJump", "Pulo no ar", "Repete o salto ao tocar no botão de pulo.", false, function(value) motion:setInfiniteJump(value) end)
    setters.noclip = ui:addToggle(movement, "noclip", "Noclip manual", "Restaura a colisão original de cada parte ao desligar.", false, function(value) setFlag("noclip", value); motion:setNoclip(value or (flags.routeNoclip and motion:isTraveling())) end)
    setters.routeNoclip = ui:addToggle(movement, "routeNoclip", "Noclip durante rotas", "Usa noclip apenas enquanto há viagem ou farm ativo.", true, function(value) setFlag("routeNoclip", value) end)
    setters.fov = ui:addNumber(movement, "fov", "Campo de visão", "Ajusta a câmera atual e acompanha trocas de câmera.", 70, 40, 110, 5, function(value) settings.fov = value; motion:setFOV(value) end)
    ui:addButton(movement, "resetFov", "Restaurar câmera", "Devolve o campo de visão registrado ao entrar.", function() motion:resetFOV(); notify("Campo de visão restaurado.") end)

    ui:addSection(travel, "ROTAS DO MAPA CARREGADO")
    dropdowns.island = ui:addDropdown(travel, "island", "Destino", "Ilhas e marcadores detectados no mar atual.", { "Nenhuma" }, "Nenhuma", function(value) settings.island = value end)
    setters.travelSpeed = ui:addNumber(travel, "travelSpeed", "Velocidade da rota", "Usada em viagens, missões e aproximação de inimigos.", 120, 30, 200, 10, function(value) settings.travelSpeed = value end)
    ui:addButton(travel, "goIsland", "Viajar para destino", "Chega acima do marcador; não muda de mar.", function()
        local destination = islands[settings.island]
        if destination and destination.object.Parent then route(destination.position + Vector3.new(0, 35, 0), "Rota para " .. settings.island)
        else notify("Selecione uma ilha carregada e atualize a lista.", true) end
    end)
    ui:addButton(travel, "stopTravel", "Parar viagem", "Interrompe a rota e o auto farm imediatamente.", function() stopFarm(); notify("Rota interrompida.") end)
    ui:addButton(travel, "savePosition", "Marcar posição", "Mantém um marcador privado durante esta execução.", function()
        local root = motion:getRoot()
        if root then bookmark = root.CFrame; notify("Posição marcada.") else notify("Personagem indisponível.", true) end
    end)
    ui:addButton(travel, "returnPosition", "Voltar à posição marcada", "Usa a mesma movimentação guiada das rotas.", function()
        if bookmark then route(bookmark.Position, "Retornando à posição marcada.") else notify("Marque uma posição primeiro.", true) end
    end)
    ui:addButton(travel, "nearFruit", "Ir à fruta mais próxima", "Procura frutas físicas que estão carregadas no mapa.", function() findPickup("fruit") end)
    ui:addButton(travel, "nearChest", "Ir ao baú mais próximo", "Procura baús físicos carregados nesta sessão.", function() findPickup("chest") end)
    ui:addButton(travel, "refreshIslands", "Atualizar destinos", "Inclui ilhas temporárias que acabaram de aparecer.", function() scanIslands(); notify("Destinos atualizados.") end)

    ui:addSection(esp, "MARCADORES COM DISTÂNCIA")
    ui:addToggle(esp, "espPlayers", "Jogadores", "Nome e distância; ignora o próprio personagem.", false, function(value) visuals:setPlayers(value) end)
    ui:addToggle(esp, "espEnemies", "Inimigos", "NPCs vivos de Workspace.Enemies.", false, function(value) visuals:setEnemies(value) end)
    ui:addToggle(esp, "espFruits", "Frutas", "Frutas físicas fora de personagens e mochilas.", false, function(value) visuals:setFruits(value) end)
    ui:addToggle(esp, "espChests", "Baús", "Marcadores de baús que estão carregados.", false, function(value) visuals:setChests(value) end)
    ui:addToggle(esp, "espIslands", "Ilhas", "Marcadores e modelos detectados no mapa atual.", false, function(value) visuals:setIslands(value) end)
    setters.espDistance = ui:addNumber(esp, "espDistance", "Alcance do ESP", "Limita distância e quantidade para manter o painel leve.", 2500, 250, 10000, 250, function(value) settings.espDistance = value; visuals:setDistance(value) end)
    ui:addToggle(esp, "fullbright", "Iluminação clara", "Restaura Lighting ao desligar ou encerrar.", false, function(value) visuals:setFullbright(value) end)
    ui:addToggle(esp, "lowGraphics", "Reduzir pós-processamento", "Pausa efeitos de Lighting sem apagar objetos do mapa.", false, function(value) visuals:setLowGraphics(value) end)

    ui:addSection(stats, "ATRIBUTOS E FRUTAS")
    dropdowns.stat = ui:addDropdown(stats, "stat", "Atributo", "Demon Fruit corresponde ao atributo Blox Fruit.", { "Melee", "Defense", "Sword", "Gun", "Demon Fruit" }, "Melee", function(value) settings.stat = value end)
    setters.batch = ui:addNumber(stats, "batch", "Pontos por lote", "Nunca envia mais pontos do que os disponíveis.", 5, 1, 100, 1, function(value) settings.batch = value end)
    ui:addButton(stats, "addStats", "Distribuir um lote", "Envia AddPoint ao atributo selecionado.", addStats)
    setters.autoStats = ui:addToggle(stats, "autoStats", "Distribuição automática", "Envia lotes enquanto houver pontos livres.", false, function(value)
        setFlag("autoStats", value and remote() ~= nil)
        if value and not flags.autoStats then notify("CommF_ indisponível para atributos.", true) end
    end)
    ui:addButton(stats, "storeFruit", "Guardar fruta da mochila", "Usa o OriginalName real; não compra nem consome frutas.", function() storeOne() end)
    setters.autoStore = ui:addToggle(stats, "autoStore", "Guardar frutas automaticamente", "Tenta guardar uma fruta por vez, com intervalo limitado.", false, function(value)
        setFlag("autoStore", value and remote() ~= nil)
        if value and not flags.autoStore then notify("CommF_ indisponível para guardar frutas.", true) end
    end)

    ui:addSection(config, "APARÊNCIA E SOM")
    dropdowns.theme = ui:addDropdown(config, "theme", "Tema", "Paletas com contraste para jogar no celular.", { "Violet", "Ocean", "Emerald" }, "Violet", function(value) settings.theme = value; ui:setTheme(value) end)
    setters.sounds = ui:addToggle(config, "sounds", "Sons da interface", "Cliques e notificações com sons locais do Roblox.", true, function(value) settings.sounds = value; ui:setSoundEnabled(value) end)
    setters.volume = ui:addNumber(config, "volume", "Volume da interface", "Volume dos sons do painel, de 0 a 1.", 0.35, 0, 1, 0.05, function(value) settings.volume = value; ui:setVolume(value) end)
    setters.antiIdle = ui:addToggle(config, "antiIdle", "Interação ao ficar inativo", "Depende da disponibilidade de VirtualUser no executor.", false, function(value) setFlag("antiIdle", value) end)
    ui:addSection(config, "PREFERÊNCIAS E SESSÃO")
    ui:addButton(config, "saveConfig", "Salvar preferências", "Salva ajustes; não salva automações ligadas.", function()
        if type(writefile) ~= "function" then notify("writefile indisponível neste executor.", true); return end
        writefile("zyon_blox_settings.json", HttpService:JSONEncode(settings))
        notify("Preferências salvas.")
    end)
    ui:addButton(config, "loadConfig", "Carregar preferências", "Reaplica valores e aparência; não liga automações.", function()
        if type(readfile) ~= "function" then notify("readfile indisponível neste executor.", true); return end
        local saved = HttpService:JSONDecode(readfile("zyon_blox_settings.json"))
        if type(saved) ~= "table" then error("Arquivo de preferências inválido.") end
        local numeric = {
            flySpeed = { 10, 180 }, walkSpeed = { 8, 100 }, jumpPower = { 25, 150 },
            fov = { 40, 110 }, travelSpeed = { 30, 200 }, farmHeight = { 0, 18 },
            attackInterval = { 0.2, 2 }, espDistance = { 250, 10000 }, volume = { 0, 1 }, batch = { 1, 100 },
        }
        for key, limits in pairs(numeric) do
            local value = saved[key]
            if type(value) == "number" and value == value and math.abs(value) < math.huge then
                value = math.clamp(value, limits[1], limits[2])
                if key == "batch" then value = math.floor(value) end
                settings[key] = value
                setters[key](value, true)
            end
        end
        if saved.theme == "Violet" or saved.theme == "Ocean" or saved.theme == "Emerald" then dropdowns.theme:SetValue(saved.theme, true) end
        if type(saved.sounds) == "boolean" then setters.sounds(saved.sounds, true) end
        local validStats = { Melee = true, Defense = true, Sword = true, Gun = true, ["Demon Fruit"] = true }
        if validStats[saved.stat] then dropdowns.stat:SetValue(saved.stat, true) end
        if saved.attackMode == "Tool" or saved.attackMode == "Entrada virtual" then dropdowns.attackMode:SetValue(saved.attackMode, true) end
        if type(saved.weapon) == "string" and (saved.weapon == "Automático" or knownWeapons[saved.weapon]) then dropdowns.weapon:SetValue(saved.weapon, true) end
        if type(saved.enemy) == "string" and (saved.enemy == "Por missão" or saved.enemy == "Mais próximo" or knownEnemies[saved.enemy]) then dropdowns.enemy:SetValue(saved.enemy, true) end
        if saved.quest == "Recomendado" or catalogByLabel[saved.quest] then dropdowns.quest:SetValue(saved.quest, true) end
        if type(saved.island) == "string" and islands[saved.island] then dropdowns.island:SetValue(saved.island, true) end
        notify("Preferências carregadas.")
    end)
    ui:addButton(config, "rejoin", "Reconectar ao servidor", "Retorna à mesma instância quando ela ainda estiver disponível.", function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, player)
    end)
    ui:addButton(config, "serverHop", "Buscar outro servidor", "Procura vaga na lista pública do Roblox.", function()
        if serverHopBusy then notify("A busca de servidores já está em andamento.", true); return end
        if pendingRemote then notify("Aguarde a chamada atual terminar.", true); return end
        serverHopBusy = true
        local job = spawnJob(function()
            local ok, result = pcall(function()
                local body = game:HttpGet("https://games.roblox.com/v1/games/" .. tostring(game.PlaceId) .. "/servers/Public?sortOrder=Asc&limit=100")
                if not alive then return end
                local response = HttpService:JSONDecode(body)
                if type(response) ~= "table" or type(response.data) ~= "table" then error("Resposta de servidores incompatível.") end
                for _, server in ipairs(response.data) do
                    if type(server.id) == "string" and server.id ~= game.JobId and type(server.playing) == "number" and type(server.maxPlayers) == "number" and server.playing < server.maxPlayers then
                        TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, player)
                        return
                    end
                end
                notify("Nenhuma vaga encontrada nesta página de servidores.", true)
            end)
            serverHopBusy = false
            if not ok then error("Busca de servidores falhou: " .. tostring(result)) end
        end)
        if not job then serverHopBusy = false end
    end)
    ui:addButton(config, "unload", "Encerrar e restaurar", "Remove o hub, desconecta eventos e restaura os efeitos locais.", function() cleanup() end)

    bind(player.Idled, function()
        if not flags.antiIdle or not alive then return end
        local camera = Workspace.CurrentCamera
        if not camera then return end
        local ok = pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:Button2Down(Vector2.new(0, 0), camera.CFrame)
            VirtualUser:Button2Up(Vector2.new(0, 0), camera.CFrame)
        end)
        if not ok then setFlag("antiIdle", false); notify("VirtualUser indisponível; interação inativa desligada.", true) end
    end)
    bind(TeleportService.TeleportInitFailed, function(who, _, message)
        if who == player then notify("Falha na conexão: " .. tostring(message), true) end
    end)

    local function periodic(key, period, delta, callback)
        intervals[key] = (intervals[key] or 0) + delta
        if intervals[key] < period then return end
        intervals[key] = 0
        local ok, err = pcall(callback)
        if not ok then warnOnce("periodic:" .. key, key .. ": " .. tostring(err)) end
    end

    bind(RunService.Heartbeat, function(delta)
        if not alive then return end
        for record in pairs(jobs) do
            if os.clock() - record.started > 20 then
                jobs[record] = nil
                if record.thread then pcall(task.cancel, record.thread) end
                serverHopBusy = false
                warnOnce("jobTimeout", "Tarefa demorou demais e foi cancelada. Tente atualizar os dados.")
            end
        end
        if pendingRemote and os.clock() - pendingRemote.started > 8 then
            local record = pendingRemote
            pendingRemote = nil
            cooldowns[record.key] = os.clock() + 15
            if record.thread then pcall(task.cancel, record.thread) end
            warnOnce("timeout", "O servidor não respondeu. Chamada cancelada; aguarde antes de tentar novamente.")
        end
        periodic("scan", 1, delta, function() scanEnemies(); refreshTools() end)
        periodic("combat", 0.15, delta, function()
            if flags.farm then farmStep()
            elseif flags.attack then attack(nearestEnemy(nil, settings.enemy ~= "Por missão")) end
            motion:setNoclip(flags.noclip or (flags.routeNoclip and motion:isTraveling()))
        end)
        periodic("stats", 1.2, delta, function() if flags.autoStats then addStats() end end)
        periodic("fruits", 4, delta, function() if flags.autoStore then storeOne() end end)
        periodic("haki", 3, delta, function()
            local character = motion:getCharacter()
            if flags.haki and character and not character:FindFirstChild("HasBuso") then invoke("Buso", { "Buso" }, nil, 5) end
        end)
        periodic("overview", 1, delta, function()
            local humanoid = motion:getHumanoid()
            overviewText.Text = string.format("%s · %s\nNível %s  |  Beli %s  |  Fragmentos %s\nHP %s  |  Pontos livres %s", player.DisplayName,
                sea and ("Mar " .. sea) or "Jogo não reconhecido", tostring(dataValue("Level", "?")), tostring(dataValue("Beli", "?")),
                tostring(dataValue("Fragments", "?")), humanoid and tostring(math.floor(humanoid.Health)) or "—", tostring(dataValue("Points", 0)))
            capabilityText.Text = "CommF_: " .. (remote() and "detectado" or "indisponível") .. "\nCatálogo: " .. catalogStatus
                .. "\nAtaque normal: Tool · dano depende da lógica atual do jogo."
            if not flags.farm then farmText.Text = "Auto farm desligado · " .. tostring(#enemies) .. " inimigos carregados." end
        end)
    end)

    cleanup = function(externalDestroy)
        if not alive then return end
        alive = false
        for _, connection in ipairs(connections) do connection:Disconnect() end
        table.clear(connections)
        if pendingRemote then
            local record = pendingRemote
            pendingRemote = nil
            if record.thread then pcall(task.cancel, record.thread) end
        end
        for record in pairs(jobs) do if record.thread then pcall(task.cancel, record.thread) end end
        table.clear(jobs)
        if motion then motion:destroy() end
        if visuals then visuals:destroy() end
        if ui and externalDestroy ~= true then ui:destroy() end
    end
    bind(unload.Event, function() cleanup() end)
    bind(ui.screen.Destroying, function() cleanup(true) end)
    refreshTools(); scanEnemies(); scanIslands()
    spawnJob(loadCatalog)
    ui:setSoundEnabled(settings.sounds)
    ui:setVolume(settings.volume)
    notify("ZYON carregado. Escolha uma aba para começar.")
end

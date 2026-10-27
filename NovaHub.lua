--[[
	NOVA HUB  ·  Blue Lock Farm
	Reconstrucción limpia y legible del hub "Aster" (que venía ofuscado).
	Reproduce la interfaz (sidebar + pestañas con toggles/sliders/dropdowns)
	y reimplementa cada opción llamando a los REMOTES REALES del juego.

	Arquitectura (igual que el original):
	  - La UI solo cambia State.<flag>.
	  - Bucles de fondo (Engine) leen esos flags y ejecutan la acción con su delay.
	  - Cada bucle escribe un .status que la píldora del toggle muestra.

	Marcado con  -- TODO:  lo que hay que afinar contigo (args no 100% confirmados).
]]

--========================================================================
--  SERVICIOS Y REFERENCIAS
--========================================================================
local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")
local UserInputService   = game:GetService("UserInputService")
local CollectionService  = game:GetService("CollectionService")
local TeleportService    = game:GetService("TeleportService")
local Lighting           = game:GetService("Lighting")
local GuiService         = game:GetService("GuiService")

local LocalPlayer = Players.LocalPlayer
local Remotes     = ReplicatedStorage:WaitForChild("Remotes")

-- parche de referencia seguro para CoreGui si el ejecutor lo soporta
local function hiddenParent()
	local ok, h = pcall(function() return gethui and gethui() end)
	if ok and h then return h end
	return LocalPlayer:WaitForChild("PlayerGui")
end

--========================================================================
--  ESTADO CENTRAL  (lo que tocan los toggles; lo que leen los bucles)
--========================================================================
local State = {
	-- Rolling
	AutoRoll = false,  RollDelay = 0.35,
	AutoBuy  = false,  SkipUnaffordable = false, MaxCost = math.huge,
	BuyBoxes = {},     BuyVariants = {},            -- filtros (vacío = todo)
	-- Lockers
	AutoPlace = false, PlaceDelay = 0.45,
	AutoOpen  = false, OpenDelay  = 0.50,
	AutoCarry = false, CarryDelay = 0.40,
	-- Selling
	AutoSell  = false, SellMode = "Crates", SellDelay = 0.75,
	AutoSellBoxes = false, SellBoxesDelay = 1.25,
	-- Progress
	AutoUpgrade = false,          UpgradeDelay = 0.60,
	AutoUpgradePlaced = false,    PlacedDelay = 0.70,
	AutoUpgradeConveyor = false,  ConveyorUpgradeDelay = 0.80,
	AutoEquipBest = false,        EquipDelay = 3.2,
	AutoClaimIndex = false,       IndexDelay = 2.0,
	AutoClaimRewards = false,     RewardsDelay = 2.5,
	-- Player
	WalkSpeedOn = false, WalkSpeedAmt = 32,
	InfJump = false, NoClip = false, InstantPrompt = false,
	Fly = false, FlySpeed = 60,
	-- Events & Weather  ·  Halloween (verificado en vivo: HouseSystemModel + TrickOrTreat + CandyCornClient)
	HalloweenKnock = false, KnockDelay = 2.0, KnockReturn = true, KnockBoss = false,
	CandyBagSell = false, CandyBagDelay = 10,
	-- Player · Client
	Disable3D = false, HideUIOnStart = false,
	-- Settings
	AntiAfk = true, AntiPause = false, AutoReconnect = false, FpsBoost = false,
	ToggleUIKey = "K", Density = "Default", Background = "None", BgOpacity = 65,
	-- Webhook (Discord)
	WebhookUrl = "", SendNewUnits = false, SendStats = false, StatsEvery = 10,
	WhVariant = "None", WhFromLockers = "None",
	-- Añadidos explorando el juego: conveyor nativo · colectables · reroll · claims
	ConvAutoBuy = false, ConvAutoSpawn = false,
	CollectVariant = false, CollectVariantDelay = 0.5,
	CollectObjects = false, CollectObjectsDelay = 0.5,
	ClaimOffline = false, OfflineDelay = 5,
	RerollTrait = false, TargetTrait = "Any", RerollTraitDelay = 0.8,
	RerollGrade = false, TargetGrade = "Any", RerollGradeDelay = 0.8,
}

-- textos de estado que muestran las píldoras (status.<Feature>)
local status = {}
local function setStatus(k, v) status[k] = v end

--========================================================================
--  UTILIDADES DE JUEGO
--========================================================================
local function safe(fn)               -- pcall que devuelve ok
	local ok = pcall(fn); return ok
end

local function getPlot()              -- plot del jugador = PlotModels[<nombre>]
	local map = workspace:FindFirstChild("Map"); if not map then return nil end
	local pm = map:FindFirstChild("PlotModels"); if not pm then return nil end
	return pm:FindFirstChild(LocalPlayer.Name)
end

local function isInMyPlot(inst)       -- ¿inst pertenece a mi plot?
	local plot = getPlot(); if not plot then return false end
	return inst:IsDescendantOf(plot)
end

local function plotTagged(tag)        -- primera parte con ese tag dentro de mi plot
	for _, inst in ipairs(CollectionService:GetTagged(tag)) do
		if isInMyPlot(inst) then return inst end
	end
	return nil
end

local function plotTaggedAll(tag)     -- todas las de mi plot
	local out = {}
	for _, inst in ipairs(CollectionService:GetTagged(tag)) do
		if isInMyPlot(inst) then out[#out+1] = inst end
	end
	return out
end

local function serverNow()
	return workspace:GetServerTimeNow()
end

local function humanoid()
	local c = LocalPlayer.Character
	return c and c:FindFirstChildOfClass("Humanoid")
end

local function hrp()
	local c = LocalPlayer.Character
	return c and c:FindFirstChild("HumanoidRootPart")
end

-- recorre tools (crates) del inventario con atributo InventoryKey
local function inventoryCrates()
	local out = {}
	local function scan(cont)
		if not cont then return end
		for _, t in ipairs(cont:GetChildren()) do
			if t:IsA("Tool") and t:GetAttribute("InventoryKey") ~= nil then
				out[#out+1] = t
			end
		end
	end
	scan(LocalPlayer:FindFirstChild("Backpack"))
	scan(LocalPlayer.Character)
	return out
end

--========================================================================
--  ENGINE  ·  una función por opción. Cada loop: while flag do acción; wait(delay) end
--========================================================================
local Engine = {}
local threads = {}          -- hilos activos por feature

-- helper: lanza un loop que corre mientras State[flag] sea true
local function loop(flag, body, delayKey)
	if threads[flag] then return end
	threads[flag] = task.spawn(function()
		while State[flag] do
			safe(body)
			task.wait(State[delayKey] or 0.3)
		end
		threads[flag] = nil
	end)
end
local function startLoop(flag, body, delayKey)
	if State[flag] then loop(flag, body, delayKey) end
end

-- ---- Rolling -------------------------------------------------------------
-- ¿la caja en cinta pasa el filtro de compra del usuario?
local function boxPassesFilter(part)
	local box = part:GetAttribute("BoxName")
	local variant = part:GetAttribute("Variant")
	if next(State.BuyBoxes) and not State.BuyBoxes[box] then return false end
	if next(State.BuyVariants) and variant and not State.BuyVariants[variant] then return false end
	return true
end

function Engine.AutoRoll()
	local part = plotTagged("RollConveyorPart")
	if not part then setStatus("AutoRoll","Plot conveyor not found"); return end
	if part:GetAttribute("TutorialConveyorLock") then setStatus("AutoRoll","Tutorial lock active"); return end

	-- cooldown
	local until_ = part:GetAttribute("RollCooldownUntil")
	if type(until_) == "number" and serverNow() < until_ then
		setStatus("AutoRoll","Roll on cooldown"); return
	end

	-- filtro de Auto Buy (si está activo): solo rollear la caja deseada
	if State.AutoBuy and not boxPassesFilter(part) then
		setStatus("AutoRoll","Skipping unaffordable box"); return   -- TODO: separar skip real vs filtro
	end

	local remote = Remotes:FindFirstChild("RequestConveyorRoll")
	if not remote then setStatus("AutoRoll","Missing RequestConveyorRoll"); return end
	if safe(function() remote:FireServer() end) then
		setStatus("AutoRoll","Rolled conveyor")
	else
		setStatus("AutoRoll","Roll fire failed")
	end
end

-- ---- Selling -------------------------------------------------------------
function Engine.AutoSell()
	local sellName = (State.SellMode == "Merchant") and "MerchantSell" or "SellCrate"
	local remote = Remotes:FindFirstChild(sellName)
	if not remote then setStatus("AutoSell","Missing "..sellName); return end

	local crates = inventoryCrates()
	if #crates == 0 then setStatus("AutoSell","No crates to sell"); return end

	local sold = 0
	for _, tool in ipairs(crates) do
		local key = tool:GetAttribute("InventoryKey")
		if type(key) == "string" or type(key) == "number" then
			if safe(function() remote:FireServer(key) end) then
				sold += 1
				task.wait(0.15)
			end
		end
	end
	setStatus("AutoSell", ("Sold %d crate(s)"):format(sold))
end

-- ---- Carry (recoger balls/boxes de la cinta) -----------------------------
function Engine.AutoCarry()
	local collect = plotTagged("ConveyorCollectPart")
	local remote  = Remotes:FindFirstChild("PickupCrateBox")
	if not (collect and remote) then setStatus("AutoCarry","No boxes to carry"); return end
	local pending = collect:GetAttribute("PendingBallCount")
	if not pending or pending <= 0 then setStatus("AutoCarry","No boxes to carry"); return end
	if safe(function() remote:FireServer(collect) end) then     -- TODO: confirmar arg (collectPart)
		setStatus("AutoCarry", ("Carrying %s"):format(tostring(pending)))
	end
end

-- ---- Lockers / Droppers --------------------------------------------------
-- dropper vacío = sin atributo de caja puesta (heurística; afinamos contigo)
local function droppersMine() return plotTaggedAll("DropperBasePart") end

function Engine.AutoPlace()
	local remote = Remotes:FindFirstChild("PlaceBoxOnDropper")
	if not remote then setStatus("AutoPlace","Missing PlaceBoxOnDropper"); return end
	local placed = 0
	for _, dropper in ipairs(droppersMine()) do
		-- TODO: condición real de "dropper vacío" (atributo exacto por confirmar)
		if not dropper:GetAttribute("BoxName") then
			if safe(function() remote:FireServer(dropper) end) then placed += 1; task.wait(0.05) end
		end
	end
	setStatus("AutoPlace", placed > 0 and ("Placed %d"):format(placed) or "No empty droppers")
end

function Engine.AutoOpen()
	local remote = Remotes:FindFirstChild("OpenBoxOnDropper")   -- RemoteFunction → InvokeServer
	if not remote then setStatus("AutoOpen","Missing OpenBoxOnDropper"); return end
	local opened = 0
	for _, dropper in ipairs(droppersMine()) do
		-- TODO: condición real de "locker listo" (atributo de tiempo/estado por confirmar)
		if dropper:GetAttribute("BoxName") then
			if safe(function() remote:InvokeServer(dropper) end) then opened += 1; task.wait(0.05) end
		end
	end
	setStatus("AutoOpen", opened > 0 and ("Opened %d"):format(opened) or "No ready lockers")
end

-- ---- Progreso ------------------------------------------------------------
function Engine.AutoEquipBest()
	local remote = Remotes:FindFirstChild("EquipBestPlayerUnits")
	if not remote then setStatus("AutoEquipBest","Missing EquipBestPlayerUnits"); return end
	if safe(function() remote:FireServer() end) then setStatus("AutoEquipBest","Equipped best")
	else setStatus("AutoEquipBest","Equip best failed") end
end

function Engine.AutoClaimIndex()
	local remote = Remotes:FindFirstChild("ClaimAllIndexRewards")
	if not remote then setStatus("AutoClaimIndex","Missing ClaimAllIndexRewards"); return end
	if safe(function() remote:FireServer() end) then setStatus("AutoClaimIndex","Claimed index rewards")
	else setStatus("AutoClaimIndex","Index claim failed") end
end

function Engine.AutoClaimRewards()
	local remote = Remotes:FindFirstChild("ClaimDailyReward")
	if not remote then setStatus("AutoClaimRewards","Missing ClaimDailyReward"); return end
	if safe(function() remote:FireServer() end) then setStatus("AutoClaimRewards","Claimed rewards")
	else setStatus("AutoClaimRewards","Rewards failed") end
end

function Engine.AutoUpgrade()
	-- sube de nivel las player units (dropper units)
	local remote = Remotes:FindFirstChild("RequestPlayerUnitLevelUp")
	if not remote then setStatus("AutoUpgrade","Missing RequestPlayerUnitLevelUp"); return end
	if safe(function() remote:FireServer() end) then setStatus("AutoUpgrade","Upgraded")   -- TODO: confirmar si lleva arg (unidad)
	else setStatus("AutoUpgrade","Upgrade failed") end
end

-- Upgrade de cinta / colocados: el original usa partes/botones del plot, no un remote directo.
function Engine.AutoUpgradeConveyor()
	setStatus("AutoUpgradeConveyor","TODO: upgrade por parte del plot")   -- TODO contigo
end
function Engine.AutoUpgradePlaced()
	setStatus("AutoUpgradePlaced","TODO: upgrade por parte del plot")     -- TODO contigo
end
function Engine.AutoSellBoxes()
	setStatus("AutoSellBoxes","TODO: ruta de venta de cajas")             -- TODO contigo
end

-- ---- Explorado del juego: conveyor nativo · colectables · reroll · claims --
local remCache = {}
local function remote(name)
	if remCache[name] == nil then remCache[name] = Remotes:FindFirstChild(name) or false end
	return remCache[name] or nil
end
local function dataGet()
	local ok, d = pcall(function() return require(ReplicatedStorage.Client.Data.ClientDataManager).GetData() end)
	return ok and d or nil
end
local function tokenAmt(name)
	local d = dataGet(); return (d and d.Tokens and tonumber(d.Tokens[name])) or 0
end

-- Colectables del mapa: Collect<X>(parte tagueada)
function Engine.CollectVariant()
	local rem = remote("CollectVariantTokenSpawn"); if not rem then setStatus("CollectVariant","sin remote"); return end
	local n = 0
	for _, p in ipairs(CollectionService:GetTagged("VariantTokenSpawn")) do
		if p:GetAttribute("Occupied") and safe(function() rem:FireServer(p) end) then n += 1 end
	end
	setStatus("CollectVariant", n > 0 and ("Recogidos "..n) or "Sin variant tokens en el mapa")
end
function Engine.CollectObjects()
	local rem = remote("CollectCollectableObject"); if not rem then setStatus("CollectObjects","sin remote"); return end
	local n = 0
	for _, p in ipairs(CollectionService:GetTagged("CollectableObject")) do
		if safe(function() rem:FireServer(p) end) then n += 1 end
	end
	setStatus("CollectObjects", n > 0 and ("Recogidos "..n) or "Nada que recoger")
end
function Engine.ClaimOffline()
	local rem = remote("ClaimOfflineEarnings"); if not rem then return end
	safe(function() rem:FireServer() end); setStatus("ClaimOffline","Reclamado")
end

-- Reroll de trait/grade: TP a la estación y reroll de unidades EQUIPADAS hasta el objetivo.
-- (Verificado en vivo: RerollPlayerUnitTrait(unitKey, traitActual) · NewRerollPlayerUnitGrade(unitKey, false, gradeActual);
--  ambos exigen CanReachRollStation con TraitsHitbox/GradingHitbox + Tokens.Trait/Grade.)
local function tpStation(tag)
	local part = CollectionService:GetTagged(tag)[1]; local root = hrp()
	if part and root then
		safe(function()
			local cf = part:IsA("BasePart") and part.CFrame or part:GetPivot()
			root.CFrame = cf + Vector3.new(0, 3, 0)
		end)
	end
	return part ~= nil
end
local function firstEquippedNot(field, target)
	local d = dataGet(); if not (d and d.PlayerUnits) then return nil end
	for key, u in pairs(d.PlayerUnits) do
		if type(u) == "table" and u.Equipped and tostring(u[field]) ~= target then
			return key, tostring(u[field]), tostring(u.PlayerUnitName)
		end
	end
end
function Engine.RerollTrait()
	if State.TargetTrait == "Any" then setStatus("RerollTrait","Elige un trait objetivo"); return end
	if tokenAmt("Trait") <= 0 then setStatus("RerollTrait","Sin Trait Tokens"); return end
	local rem = remote("RerollPlayerUnitTrait"); if not rem then setStatus("RerollTrait","sin remote"); return end
	local key, cur, name = firstEquippedNot("Trait", State.TargetTrait)
	if not key then setStatus("RerollTrait","Equipadas ya en "..State.TargetTrait); return end
	if not tpStation("TraitsHitbox") then setStatus("RerollTrait","Estación no encontrada"); return end
	task.wait(0.12)
	safe(function() rem:FireServer(key, cur) end)
	setStatus("RerollTrait", ("%s: %s → %s? (tok %d)"):format(name, cur, State.TargetTrait, tokenAmt("Trait")))
end
function Engine.RerollGrade()
	if State.TargetGrade == "Any" then setStatus("RerollGrade","Elige un grade objetivo"); return end
	if tokenAmt("Grade") <= 0 then setStatus("RerollGrade","Sin Grade Tokens"); return end
	local rem = remote("NewRerollPlayerUnitGrade"); if not rem then setStatus("RerollGrade","sin remote"); return end
	local key, cur, name = firstEquippedNot("Grade", State.TargetGrade)
	if not key then setStatus("RerollGrade","Equipadas ya en "..State.TargetGrade); return end
	if not tpStation("GradingHitbox") then setStatus("RerollGrade","Estación no encontrada"); return end
	task.wait(0.12)
	safe(function() rem:FireServer(key, false, cur) end)
	setStatus("RerollGrade", ("%s: %s → %s? (tok %d)"):format(name, cur, State.TargetGrade, tokenAmt("Grade")))
end

-- ---- Events & Weather · Halloween Event Automation ------------------------
-- Verificado EN VIVO (decompilando HouseSystemModel / HalloweenService / CandyCornClient
-- / DayNightService) el 2026-10-26:
--   * Casas = instancias con tag CollectionService "HouseSystemModel" (84; incl. la boss
--     "HouseModelAdmin" en Map.HALLOWEEN-MainMap.House."Special Houses".BOSS_HOUSE).
--     El HouseName que espera el server = el .Name de ESE modelo (p.ej. "HouseModel41").
--   * Posición de knock: modelo.Door_Rig.PrimaryPart.PlayerAttachment (server exige
--     KnockRange = 20 studs).
--   * El knock REAL es  TrickOrTreat:InvokeServer(HouseName)  (RemoteFunction, devuelve
--     truthy si OK). El juego lo envuelve en una cutscene de ~5s (anims DoorKnock + Knock
--     + TossCandyReward) pero NO hace falta: invocamos directo y nos saltamos la animación.
--   * Gates del server: solo de NOCHE (DayNightService.CanTrickOrTreat) · cooldown por casa
--     (HalloweenService.IsHouseOnCooldown; HouseCooldown 300s / boss 3600s) · throttle
--     GLOBAL KnockCooldown = 5s entre knocks.
--   * Tras un knock OK el server dispara ThrowCandyCorns -> el cliente lanza CandyCorn a
--     workspace.Effects; CandyCornClient AUTO-RECOGE cualquiera a <=5 studs (CollectRange)
--     y hace CollectCandyCorn:FireServer(id). Vida 60s. => para COBRAR hay que pasar cerca:
--     barremos los CandyCorn de Effects acercando el HRP (reusa el colector del juego).
-- Ciclo día/noche: día 600s, noche 300s (900s). GetSecondsUntilChange() da el reloj.
local TOT   = { KnockCooldown = 5, KnockRange = 20, BossHouseName = "HouseModelAdmin" }
local CANDY = { CollectRange = 5 }
local HOUSE_TAG = "HouseSystemModel"

local HalloweenSvc, DayNight
local function reqServices()
	if not HalloweenSvc then pcall(function() HalloweenSvc = require(ReplicatedStorage.Shared.Services.HalloweenService) end) end
	if not DayNight    then pcall(function() DayNight    = require(ReplicatedStorage.Shared.Services.DayNightService) end) end
end
local function canToT()                 -- ¿se puede trick-or-treat ahora? (= es de noche)
	reqServices()
	if DayNight and DayNight.CanTrickOrTreat then
		local ok, v = pcall(DayNight.CanTrickOrTreat); if ok then return v == true end
	end
	return false
end
local function secsUntilChange()        -- segundos hasta el próximo cambio día<->noche
	reqServices()
	if DayNight and DayNight.GetSecondsUntilChange then
		local ok, v = pcall(DayNight.GetSecondsUntilChange); if ok and type(v) == "number" then return v end
	end
	return nil
end
local function houseOnCooldown(name)
	reqServices()
	if HalloweenSvc and HalloweenSvc.IsHouseOnCooldown then
		local ok, v = pcall(HalloweenSvc.IsHouseOnCooldown, LocalPlayer, name); if ok then return v == true end
	end
	return false
end
-- lista de casas: {name, cf} con el attachment donde el server espera al jugador
local function houseList()
	local out = {}
	for _, m in ipairs(CollectionService:GetTagged(HOUSE_TAG)) do
		local dr = m:FindFirstChild("Door_Rig")
		local pp = dr and dr.PrimaryPart
		local pa = pp and pp:FindFirstChild("PlayerAttachment")
		if pa and pa:IsA("Attachment") then
			out[#out+1] = { name = m.Name, cf = pa.WorldCFrame }
		end
	end
	return out
end
-- casas listas (no en cooldown) / total — para el dashboard del Overview
local function houseReadyCounts()
	local list = houseList()
	local ready = 0
	for _, h in ipairs(list) do if not houseOnCooldown(h.name) then ready += 1 end end
	return ready, #list
end
-- recoge los CandyCorn de workspace.Effects acercando el HRP (<=5 studs): el propio loop
-- del juego (checkProximity, cada 0.2s) los cobra y los borra. Acotado por 'deadline'.
local function sweepCandies(deadline)
	local root = hrp(); if not root then return 0 end
	local eff = workspace:FindFirstChild("Effects"); if not eff then return 0 end
	local got = 0
	while State.HalloweenKnock and os.clock() < deadline do
		local list = {}
		for _, c in ipairs(eff:GetChildren()) do
			if string.find(c.Name, "Candy") then list[#list+1] = c end
		end
		if #list == 0 then break end                 -- no quedan caramelos -> fin
		for _, c in ipairs(list) do
			if not (State.HalloweenKnock and os.clock() < deadline) then break end
			if c.Parent then
				safe(function() root.CFrame = CFrame.new(c:GetPivot().Position + Vector3.new(0, 2, 0)) end)
				task.wait(0.22)                        -- deja que el juego lo recoja
				got += 1
			end
		end
	end
	return got
end

local TrickOrTreat    = Remotes:FindFirstChild("TrickOrTreat")
local CollectCandyCorn = Remotes:FindFirstChild("CollectCandyCorn")
local CandyCornClient
pcall(function() CandyCornClient = require(ReplicatedStorage.Client.Core.CandyCornClient) end)
local lastKnock = 0                        -- GetServerTimeNow() del último knock OK (throttle)

-- saldo de la bolsa de caramelos del plot (se llena al knockear; al tope -> hay que vaciar)
local function candyBag()
	reqServices()
	local amt, maxb
	if HalloweenSvc then
		pcall(function() amt = HalloweenSvc.GetPlotCandyBagAmount(LocalPlayer) end)
		pcall(function()
			local plot = workspace.Map.PlotModels:FindFirstChild(LocalPlayer.Name)
			if plot then maxb = HalloweenSvc.GetMaxPlotCandyBagAmount(plot) end
		end)
	end
	return amt, maxb
end
-- vacía la bolsa del plot (PickupCandyBag sobre el CandyPart) para no estancarse en el tope
local function emptyCandyBag()
	local rem = remote("PickupCandyBag"); if not rem then return false end
	local part = CollectionService:GetTagged("ConveyorCandyCollectPart")[1]
	if not part then return false end
	return safe(function() rem:FireServer(part) end)
end
-- OPCIÓN SEPARADA (no es parte del farm de casas): recoger la bolsa del plot y venderla.
function Engine.CandyBagSell()
	local before = candyBag()
	emptyCandyBag()                                   -- recoger (vacía el plot bag)
	task.wait(0.3)
	local sell = remote("SellCandyBag")               -- vender si quedó una bolsa en mano
	local sold = 0
	if sell then
		local function trySell(c)
			if not c then return end
			for _, t in ipairs(c:GetChildren()) do
				if t:IsA("Tool") then
					local g = t:GetAttribute("CandyBagGuid")
					if g and safe(function() sell:FireServer(g) end) then sold += 1 end
				end
			end
		end
		trySell(LocalPlayer.Character); trySell(LocalPlayer:FindFirstChild("Backpack"))
	end
	setStatus("CandyBagSell", before and before > 0 and ("Recogida (%s)%s"):format(tostring(before), sold > 0 and (" · vendidas "..sold) or "") or "Bolsa vacía")
end

-- Un "pase" recorre todas las casas disponibles. El loop externo lo repite (KnockDelay).
function Engine.HalloweenKnock()
	if not TrickOrTreat then setStatus("HalloweenKnock", "Falta remote TrickOrTreat"); return end
	local root = hrp()
	if not canToT() then
		local s = secsUntilChange()
		setStatus("HalloweenKnock", s and ("Esperando noche (%ds)"):format(math.floor(s)) or "Solo de noche…")
		return
	end
	local houses = houseList()
	if #houses == 0 then setStatus("HalloweenKnock", "Evento no activo / sin casas"); return end

	local origin  = (State.KnockReturn and root) and root.CFrame or nil
	local knocked = 0
	for _, h in ipairs(houses) do
		if not State.HalloweenKnock then break end
		if not canToT() then setStatus("HalloweenKnock", "Se hizo de día — en pausa"); break end
		local skipBoss = (h.name == TOT.BossHouseName) and not State.KnockBoss
		if not skipBoss and not houseOnCooldown(h.name) then
			-- respeta el throttle GLOBAL de 5s del server
			local remain = TOT.KnockCooldown - (serverNow() - lastKnock)
			while remain > 0 and State.HalloweenKnock do task.wait(0.15); remain = TOT.KnockCooldown - (serverNow() - lastKnock) end
			if not State.HalloweenKnock then break end
			-- si el personaje murió (hay casas que matan), espera el respawn y continúa
			root = hrp()
			while not (root and root.Parent) and State.HalloweenKnock do
				setStatus("HalloweenKnock", "Muerto — esperando respawn…"); task.wait(0.4); root = hrp()
			end
			if not State.HalloweenKnock then break end
			-- colócate en la puerta (server valida KnockRange=20) y knockea DIRECTO
			safe(function() root.CFrame = h.cf end)
			task.wait(0.2)                 -- deja replicar la posición
			local ok, v39, v40, v41 = pcall(function() return TrickOrTreat:InvokeServer(h.name) end)
			if ok and v39 then
				lastKnock = serverNow()
				knocked += 1
				setStatus("HalloweenKnock", ("Knock %d · %s · esperando al NPC…"):format(knocked, h.name))
				-- el NPC lanza los caramelos TRAS la animación. Nos quedamos en la casa
				-- (no volvemos), los lanzamos como hace el juego y ESPERAMOS a que caigan.
				if type(v41) == "table" and CandyCornClient and CandyCornClient.Throw then
					pcall(function() CandyCornClient.Throw(h.cf.Position, v41, v40 and v40.ThrowDuration) end)
				end
				local dur = (v40 and tonumber(v40.ThrowDuration)) or 1.5
				local t = 0
				while t < dur + 1.0 and State.HalloweenKnock do task.wait(0.2); t += 0.2 end
				-- ya están tirados: recogerlos (proximidad acercando el HRP + remate por Id)
				sweepCandies(os.clock() + 2.5)
				local got = 0
				if type(v41) == "table" and CollectCandyCorn then
					for _, e in ipairs(v41) do
						local id = e.Id or e.id
						if id and safe(function() CollectCandyCorn:FireServer(id) end) then got += 1 end
					end
				end
				setStatus("HalloweenKnock", ("Knock %d · %s (+%d caramelos)"):format(knocked, h.name, got))
			else
				setStatus("HalloweenKnock", ("Rechazado: %s (¿de día/cooldown?)"):format(h.name))
			end
		end
	end
	if origin then safe(function() root.CFrame = origin end) end
	if State.HalloweenKnock then setStatus("HalloweenKnock", ("Pase completo: %d knock(s)"):format(knocked)) end
end

--========================================================================
--  FEATURES DE CLIENTE (sin remotes)
--========================================================================
local clientConns = {}

local function applyWalkSpeed()
	local h = humanoid(); if h then h.WalkSpeed = State.WalkSpeedOn and State.WalkSpeedAmt or 16 end
end

local function startInfJump()
	if clientConns.InfJump then return end
	clientConns.InfJump = UserInputService.JumpRequest:Connect(function()
		if State.InfJump then local h = humanoid(); if h then h:ChangeState(Enum.HumanoidStateType.Jumping) end end
	end)
end

local function startNoClip()
	if clientConns.NoClip then return end
	clientConns.NoClip = RunService.Stepped:Connect(function()
		if State.NoClip and LocalPlayer.Character then
			for _, p in ipairs(LocalPlayer.Character:GetDescendants()) do
				if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
			end
		end
	end)
end

-- Fly
local flyBV, flyBG, flyConn
local function stopFly()
	if flyBV then flyBV:Destroy(); flyBV = nil end
	if flyBG then flyBG:Destroy(); flyBG = nil end
	if flyConn then flyConn:Disconnect(); flyConn = nil end
	local h = humanoid(); if h then h.PlatformStand = false end
end
local function startFly()
	local root, h = hrp(), humanoid()
	if not (root and h) then return end
	stopFly()
	h.PlatformStand = true
	flyBV = Instance.new("BodyVelocity"); flyBV.MaxForce = Vector3.new(1,1,1)*9e9; flyBV.Velocity = Vector3.zero; flyBV.Parent = root
	flyConn = RunService.RenderStepped:Connect(function()
		if not State.Fly then stopFly(); return end
		local cam = workspace.CurrentCamera
		local dir = Vector3.zero
		local function down(k) return UserInputService:IsKeyDown(k) end
		if down(Enum.KeyCode.W) then dir += cam.CFrame.LookVector end
		if down(Enum.KeyCode.S) then dir -= cam.CFrame.LookVector end
		if down(Enum.KeyCode.A) then dir -= cam.CFrame.RightVector end
		if down(Enum.KeyCode.D) then dir += cam.CFrame.RightVector end
		if down(Enum.KeyCode.Space) then dir += Vector3.yAxis end
		if down(Enum.KeyCode.LeftControl) then dir -= Vector3.yAxis end
		flyBV.Velocity = (dir.Magnitude > 0 and dir.Unit or Vector3.zero) * State.FlySpeed
	end)
end

-- Instant ProximityPrompt
local promptConn
local function patchPrompt(p)
	if p:IsA("ProximityPrompt") then
		p.HoldDuration = 0
		p.MaxActivationDistance = math.max(p.MaxActivationDistance, 50)
		p.RequiresLineOfSight = false
	end
end
local function startInstantPrompt()
	if promptConn then return end
	for _, p in ipairs(workspace:GetDescendants()) do patchPrompt(p) end
	promptConn = workspace.DescendantAdded:Connect(function(d)
		if State.InstantPrompt then patchPrompt(d) end
	end)
end
local function stopInstantPrompt()
	if promptConn then promptConn:Disconnect(); promptConn = nil end
end

--========================================================================
--  SETTINGS DE SESIÓN
--========================================================================
-- Anti-AFK (VirtualUser evita el kick por idle)
do
	local VirtualUser = cloneref and cloneref(game:GetService("VirtualUser")) or game:GetService("VirtualUser")
	LocalPlayer.Idled:Connect(function()
		if State.AntiAfk then
			VirtualUser:CaptureController()
			VirtualUser:ClickButton2(Vector2.new())
		end
	end)
end

-- FPS Boost (desactiva efectos visuales)
local fpsBackup
local function applyFpsBoost()
	if State.FpsBoost then
		Lighting.GlobalShadows = false
		Lighting.FogEnd = 9e9
		for _, d in ipairs(workspace:GetDescendants()) do
			if d:IsA("ParticleEmitter") or d:IsA("Beam") or d:IsA("Trail") or d:IsA("Smoke")
			or d:IsA("Sparkles") or d:IsA("Explosion") or d:IsA("Fire") then
				d.Enabled = false
			end
		end
	end
end

-- Disable 3D Rendering (apaga el render del mundo = FPS altísimos)
local function applyDisable3D()
	pcall(function() RunService:Set3DRenderingEnabled(not State.Disable3D) end)
	pcall(function() RunService:Set3dRenderingEnabled(not State.Disable3D) end)
end

-- ---- Webhook de Discord (envío real con request del executor) ----
local HttpService   = game:GetService("HttpService")
local httpRequest   = (syn and syn.request) or (http and http.request) or http_request or request
local NOVA_COLOR    = 7331501   -- #6FDEAD
local function sendWebhook(payload)
	local url = State.WebhookUrl
	if not url or #url < 12 or not httpRequest then return false end
	return (pcall(function()
		httpRequest({ Url = url, Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = HttpService:JSONEncode(payload) })
	end))
end
local function unitEmbed(id, data)
	local fields = {}
	if type(data) == "table" then
		for _, k in ipairs({ "Type", "Rarity", "Variant", "Grade" }) do
			if data[k] ~= nil then fields[#fields+1] = { name = k, value = tostring(data[k]), inline = true } end
		end
	end
	return { username = "Nova Hub", embeds = {{ title = "Nuevo: " .. tostring(id),
		color = NOVA_COLOR, fields = fields, footer = { text = LocalPlayer.Name .. " · Blue Lock Farm" } }} }
end
local function statsEmbed()
	local cash, candy, units = "?", "?", 0
	pcall(function()
		local d = require(ReplicatedStorage.Client.Data.ClientDataManager).GetData()
		if d.Currency then cash = tostring(d.Currency.Cash) end
		if d.Events and d.Events.Halloween_2026 then candy = tostring(d.Events.Halloween_2026.PlotCandyBagAmount) end
		for _ in pairs(d.PlayerUnits or {}) do units += 1 end
	end)
	return { username = "Nova Hub", embeds = {{ title = "Stats · " .. LocalPlayer.Name, color = NOVA_COLOR, fields = {
		{ name = "Cash", value = cash, inline = true },
		{ name = "Candy Bag", value = candy, inline = true },
		{ name = "Unidades", value = tostring(units), inline = true } } }} }
end
-- hook de ítems/unidades nuevas: envuelve NewItemsGuiClient.NewItem
local whHooked = false
local function startNewUnitsHook()
	if whHooked then return end
	whHooked = true
	pcall(function()
		local N = require(ReplicatedStorage.Client.Core.Gui.NewItemsGuiClient)
		local orig = N.NewItem
		N.NewItem = function(id, ...)
			if State.SendNewUnits then
				local data; pcall(function() data = require(ReplicatedStorage.Shared.Services.ItemService).GetItemData(id) end)
				local passV = (State.WhVariant == "None") or (data and tostring(data.Variant) == State.WhVariant)
				local passL = (State.WhFromLockers == "None")
					or (tostring(id):find(tostring(State.WhFromLockers)) ~= nil)
					or (data and tostring(data.Box or "") == State.WhFromLockers)
				if passV and passL then task.spawn(sendWebhook, unitEmbed(id, data)) end
			end
			return orig(id, ...)
		end
	end)
end
local statsThread
local function startStatsLoop()
	if statsThread then return end
	statsThread = task.spawn(function()
		while State.SendStats do
			sendWebhook(statsEmbed())
			local t, target = 0, (State.StatsEvery or 10) * 60
			while t < target and State.SendStats do task.wait(1); t += 1 end
		end
		statsThread = nil
	end)
end

-- Auto Reconnect on Kick
GuiService.ErrorMessageChanged:Connect(function()
	if State.AutoReconnect then
		task.wait(1)
		TeleportService:Teleport(game.PlaceId, LocalPlayer)
	end
end)

--========================================================================
--  ARRANQUE DE LOOPS SEGÚN FLAG
--========================================================================
local featureLoop = {
	AutoRoll={"AutoRoll",Engine.AutoRoll,"RollDelay"},
	AutoSell={"AutoSell",Engine.AutoSell,"SellDelay"},
	AutoSellBoxes={"AutoSellBoxes",Engine.AutoSellBoxes,"SellBoxesDelay"},
	AutoCarry={"AutoCarry",Engine.AutoCarry,"CarryDelay"},
	AutoPlace={"AutoPlace",Engine.AutoPlace,"PlaceDelay"},
	AutoOpen={"AutoOpen",Engine.AutoOpen,"OpenDelay"},
	AutoEquipBest={"AutoEquipBest",Engine.AutoEquipBest,"EquipDelay"},
	AutoClaimIndex={"AutoClaimIndex",Engine.AutoClaimIndex,"IndexDelay"},
	AutoClaimRewards={"AutoClaimRewards",Engine.AutoClaimRewards,"RewardsDelay"},
	AutoUpgrade={"AutoUpgrade",Engine.AutoUpgrade,"UpgradeDelay"},
	AutoUpgradeConveyor={"AutoUpgradeConveyor",Engine.AutoUpgradeConveyor,"ConveyorUpgradeDelay"},
	AutoUpgradePlaced={"AutoUpgradePlaced",Engine.AutoUpgradePlaced,"PlacedDelay"},
	HalloweenKnock={"HalloweenKnock",Engine.HalloweenKnock,"KnockDelay"},
	CandyBagSell={"CandyBagSell",Engine.CandyBagSell,"CandyBagDelay"},
	CollectVariant={"CollectVariant",Engine.CollectVariant,"CollectVariantDelay"},
	CollectObjects={"CollectObjects",Engine.CollectObjects,"CollectObjectsDelay"},
	ClaimOffline={"ClaimOffline",Engine.ClaimOffline,"OfflineDelay"},
	RerollTrait={"RerollTrait",Engine.RerollTrait,"RerollTraitDelay"},
	RerollGrade={"RerollGrade",Engine.RerollGrade,"RerollGradeDelay"},
}

-- se llama cada vez que un toggle cambia
local function onToggle(flag, value)
	State[flag] = value
	if featureLoop[flag] then
		if value then loop(table.unpack(featureLoop[flag])) end
	elseif flag == "WalkSpeedOn" then applyWalkSpeed()
	elseif flag == "InfJump" then if value then startInfJump() end
	elseif flag == "NoClip" then if value then startNoClip() end
	elseif flag == "InstantPrompt" then if value then startInstantPrompt() else stopInstantPrompt() end
	elseif flag == "Fly" then if value then startFly() else stopFly() end
	elseif flag == "FpsBoost" then applyFpsBoost()
	elseif flag == "Disable3D" then applyDisable3D()
	elseif flag == "SendNewUnits" then if value then startNewUnitsHook() end
	elseif flag == "SendStats" then if value then startStatsLoop() end
	elseif flag == "ConvAutoBuy" then local r = Remotes:FindFirstChild("RequestSetConveyorAutoBuy"); if r then safe(function() r:FireServer(value) end) end
	elseif flag == "ConvAutoSpawn" then local r = Remotes:FindFirstChild("RequestSetConveyorAutoSpawn"); if r then safe(function() r:FireServer(value) end) end
	end
end

--========================================================================
--  UI  ·  Rayfield Gen2  (STANDALONE — lib pública vendorizada en el repo)
--========================================================================
-- Nova ya NO depende de Aster: carga su propia copia de Rayfield Gen2 1.2.0
-- (el bundled.luau oficial, fijado en el repo) y le aplica el tema "Aster"
-- extraído en vivo. El stock usa camelCase pero ACEPTA PascalCase, así que el
-- resto de Nova (escrito en PascalCase) funciona igual. Lo que la build de
-- Aster tenía de más (Groupbox/Status/ButtonRow/Theme&ConfigManager y varios
-- Window:*) se emula aquí con un adaptador fino sobre el stock.

-- Paleta "Aster" (13 colores semánticos) mapeada al esquema de tema del stock.
-- Es un tema PARCIAL: el resto de claves caen al default de la lib.
local AsterTheme = {
	WindowColor = ColorSequence.new({
		ColorSequenceKeypoint.new(0,      Color3.fromRGB(13, 19, 21)),
		ColorSequenceKeypoint.new(0.9999, Color3.fromRGB(22, 32, 34)),
		ColorSequenceKeypoint.new(1,      Color3.fromRGB(35, 49, 49)),
	}),
	ShadowColor           = Color3.fromRGB(8, 12, 13),
	ElementStroke         = Color3.fromRGB(40, 57, 56),
	ElementGradient       = ColorSequence.new(Color3.fromRGB(18, 26, 28), Color3.fromRGB(22, 32, 34)),
	ElementStrokeGradient = ColorSequence.new(Color3.fromRGB(40, 57, 56), Color3.fromRGB(66, 101, 89)),
	ElementStrokeHover    = Color3.fromRGB(66, 101, 89),
	TabColor              = Color3.fromRGB(233, 244, 237),
	TabBackground         = ColorSequence.new(Color3.fromRGB(35, 49, 49), Color3.fromRGB(18, 26, 28)),
	TabStroke             = ColorSequence.new(Color3.fromRGB(66, 101, 89), Color3.fromRGB(40, 57, 56)),
	SliderBackground      = Color3.fromRGB(35, 49, 49),
	SliderBackgroundHover = Color3.fromRGB(66, 101, 89),
	SliderProgress        = ColorSequence.new(Color3.fromRGB(111, 222, 173), Color3.fromRGB(80, 170, 130)),
	SliderStroke          = Color3.fromRGB(233, 244, 237),
	SliderHandle          = Color3.fromRGB(233, 244, 237),
	ActionColor           = Color3.fromRGB(233, 244, 237),
	ContentColor          = Color3.fromRGB(233, 244, 237),
	TitlingColor          = Color3.fromRGB(233, 244, 237),
	ElementTextHoverColor = Color3.fromRGB(233, 244, 237),
	DropdownHighlight     = Color3.fromRGB(111, 222, 173),
	AccentColor           = Color3.fromRGB(111, 222, 173),
	AccentStroke          = Color3.fromRGB(132, 226, 170),
	StatBackground        = Color3.fromRGB(18, 26, 28),
	ToggleTrack           = Color3.fromRGB(12, 37, 29),
	PlaceholderColor      = Color3.fromRGB(138, 162, 155),
	NeutralButton         = Color3.fromRGB(35, 49, 49),
	NeutralButtonHover    = Color3.fromRGB(66, 101, 89),
	ErrorColor            = Color3.fromRGB(185, 70, 76),
	ErrorStrokeColor      = Color3.fromRGB(244, 125, 132),
}

-- Carga de la librería (vendorizada en el repo; el repo debe ser PÚBLICO).
local RAYFIELD_URL = "https://raw.githubusercontent.com/Kaiz-2/NovaHub/main/Rayfield.lua"
local okLib, Rayfield = pcall(function()
	return loadstring(game:HttpGet(RAYFIELD_URL))()
end)
if not okLib or type(Rayfield) ~= "table" then
	warn("[Nova Hub] No pude cargar Rayfield Gen2 desde el repo: " .. tostring(Rayfield))
	warn("[Nova Hub] ¿El repo Kaiz-2/NovaHub es público? URL: " .. RAYFIELD_URL)
	return
end

-- si se reinyecta Nova, descarga la ventana anterior
if getgenv then
	local prev = getgenv().__NovaWindow
	if prev then pcall(function() prev:Unload() end); getgenv().__NovaWindow = nil end
end

local Window = Rayfield:CreateWindow({
	name = "Nova Hub",
	subtitle = "Blue Lock Farm",
	sidebarLayout = true,
	theme = AsterTheme,
	configuration = { autoSave = true, autoLoad = false, fileName = "NovaHub_BlueLockFarm" },
})
if getgenv then getgenv().__NovaWindow = Window end

--------------------------------------------------------------------------
-- ADAPTADOR: añade al stock los métodos que la build de Aster tenía de más.
-- (El stock acepta props PascalCase, así que no hace falta traducir claves.)
--------------------------------------------------------------------------
-- Window:* que no existen en el stock -> se mapean o se vuelven no-op.
do
	local W = Window
	W.SelectTab   = W.SelectTab   or function(self, t) return self:Navigate(t) end
	W.Destroy     = W.Destroy     or function(self) return self:Unload() end
	W.SetMinimized = W.SetMinimized or function(self, b) if b then self:Hide() else self:Show() end end
	W.SetBackground = W.SetBackground or function() end
	W.SetBackgroundTransparency = W.SetBackgroundTransparency or function() end
	W.ListBackgrounds = W.ListBackgrounds or function() return { "None" } end
	W.SetDensity  = W.SetDensity  or function() end
	W.SetKeybind  = W.SetKeybind  or function() end
	W.Confirm     = W.Confirm     or function(self, p)
		local opts = {}
		for _, o in ipairs(p.Options or p.options or {}) do
			opts[#opts + 1] = { text = o.Text or o.text, style = o.Style or o.style, callback = o.Callback or o.callback }
		end
		return self:Popup({ title = p.Title or p.title, content = p.Content or p.content, options = opts })
	end
end

-- Emula el "groupbox" de Aster: pinta una Section como cabecera y reenvía la
-- creación de elementos a la propia pestaña (layout en una sola columna).
local function makeGroupbox(tab, props)
	local title = props and (props.Name or props.name)
	if title then pcall(function() tab:CreateSection({ name = title }) end) end
	local g = {}
	for _, m in ipairs({
		"CreateToggle", "CreateSlider", "CreateDropdown", "CreateInput", "CreateKeybind",
		"CreateColorPicker", "CreateButton", "CreateProgress", "CreateStat",
		"CreateStatus", "CreateParagraph", "CreateButtonRow", "CreateSection",
		"CreateDivider", "CreateText",
	}) do
		g[m] = function(_, p) return tab[m](tab, p) end
	end
	g.Collapse = function() end; g.Expand = function() end
	g.SetTitle = function() end; g.SetBadge = function() end
	return g
end

-- Parchea una pestaña del stock con los Create* extra que usa Nova.
local function patchTab(tab)
	tab.CreateGroupbox   = function(self, p) return makeGroupbox(self, p) end
	tab.AddLeftGroupbox  = tab.CreateGroupbox
	tab.AddRightGroupbox = tab.CreateGroupbox
	-- Status (texto vivo) -> Text del stock, con :Set/:SetTone/:SetName.
	tab.CreateStatus = function(self, p)
		local t = self:CreateText({ name = p.Name or p.name, text = p.Text or p.text or "" })
		return {
			Set     = function(_, v) pcall(function() t:Set(tostring(v)) end) end,
			Get     = function() return t.text end,
			SetTone = function() end,
			SetColor = function() end,
			SetName = function(_, n) pcall(function() t:SetTitle(n) end) end,
			Destroy = function() pcall(function() t:Remove() end) end,
		}
	end
	-- Paragraph (título + cuerpo) -> Text del stock.
	tab.CreateParagraph = function(self, p)
		local t = self:CreateText({ name = p.Name or p.name, text = p.Text or p.text or "" })
		return {
			Set      = function(_, body) pcall(function() t:Set(body) end) end,
			SetTitle = function(_, x) pcall(function() t:SetTitle(x) end) end,
			Destroy  = function() pcall(function() t:Remove() end) end,
		}
	end
	-- ButtonRow -> fila de botones (Group "row"), o botones sueltos si falla.
	tab.CreateButtonRow = function(self, p)
		local btns = p.Buttons or p.buttons or {}
		local ok, row = pcall(function() return self:CreateGroup({ direction = "row" }) end)
		local host = (ok and row) or self
		for _, b in ipairs(btns) do
			pcall(function() host:CreateButton({ name = b.Name or b.name, callback = b.Callback or b.callback }) end)
		end
	end
	-- ThemeManager -> selector de temas (incluye "Aster").
	tab.CreateThemeManager = function(self)
		pcall(function() self:CreateSection({ name = "Themes" }) end)
		pcall(function()
			self:CreateDropdown({
				name = "Theme",
				options = { "Aster", "Default", "Amethyst", "Cobalt", "Ember", "Frost", "Rose" },
				value = "Aster",
				callback = function(v)
					if type(v) == "table" then v = v[1] end
					if v == "Aster" then Window:ChangeTheme(AsterTheme) else Window:ChangeTheme(string.lower(v)) end
				end,
			})
		end)
	end
	-- ConfigManager -> guardar/cargar config con nombre.
	tab.CreateConfigManager = function(self)
		pcall(function() self:CreateSection({ name = "Configs" }) end)
		local box
		pcall(function() box = self:CreateInput({ name = "Config name", placeholder = "NovaHub", value = "" }) end)
		pcall(function() self:CreateButton({ name = "Guardar config", callback = function() pcall(function() Window:Save(box and box.value) end) end }) end)
		pcall(function() self:CreateButton({ name = "Cargar config", callback = function() pcall(function() Window:Load(box and box.value) end) end }) end)
	end
	return tab
end

-- helpers que puentean Rayfield -> backend de Nova (State + onToggle + Engine)
local function mkTab(title, icon)
	local ok, t = pcall(function() return Window:CreateTab({ Name = title, Icon = icon }) end)
	if not ok or not t then t = Window:CreateTab({ Name = title }) end
	return patchTab(t)
end
local function T(tab, title, flag, desc)              -- toggle ligado a onToggle
	tab:CreateToggle({
		Name = title, Value = State[flag] == true, Description = desc, Flag = "Nova_" .. flag,
		Callback = function(state) onToggle(flag, state) end,
	})
end
local function Sl(tab, title, key, mn, mx, inc, suffix) -- slider ligado a State[key]
	tab:CreateSlider({
		Name = title, Range = { mn, mx }, Increment = inc or 1, Value = State[key], Suffix = suffix,
		Callback = function(v) State[key] = v end,
	})
end

local tAdv  -- fwd: lo usa el botón "Ir a Halloween" del Overview (SelectTab)
local function panic()  -- apaga toda la automatización
	for _, c in pairs(clientConns) do pcall(function() c:Disconnect() end) end
	stopFly(); stopInstantPrompt()
	for k in pairs(State) do if type(State[k]) == "boolean" then State[k] = false end end
end

-- ===== OVERVIEW (dashboard: groupbox 2 columnas + Status vivo + Progress + ButtonRow) =====
local tOverview = mkTab("Overview", "layout-dashboard")
tOverview:CreateParagraph({ Name = "Nova Hub", Text = "Hub sobre Rayfield Gen2 (la misma librería que Aster). El Halloween (pestaña Adventure) solo knockea de noche; el juego impone ~5s entre casas." })
local gEstado = tOverview:AddLeftGroupbox({ Name = "Estado" })
local gAtajos = tOverview:AddRightGroupbox({ Name = "Atajos" })
local stNight  = gEstado:CreateStatus({ Name = "Trick-or-Treat", Text = "…" })
local stHouses = gEstado:CreateStatus({ Name = "Casas listas", Text = "0" })
local prHouses = gEstado:CreateProgress({ Name = "Casas listas %", Range = { 0, 100 }, Value = 0 })
gAtajos:CreateButtonRow({ Buttons = {
	{ Name = "Todo OFF", Callback = function() panic(); pcall(function() Window:Notify({ Title = "Nova", Content = "Todo apagado", Icon = "power" }) end) end },
	{ Name = "Ir a Halloween", Callback = function() pcall(function() Window:SelectTab(tAdv) end) end },
} })
-- updater vivo: demuestra Status:Set/:SetTone y Progress:Set
task.spawn(function()
	while Window and not Window.unloaded do
		local night = canToT()
		local ready, total = houseReadyCounts()
		local s = secsUntilChange()
		pcall(function()
			if night then
				stNight:Set(s and ("Noche · %ds"):format(math.floor(s)) or "DISPONIBLE (noche)")
				stNight:SetTone("positive")
			else
				stNight:Set(s and ("Día · noche en %ds"):format(math.floor(s)) or "Solo de noche")
				stNight:SetTone("neutral")
			end
			stHouses:Set(tostring(ready) .. " / " .. tostring(total))
			stHouses:SetTone(ready > 0 and "positive" or "neutral")
			prHouses:Set(total > 0 and math.floor(ready / total * 100) or 0)
		end)
		task.wait(2)
	end
end)

-- ===== FARM =====
local tFarm = mkTab("Farm", "sprout")
local gRoll = tFarm:CreateGroupbox({ Name = "Rolling" })
T(gRoll, "Auto Roll", "AutoRoll");            Sl(gRoll, "Roll Delay", "RollDelay", 0.1, 2, 0.05, "s")
T(gRoll, "Auto Buy Roll", "AutoBuy")
T(gRoll, "Skip If Unaffordable", "SkipUnaffordable")
local gLock = tFarm:CreateGroupbox({ Name = "Lockers" })
T(gLock, "Auto Place Lockers", "AutoPlace");  Sl(gLock, "Place Delay", "PlaceDelay", 0.1, 2, 0.05, "s")
T(gLock, "Auto Open Lockers", "AutoOpen");    Sl(gLock, "Open Delay", "OpenDelay", 0.1, 2, 0.05, "s")
T(gLock, "Auto Carry Boxes", "AutoCarry");    Sl(gLock, "Carry Delay", "CarryDelay", 0.1, 2, 0.05, "s")
local gConv = tFarm:CreateGroupbox({ Name = "Conveyor (nativo del juego)" })
T(gConv, "Conveyor Auto Buy", "ConvAutoBuy", "Activa el auto-compra de cajas de la cinta (del propio juego).")
T(gConv, "Conveyor Auto Spawn", "ConvAutoSpawn", "Activa el auto-spawn de la cinta (del propio juego).")
local gCol = tFarm:CreateGroupbox({ Name = "Collectables" })
T(gCol, "Auto Collect Variant Tokens", "CollectVariant", "Recoge los variant tokens que aparecen en el mapa.")
T(gCol, "Auto Collect Collectables", "CollectObjects", "Recoge los objetos coleccionables del mapa.")

-- ===== ECONOMY =====
local tEco = mkTab("Economy", "coins")
local gSell = tEco:CreateGroupbox({ Name = "Selling" })
gSell:CreateDropdown({
	Name = "Sell Mode", Options = { "Crates", "Merchant" }, Value = State.SellMode or "Crates",
	Callback = function(v) State.SellMode = v end,
})
T(gSell, "Auto Sell", "AutoSell");             Sl(gSell, "Sell Delay", "SellDelay", 0.1, 3, 0.05, "s")
T(gSell, "Auto Sell Boxes", "AutoSellBoxes");  Sl(gSell, "Sell Boxes Delay", "SellBoxesDelay", 0.1, 3, 0.05, "s")
local gRew = tEco:CreateGroupbox({ Name = "Rewards" })
T(gRew, "Auto Claim Index", "AutoClaimIndex");     Sl(gRew, "Index Delay", "IndexDelay", 0.5, 5, 0.1, "s")
T(gRew, "Auto Claim Rewards", "AutoClaimRewards"); Sl(gRew, "Rewards Delay", "RewardsDelay", 0.5, 5, 0.1, "s")
T(gRew, "Auto Claim Offline Earnings", "ClaimOffline", "Reclama las ganancias offline al volver.")

-- ===== UNITS =====
local tUnits = mkTab("Units", "users")
local gUnits = tUnits:CreateGroupbox({ Name = "Units" })
T(gUnits, "Auto Equip Best", "AutoEquipBest");   Sl(gUnits, "Equip Delay", "EquipDelay", 1, 10, 0.1, "s")
T(gUnits, "Auto Upgrade", "AutoUpgrade");        Sl(gUnits, "Upgrade Delay", "UpgradeDelay", 0.1, 3, 0.05, "s")
T(gUnits, "Auto Upgrade Placed", "AutoUpgradePlaced")
T(gUnits, "Auto Upgrade Conveyor", "AutoUpgradeConveyor")
local gReroll = tUnits:CreateGroupbox({ Name = "Reroll (equipadas → objetivo)" })
do
	local traitOpts = { "Any" }
	pcall(function() for k in pairs(require(ReplicatedStorage.Shared.Core.Storage.Game.TraitsLibrary)) do traitOpts[#traitOpts+1] = tostring(k) end end)
	gReroll:CreateDropdown({ Name = "Target Trait", Options = traitOpts, Value = "Any",
		Callback = function(v) State.TargetTrait = v end })
	T(gReroll, "Auto Reroll Trait", "RerollTrait", "TP a la estación y rerollea las unidades equipadas hasta el trait objetivo (gasta Trait Tokens).")
	local gradeOpts = { "Any" }
	pcall(function() for k in pairs(require(ReplicatedStorage.Shared.Core.Storage.Game.GradesLibrary)) do gradeOpts[#gradeOpts+1] = tostring(k) end end)
	gReroll:CreateDropdown({ Name = "Target Grade (stats)", Options = gradeOpts, Value = "Any",
		Callback = function(v) State.TargetGrade = v end })
	T(gReroll, "Auto Reroll Grade", "RerollGrade", "TP a la estación y rerollea el grade/stats de las equipadas hasta el objetivo (gasta Grade Tokens).")
end

-- ===== ADVENTURE (Events / Halloween de Song Hub) =====
tAdv = mkTab("Adventure", "ghost")
local gHw = tAdv:CreateGroupbox({ Name = "Halloween · Trick-or-Treat" })
gHw:CreateParagraph({ Name = "Cómo funciona", Text = "Recorre las 84 casas: TP a la puerta → TrickOrTreat directo (sin esperar la animación de ~5s) → recoge los caramelos que dropea el NPC acercándose a ellos. Solo de noche; el juego impone 5s entre knocks y 300s de cooldown por casa (boss 1h)." })
local stAdv = gHw:CreateStatus({ Name = "Estado", Text = "Idle" })
task.spawn(function() while Window and not Window.unloaded do pcall(function() stAdv:Set(status.HalloweenKnock or "Idle") end); task.wait(1) end end)
T(gHw, "Farmear evento (auto knock + caramelos)", "HalloweenKnock", "Knockea todas las casas de noche y cobra los caramelos.")
T(gHw, "Incluir casa BOSS", "KnockBoss", "También knockea HouseModelAdmin (cooldown 1h, premio grande).")
T(gHw, "Volver a la posición inicial al terminar", "KnockReturn")
Sl(gHw, "Pausa entre pases", "KnockDelay", 0.3, 5, 0.1, "s")
local gBag = tAdv:CreateGroupbox({ Name = "Bolsa de caramelos (aparte)" })
gBag:CreateParagraph({ Name = "Nota", Text = "Independiente del farm de casas: recoge la bolsa del plot y la vende." })
T(gBag, "Auto recoger + vender bolsa", "CandyBagSell", "PickupCandyBag + SellCandyBag cada X segundos.")
Sl(gBag, "Cada", "CandyBagDelay", 2, 60, 1, "s")

-- ===== WEBHOOK  (copiado de Aster: Webhook · New Units · Stats, con envío REAL a Discord) =====
local tWeb = mkTab("Webhook", "webhook")
local gWh = tWeb:CreateGroupbox({ Name = "Webhook" })
gWh:CreateInput({ Name = "Webhook URL", Placeholder = "https://discord.com/api/webhooks/...", Value = State.WebhookUrl or "",
	Callback = function(v) State.WebhookUrl = v end })
gWh:CreateButton({ Name = "Send Test", Callback = function()
	local ok = sendWebhook({ username = "Nova Hub", embeds = {{ title = "Test ✓",
		description = "Webhook conectado desde Nova Hub.", color = NOVA_COLOR }} })
	pcall(function() Window:Notify({ Title = "Webhook", Content = ok and "Test enviado ✓" or "Falló (revisa URL/executor)", Icon = ok and "check" or "x" }) end)
end })
local gNU = tWeb:CreateGroupbox({ Name = "New Units" })
T(gNU, "Send New Units", "SendNewUnits", "Publica en Discord cada unidad/ítem nuevo que obtengas.")
do  -- From Lockers y Variants: filtros (None = sin filtro); poblados desde el juego
	local boxOpts = { "None" }
	pcall(function()
		local B = require(ReplicatedStorage.Shared.Core.Storage.Game.BoxesLibrary)
		for k in pairs(B) do boxOpts[#boxOpts+1] = tostring(k) end
	end)
	gNU:CreateDropdown({ Name = "From Lockers", Options = boxOpts, Value = "None",
		Callback = function(v) State.WhFromLockers = v end })
	local varOpts = { "None" }
	pcall(function()
		local V = require(ReplicatedStorage.Shared.Core.Storage.Game.VariantTokensLibrary)
		for k in pairs(V) do varOpts[#varOpts+1] = tostring(k) end
	end)
	gNU:CreateDropdown({ Name = "Variants", Options = varOpts, Value = "None",
		Callback = function(v) State.WhVariant = v end })
end
local gSt = tWeb:CreateGroupbox({ Name = "Stats" })
T(gSt, "Send Stats", "SendStats", "Envía un resumen (cash/candy/unidades) cada X minutos.")
Sl(gSt, "Every (minutes)", "StatsEvery", 1, 60, 1, "m")

-- ===== PLAYER  (copiado de Aster: Movement · Fly · Client) =====
local tPlayer = mkTab("Player", "user")
local gMove = tPlayer:CreateGroupbox({ Name = "Movement" })
T(gMove, "WalkSpeed", "WalkSpeedOn");  Sl(gMove, "Speed", "WalkSpeedAmt", 16, 200, 1)
T(gMove, "Infinite Jump", "InfJump")
T(gMove, "Noclip", "NoClip")
T(gMove, "Instant ProximityPrompt", "InstantPrompt")
local gFly = tPlayer:CreateGroupbox({ Name = "Fly" })
T(gFly, "Fly", "Fly");                Sl(gFly, "Fly Speed", "FlySpeed", 10, 200, 1)
local gCli = tPlayer:CreateGroupbox({ Name = "Client" })
T(gCli, "No Gameplay Paused", "AntiPause")
T(gCli, "Auto Reconnect on Kick", "AutoReconnect")
T(gCli, "Disable 3D Rendering", "Disable3D", "Deja de renderizar el mundo (FPS altísimos).")
T(gCli, "FPS Boost", "FpsBoost")
T(gCli, "Hide UI On Start", "HideUIOnStart", "Arranca con la ventana minimizada.")

-- ===== SETTINGS  (copiado de Aster: Menu + Themes/Configs nativos de Rayfield) =====
local tSet = mkTab("Settings", "settings")
local gMenu = tSet:CreateGroupbox({ Name = "Menu" })
gMenu:CreateKeybind({ Name = "Toggle UI", Value = State.ToggleUIKey or "K",
	Callback = function(k) State.ToggleUIKey = k; pcall(function() Window:SetKeybind(k) end) end })
pcall(function() Window:SetKeybind(State.ToggleUIKey) end)
gMenu:CreateDropdown({ Name = "Density", Options = { "Default", "Comfortable", "Compact" }, Value = State.Density or "Default",
	Callback = function(v) State.Density = v; pcall(function() Window:SetDensity(v) end) end })
do
	local bgs = { "None" }
	pcall(function() local l = Window:ListBackgrounds(); if type(l) == "table" then for _, b in ipairs(l) do bgs[#bgs+1] = tostring(b) end end end)
	gMenu:CreateDropdown({ Name = "Background", Options = bgs, Value = "None",
		Callback = function(v) State.Background = v; pcall(function() Window:SetBackground(v == "None" and "" or v) end) end })
end
gMenu:CreateSlider({ Name = "Background Opacity", Range = { 0, 100 }, Increment = 1, Value = State.BgOpacity, Suffix = "%",
	Callback = function(v) State.BgOpacity = v; pcall(function() Window:SetBackgroundTransparency(1 - v / 100) end) end })
T(gMenu, "Anti-AFK", "AntiAfk")
gMenu:CreateButton({
	Name = "Unload Nova",
	Callback = function()
		pcall(function()
			Window:Confirm({
				Title = "¿Descargar Nova?",
				Content = "Se detiene toda la automatización y se cierra la ventana.",
				Options = {
					{ Text = "Cerrar", Style = "danger", Callback = function()
						panic()
						pcall(function() Window:Notify({ Title = "Nova Hub", Content = "Cerrando…", Icon = "power" }) end)
						task.wait(0.3)
						pcall(function() Window:Destroy() end)
					end },
					{ Text = "Cancelar", Style = "neutral", Callback = function() end },
				},
			})
		end)
	end,
})
-- Themes y Configs: paneles NATIVOS de Rayfield (lo mismo que usa Aster: preset, color pickers, autoload, import/copy code)
pcall(function() tSet:CreateThemeManager() end)
pcall(function() tSet:CreateConfigManager() end)

-- reaplicar WalkSpeed / Fly al respawn
LocalPlayer.CharacterAdded:Connect(function()
	task.wait(0.5)
	applyWalkSpeed()
	if State.Fly then startFly() end
end)

if State.HideUIOnStart then pcall(function() Window:SetMinimized(true) end) end

pcall(function() Window:Notify({ Title = "Nova Hub", Content = "Cargado sobre Rayfield Gen2 ✓", Icon = "check" }) end)
print("[Nova Hub] cargado (Rayfield Gen2)")

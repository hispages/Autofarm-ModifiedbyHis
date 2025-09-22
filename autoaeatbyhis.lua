-- Auto-Eat Nearby Items (template gaya "99 Nights in the Forest")
-- Catatan: ini client-side template. Sesuaikan fungsi `consumeFood` dengan API game-mu sendiri.
-- Behavior: jika hunger >= THRESHOLD_PERCENT, script akan mencari item "makanan" di radius dan mencoba mengonsumsinya.

-- ========== CONFIG ==========
local THRESHOLD_PERCENT = 75      -- mulai makan saat hunger >= 75%
local SCAN_RADIUS = 30            -- radius (studs) untuk deteksi makanan di sekitar
local SCAN_INTERVAL = 0.5         -- detik antara scan
local CONSUME_COOLDOWN = 0.8      -- delay setelah mencoba mengonsumsi sebuah item
local MAX_CANDIDATES = 8         -- maksimal calon item yang diperiksa per scan

-- Nama/child yang sering dipakai gamedev untuk nutrisi -- bisa ubah sesuai gamemu
local NUTRITION_NAMES = { "Nutrition", "HungerRestore", "FoodValue", "Heal" }
local ISFOOD_NAMES = { "IsFood", "Edible", "CanEat" } -- BoolValue names
local TAG_NAMES = { "Food", "Edible", "Makanan" }     -- jika pakai CollectionService tagging

-- ========== SETUP ==========
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
if not player then return end

local function getCharacter()
    return player.Character or player.CharacterAdded:Wait()
end

local function getHumanoidRoot()
    local char = getCharacter()
    return char and (char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart)
end

-- ========== HELPERS ==========
local function safeGetNumberValue(inst, names)
    for _, n in ipairs(names) do
        local child = inst:FindFirstChild(n)
        if child and child:IsA("NumberValue") then
            return child.Value
        end
    end
    -- try attribute
    for _, n in ipairs(names) do
        local attr = inst:GetAttribute(n)
        if type(attr) == "number" then
            return attr
        end
    end
    return nil
end

local function safeGetBoolValue(inst, names)
    for _, n in ipairs(names) do
        local child = inst:FindFirstChild(n)
        if child and child:IsA("BoolValue") then
            return child.Value
        end
    end
    for _, n in ipairs(names) do
        local attr = inst:GetAttribute(n)
        if type(attr) == "boolean" then
            return attr
        end
    end
    return nil
end

local function isToolLike(inst)
    return inst:IsA("Tool")
end

local function getInstancePosition(inst)
    if inst:IsA("BasePart") then
        return inst.Position
    end
    if inst.PrimaryPart then
        return inst.PrimaryPart.Position
    end
    -- fallback: find any BasePart descendant
    for _, d in ipairs(inst:GetDescendants()) do
        if d:IsA("BasePart") then
            return d.Position
        end
    end
    return nil
end

local function magnitudeToPlayer(pos)
    local root = getHumanoidRoot()
    if not root or not pos then return math.huge end
    return (root.Position - pos).Magnitude
end

local function getHungerPercent()
    -- COUNTERPARTS: posssible locations for hunger value. Sesuaikan jika game-mu letak/huruf beda.
    -- 1) player.Hunger (NumberValue), with optional player.MaxHunger
    -- 2) player:FindFirstChild("HungerPercent") langsung (0-100)
    local hungerVal = nil
    local maxVal = nil

    local hv = player:FindFirstChild("Hunger") or player:FindFirstChild("Energy")
    if hv and hv:IsA("NumberValue") then
        hungerVal = hv.Value
        local mv = player:FindFirstChild("MaxHunger")
        if mv and mv:IsA("NumberValue") then
            maxVal = mv.Value
        end
    else
        local hp = player:FindFirstChild("HungerPercent") or player:FindFirstChild("HungerPct")
        if hp and hp:IsA("NumberValue") then
            return math.clamp(hp.Value, 0, 100)
        end
    end

    if not hungerVal then
        -- coba cek di leaderstats
        local ls = player:FindFirstChild("leaderstats")
        if ls then
            local hv2 = ls:FindFirstChild("Hunger") or ls:FindFirstChild("Energy")
            if hv2 and hv2:IsA("NumberValue") then
                hungerVal = hv2.Value
                local mv2 = ls:FindFirstChild("MaxHunger")
                if mv2 and mv2:IsA("NumberValue") then maxVal = mv2.Value end
            end
        end
    end

    if hungerVal then
        if not maxVal or maxVal <= 0 then maxVal = 100 end
        -- asumsi: hunger = 0 (kenyang) .. max = 100 (sangat lapar)
        -- kita kembalikan persen "berapa lapar" (0..100)
        local percent = (hungerVal / maxVal) * 100
        return math.clamp(percent, 0, 100)
    end

    -- fallback: tidak ketemu data hunger -> anggap 0 (tidak lapar)
    return 0
end

-- deteksi apakah instance merupakan makanan (banyak heuristik)
local function isFoodCandidate(inst)
    if not inst or not inst:IsDescendantOf(workspace) then return false end

    -- Tagged dengan CollectionService?
    for _, tag in ipairs(TAG_NAMES) do
        local ok, tagged = pcall(function() return CollectionService:GetTagged(tag) end)
        if ok and tagged then
            -- search if inst in that list (fast path)
            for _, t in ipairs(tagged) do
                if t == inst then return true end
            end
        end
    end

    -- punya atribut/child BoolValue yang menandakan makanan
    local b = safeGetBoolValue(inst, ISFOOD_NAMES)
    if b ~= nil then
        return b
    end

    -- punya child NumberValue nutrition
    local num = safeGetNumberValue(inst, NUTRITION_NAMES)
    if num ~= nil then
        return true
    end

    -- Tool yang punya nutrition atau dinamai "Food"/"Apple" dll
    if isToolLike(inst) then
        if safeGetNumberValue(inst, NUTRITION_NAMES) then return true end
        local nameLower = inst.Name:lower()
        if nameLower:find("food") or nameLower:find("apple") or nameLower:find("bread") or nameLower:find("meat") then
            return true
        end
    end

    -- Part/Model yang namanya mengindikasikan makanan
    local nm = inst.Name and inst.Name:lower() or ""
    if nm:find("food") or nm:find("apple") or nm:find("meat") or nm:find("bread") then
        return true
    end

    -- fallback false
    return false
end

-- Kumpulkan kandidat makanan di radius
local function findNearbyFoods(radius)
    local root = getHumanoidRoot()
    if not root then return {} end
    local rootPos = root.Position

    local candidates = {}

    -- 1) cek CollectionService tags dulu (fast)
    for _, tag in ipairs(TAG_NAMES) do
        local ok, tagged = pcall(function() return CollectionService:GetTagged(tag) end)
        if ok and tagged then
            for _, inst in ipairs(tagged) do
                if inst and inst:IsDescendantOf(workspace) and not inst:IsDescendantOf(player.Character) then
                    local pos = getInstancePosition(inst)
                    if pos and (pos - rootPos).Magnitude <= radius then
                        table.insert(candidates, inst)
                    end
                end
            end
        end
    end

    -- 2) fallback: scan workspace for likely food objects (heuristik)
    if #candidates < MAX_CANDIDATES then
        for _, inst in ipairs(workspace:GetDescendants()) do
            if #candidates >= MAX_CANDIDATES then break end
            if isFoodCandidate(inst) then
                -- ignore items that are inside player's backpack/character
                if inst:IsDescendantOf(player.Backpack) or inst:IsDescendantOf(player.Character) then
                    -- skip
                else
                    local pos = getInstancePosition(inst)
                    if pos then
                        local dist = (pos - rootPos).Magnitude
                        if dist <= radius then
                            table.insert(candidates, inst)
                        end
                    end
                end
            end
        end
    end

    -- deduplicate & sort by priority: prefer higher nutrition (if known) then closer
    local seen = {}
    local clean = {}
    for _, c in ipairs(candidates) do
        if c and not seen[c] then
            seen[c] = true
            table.insert(clean, c)
        end
    end

    table.sort(clean, function(a, b)
        local an = safeGetNumberValue(a, NUTRITION_NAMES) or 0
        local bn = safeGetNumberValue(b, NUTRITION_NAMES) or 0
        if an ~= bn then
            return an > bn -- lebih tinggi nutrition dulu
        end
        local ap = getInstancePosition(a)
        local bp = getInstancePosition(b)
        local ad = ap and (ap - rootPos).Magnitude or math.huge
        local bd = bp and (bp - rootPos).Magnitude or math.huge
        return ad < bd -- lebih dekat dulu
    end)

    return clean
end

-- ========== CONSUMPTION STRATEGIES ==========
-- Ubah/Melengkapi fungsi ini sesuai API server game-mu.
local lastTried = {} -- track item -> timestamp supaya ga spam coba terus

local function tryFireRemoteOnItem(item, remoteNames)
    for _, rn in ipairs(remoteNames) do
        local rem = ReplicatedStorage:FindFirstChild(rn) or item:FindFirstChild(rn)
        if rem and rem:IsA("RemoteEvent") then
            local ok, err = pcall(function()
                rem:FireServer(item)
            end)
            if ok then return true end
        end
    end
    return false
end

local function equipActivateTool(tool)
    if not tool or not tool.Parent then return false end
    local char = getCharacter()
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end

    local success, err = pcall(function()
        -- Pastikan tool ada di Backpack agar Humanoid bisa equip
        if tool.Parent ~= player.Backpack then
            tool.Parent = player.Backpack
            task.wait(0.05)
        end
        humanoid:EquipTool(tool)
        task.wait(0.08)
        -- try Activate (works for many client tools)
        if tool.Activate then
            tool:Activate()
        end
    end)
    return success
end

local function simpleConsume(item)
    -- 1) Jika item punya RemoteEvent "Eat"/"Use", coba FireServer
    local rvNames = { "Eat", "EatItem", "UseItem", "Consume", "RemoteEat", "FoodEat" }
    local ok = false
    for _, n in ipairs(rvNames) do
        local rem = ReplicatedStorage:FindFirstChild(n) or item:FindFirstChild(n)
        if rem and rem:IsA("RemoteEvent") then
            ok = pcall(function() rem:FireServer(item) end)
            if ok then return true end
        end
    end

    -- 2) Kalau item adalah Tool, coba equip & activate
    if isToolLike(item) then
        local suc = pcall(function() return equipActivateTool(item) end)
        if suc then return true end
    end

    -- 3) Kalau ada ProximityPrompt di item, coba trigger via :InputHoldBegin/End (client-side approach)
    for _, p in ipairs(item:GetDescendants()) do
        if p:IsA("ProximityPrompt") then
            local success = pcall(function()
                -- Trigger Prompt (beberapa game menerima client trigger)
                p:InputHoldBegin()
                task.wait(0.15)
                p:InputHoldEnd()
            end)
            if success then return true end
        end
    end

    -- 4) Jika ada RemoteEvent global khusus Interact/Use, coba:
    local globalUse = ReplicatedStorage:FindFirstChild("Interact") or ReplicatedStorage:FindFirstChild("Use")
    if globalUse and globalUse:IsA("RemoteEvent") then
        local suc = pcall(function() globalUse:FireServer(item) end)
        if suc then return true end
    end

    -- 5) fallback: jika ada function Consume di module server (tidak bisa di-call client)
    return false
end

local function consumeFood(item)
    if not item then return false end
    if lastTried[item] and (os.clock() - lastTried[item] < 1.0) then
        return false -- debounce
    end
    lastTried[item] = os.clock()

    local success, err = pcall(simpleConsume, item)
    if success and err ~= false then
        -- success likely true
        return true
    end
    return false
end

-- ========== MAIN LOOP ==========
spawn(function()
    while RunService:IsRunning() do
        task.wait(SCAN_INTERVAL)
        local hungerPct = getHungerPercent()
        if hungerPct >= THRESHOLD_PERCENT then
            local foods = findNearbyFoods(SCAN_RADIUS)
            if #foods == 0 then
                -- tidak ada makanan di sekitar
                -- print("AutoEat: tidak menemukan makanan di sekitar.")
            else
                -- coba konsumsi satu per satu sesuai prioritas
                for _, item in ipairs(foods) do
                    -- safety: pastikan item masih valid dan masih di workspace
                    if item and item.Parent and item:IsDescendantOf(workspace) then
                        local pos = getInstancePosition(item)
                        if pos and magnitudeToPlayer(pos) <= SCAN_RADIUS then
                            local ok = consumeFood(item)
                            if ok then
                                print(("[AutoEat] Mengonsumsi: %s (%.1f%% hunger)"):format(item:GetFullName(), hungerPct))
                                task.wait(CONSUME_COOLDOWN)
                                break -- hentikan loop kandidat dan tunggu scan berikutnya
                            else
                                -- gagal; lanjut ke kandidat berikutnya
                            end
                        end
                    end
                end
            end
        end
    end
end)

-- OPTIONAL: debug command (ketik di konsol atau hubungkan ke GUI untuk on/off)
-- Untuk mematikan, Anda bisa destroy script ini atau set THRESHOLD_PERCENT = 101

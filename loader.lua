local Services = setmetatable({}, { __index = function(t, k)
    local s = game:GetService(k)
    t[k] = s
    return s
end })

local Players           = Services.Players
local RunService        = Services.RunService
local UserInputService  = Services.UserInputService
local TweenService      = Services.TweenService
local Lighting          = Services.Lighting
local Workspace         = Services.Workspace
local GuiService        = Services.GuiService

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
    LocalPlayer = Players.LocalPlayer
end

local Camera = Workspace.CurrentCamera
Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    Camera = Workspace.CurrentCamera
end)

-- ============================================================
-- Rayfield loader
-- ============================================================
local Rayfield
do
    local ok, err = pcall(function()
        Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
    end)
    if not ok or not Rayfield then
        warn("[Melz] Rayfield load failed: " .. tostring(err))
        return
    end
end

local Window = Rayfield:CreateWindow({
    Name = "Melz Hub V1.1",
    LoadingTitle = "Melz Hub",
    LoadingSubtitle = "by Melz",
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "MelzHub",
        FileName = "MelzHubV1",
    },
    KeySystem = false,
})

-- ============================================================
-- State
-- ============================================================
local State = {
    aimlock = {
        enabled = false, fov = 120,
        color = Color3.fromRGB(255, 60, 60), size = 2,
        part = "Head", smoothing = 0.25, wallCheck = true,
    },
    silentAim = {
        enabled = false, fov = 150,
        color = Color3.fromRGB(60, 180, 255), size = 2,
        invisibleFov = true, part = "Head", wallCheck = false,
        prediction = 0,
    },
    esp = {
        enabled = false, name = true, box = true, skeleton = true,
        health = true, distance = true, teamCheck = false,
        color = Color3.fromRGB(80, 200, 255),
        textColor = Color3.fromRGB(255, 255, 255),
    },
    movement = {
        infiniteEnergy = false, walkSpeed = 16, defaultWalkSpeed = 16,
    },
    camera = {
        fov = 70, defaultFov = Camera and Camera.FieldOfView or 70,
        noRecoil = false, lockedCFrame = nil,
    },
    combat = {
        noSpread = false,
        rapidFire = { enabled = false, speed = 50 }, -- 0..100
        damageUp = { enabled = false, multiplier = 2 },
    },
    mentos = {
        enabled = false, interval = 1.0, toolNames = {"Mentos", "MentosCola"},
    },
    perf = {
        fpsBoost = false, fakeFps = false, fakeFpsValue = 240,
        savedLighting = nil, savedQuality = nil,
    },
}

-- ============================================================
-- Utility
-- ============================================================
local function isAlive(model)
    if not model or not model:IsA("Model") then return false end
    local hum = model:FindFirstChildOfClass("Humanoid")
    return hum ~= nil and hum.Health > 0
end

local function getChar(p) return p and p.Character end
local function getHRP(c) return c and c:FindFirstChild("HumanoidRootPart") end
local function getHumanoid(c) return c and c:FindFirstChildOfClass("Humanoid") end

local function isSameTeam(a, b)
    if not a or not b then return false end
    return a.Team ~= nil and b.Team ~= nil and a.Team == b.Team
end

local function worldToViewport(pos)
    if not Camera then return Vector2.new(), false, 0 end
    local sp, onScreen = Camera:WorldToViewportPoint(pos)
    return Vector2.new(sp.X, sp.Y), onScreen, sp.Z
end

local function hasLineOfSight(targetPart)
    if not targetPart or not Camera then return false end
    local origin = Camera.CFrame.Position
    local dir = targetPart.Position - origin
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local ignore = {}
    if LocalPlayer.Character then table.insert(ignore, LocalPlayer.Character) end
    params.FilterDescendantsInstances = ignore
    local result = Workspace:Raycast(origin, dir, params)
    if not result then return true end
    return result.Instance:IsDescendantOf(targetPart.Parent)
end

local function getTargetPart(character, partName)
    if not character then return nil end
    return character:FindFirstChild(partName)
        or character:FindFirstChild("Head")
        or character:FindFirstChild("HumanoidRootPart")
end

local function isAlly(player)
    return player == LocalPlayer or (player.Team ~= nil and player.Team == LocalPlayer.Team)
end

-- ============================================================
-- Aimlock
-- ============================================================
local AimlockFovCircle
local function ensureAimFovCircle()
    if AimlockFovCircle then return end
    local ok, circle = pcall(function() return Drawing.new("Circle") end)
    if ok and circle then
        circle.Thickness = State.aimlock.size
        circle.NumSides = 64
        circle.Radius = State.aimlock.fov
        circle.Filled = false
        circle.Transparency = 0.8
        circle.Color = State.aimlock.color
        circle.Visible = false
        AimlockFovCircle = circle
    end
end

local function updateAimFovCircle()
    ensureAimFovCircle()
    if not AimlockFovCircle then return end
    AimlockFovCircle.Visible = State.aimlock.enabled and State.aimlock.fov > 0
    AimlockFovCircle.Radius = State.aimlock.fov
    AimlockFovCircle.Thickness = State.aimlock.size
    AimlockFovCircle.Color = State.aimlock.color
    if Camera then
        AimlockFovCircle.Position = Vector2.new(
            Camera.ViewportSize.X / 2,
            Camera.ViewportSize.Y / 2
        )
    end
end

local function findNearestPlayer(fovRadius, partName, wallCheck, teamCheck)
    if not Camera then return nil end
    local center = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    local best, bestDist = nil, fovRadius
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and isAlive(player.Character) then
            if not (teamCheck and isAlly(player)) then
                local part = getTargetPart(player.Character, partName)
                if part then
                    local screen, onScreen = worldToViewport(part.Position)
                    if onScreen then
                        local d = (screen - center).Magnitude
                        if d < bestDist then
                            if (not wallCheck) or hasLineOfSight(part) then
                                best, bestDist = { player = player, part = part }, d
                            end
                        end
                    end
                end
            end
        end
    end
    return best
end

local aimConnection
local function startAimlock()
    if aimConnection then aimConnection:Disconnect(); aimConnection = nil end
    aimConnection = RunService.RenderStepped:Connect(function()
        updateAimFovCircle()
        if not State.aimlock.enabled or not Camera then return end
        local target = findNearestPlayer(
            State.aimlock.fov, State.aimlock.part,
            State.aimlock.wallCheck, true
        )
        if target then
            local goal = CFrame.new(Camera.CFrame.Position, target.part.Position)
            local smooth = math.clamp(State.aimlock.smoothing, 0.01, 1)
            Camera.CFrame = Camera.CFrame:Lerp(goal, smooth)
        end
    end)
end
startAimlock()

-- ============================================================
-- Silent Aim  (FIX — rewrite remote arguments)
-- ============================================================
-- Pendekatan: hook __namecall. Untuk setiap panggilan FireServer/InvokeServer,
-- deteksi signature yang mengandung (origin CF, direction Vector3) dan/atau
-- argumen Vector3 yang merepresentasikan posisi hit. Jika silent aim aktif dan
-- ada target di FOV circle, ganti direction agar mengarah ke target part.
-- Kamera lokal tidak disentuh — user tetap melihat bidiknya sendiri.
--
-- Deteksi heuristik:
--   - origin: argumen bertipe CFrame (spawn), atau .Position dari Vector3 di
--             indeks awal
--   - direction: argumen Vector3 dengan Magnitude antara 0.001 dan 5000
--   - endpoint: argumen Vector3 kedua setelah direction (posisi hit)
-- Keduanya di-rewrite. Jika hanya satu yang ada, sisanya dibiarkan.
--
-- Wall check menghormati State.silentAim.wallCheck.

local silentState = {
    targetPart = nil,
    lastTargetPlayer = nil,
}

local SilentFovCircle
local function ensureSilentFovCircle()
    if SilentFovCircle then return end
    local ok, circle = pcall(function() return Drawing.new("Circle") end)
    if ok and circle then
        circle.Thickness = State.silentAim.size
        circle.NumSides = 64
        circle.Radius = State.silentAim.fov
        circle.Filled = false
        circle.Transparency = State.silentAim.invisibleFov and 0.001 or 0.6
        circle.Color = State.silentAim.color
        circle.Visible = false
        SilentFovCircle = circle
    end
end

local function updateSilentFovCircle()
    ensureSilentFovCircle()
    if not SilentFovCircle then return end
    SilentFovCircle.Visible = State.silentAim.enabled and State.silentAim.fov > 0
    SilentFovCircle.Radius = State.silentAim.fov
    SilentFovCircle.Thickness = State.silentAim.size
    SilentFovCircle.Color = State.silentAim.color
    SilentFovCircle.Transparency = State.silentAim.invisibleFov and 0.001 or 0.6
    if Camera then
        SilentFovCircle.Position = Vector2.new(
            Camera.ViewportSize.X / 2,
            Camera.ViewportSize.Y / 2
        )
    end
end

local silentConnection = RunService.RenderStepped:Connect(function()
    updateSilentFovCircle()
    if not State.silentAim.enabled then
        silentState.targetPart = nil
        silentState.lastTargetPlayer = nil
        return
    end
    local target = findNearestPlayer(
        State.silentAim.fov, State.silentAim.part,
        State.silentAim.wallCheck, true
    )
    if target then
        silentState.targetPart = target.part
        silentState.lastTargetPlayer = target.player
    else
        silentState.targetPart = nil
        silentState.lastTargetPlayer = nil
    end
end)

-- Prediksi posisi target (lead shot) — offset berdasarkan velocity part.
-- prediction = detik lead (0 = tidak prediksi). HumanoidRootPart.AssemblyLinearVelocity
-- jika ada.
local function predictPosition(part, leadTime)
    if not part or leadTime <= 0 then return part and part.Position or nil end
    local ok, vel = pcall(function()
        return part.AssemblyLinearVelocity
    end)
    if not ok or not vel then return part.Position end
    return part.Position + vel * leadTime
end

-- Cek apakah vector berisi nilai plausibel sebagai direction (0.001..5000)
local function looksLikeDirection(v)
    if typeof(v) ~= "Vector3" then return false end
    local m = v.Magnitude
    return m > 0.001 and m < 5000
end

-- Cek apakah vector plausibel sebagai origin/posisi dunia (di dalam workspace bounds)
local function looksLikeOrigin(v)
    if typeof(v) ~= "Vector3" then return false end
    local m = v.Magnitude
    return m > 0.01 and m < 100000
end

-- Apply silent aim ke daftar argumen. Mengembalikan argumen baru + apakah berubah.
-- Mencari pasangan (origin, direction) atau (originCFrame, direction) atau
-- direction tunggal, dan rewrite ke target.
local function applySilentAimToArgs(args, originHint)
    if not silentState.targetPart or not silentState.targetPart.Parent then
        return args, false
    end
    local targetPos = predictPosition(silentState.targetPart, State.silentAim.prediction)
    if not targetPos then return args, false end

    -- Origin: pakai Camera.CFrame.Position sebagai default, atau argumen CFrame
    -- pertama jika ada.
    local originPos = originHint or Camera and Camera.CFrame.Position or Vector3.zero
    local originIdx, dirIdx
    -- Pass 1: cari pasangan posisi + direction berurutan
    for i = 1, #args do
        if typeof(args[i]) == "CFrame" then
            originPos = args[i].Position
            originIdx = i
            -- direction biasanya setelah CFrame, bisa Vector3 atau Vector3 lain
            for j = i + 1, math.min(i + 3, #args) do
                if looksLikeDirection(args[j]) then
                    dirIdx = j
                    break
                end
            end
            if dirIdx then break end
        end
    end
    -- Pass 2: origin Vector3 + direction Vector3
    if not dirIdx then
        for i = 1, #args - 1 do
            if looksLikeOrigin(args[i]) and looksLikeDirection(args[i + 1]) then
                originPos = args[i]
                originIdx = i
                dirIdx = i + 1
                break
            end
        end
    end
    -- Pass 3: hanya direction (origin dari camera)
    if not dirIdx then
        for i = 1, #args do
            if looksLikeDirection(args[i]) then
                dirIdx = i
                originIdx = nil
                break
            end
        end
    end

    if not dirIdx then return args, false end

    -- Rewrite direction
    local direction = targetPos - originPos
    if direction.Magnitude < 0.001 then return args, false end
    local newArgs = table.clone and table.clone(args) or {}
    if not table.clone then
        for i = 1, #args do newArgs[i] = args[i] end
    end
    newArgs[dirIdx] = direction

    -- Jika ada argumen endpoint (posisi hit), rewrite juga
    for i = dirIdx + 1, math.min(dirIdx + 2, #args) do
        if typeof(args[i]) == "Vector3" and looksLikeOrigin(args[i]) then
            newArgs[i] = targetPos
            break
        end
    end
    return newArgs, true
end

-- No spread: normalisasi direction agar tidak ada random offset.
-- Heuristik: jika direction diberi perturbation kecil (< 5% magnitude),
-- kita tidak bisa bedain dari direction asli tanpa tahu seed. Namun kita bisa
-- memaksa direction hasil silent aim menjadi unit vector yang deterministik,
-- dan untuk weapons yang menggunakan dua argumen direction, kita samakan
-- magnitude kedua argumen agar tidak ada spread cone.
local function applyNoSpread(args)
    if not State.combat.noSpread then return args, false end
    local dirIdxs = {}
    for i = 1, #args do
        if typeof(args[i]) == "Vector3" and looksLikeDirection(args[i]) then
            table.insert(dirIdxs, i)
        end
    end
    if #dirIdxs < 1 then return args, false end
    local newArgs = {}
    for i = 1, #args do newArgs[i] = args[i] end
    -- Kumpulkan semua direction, ambil rata-rata arah, proyeksikan semua ke arah itu
    local sum = Vector3.zero
    for _, idx in ipairs(dirIdxs) do sum = sum + args[idx].Unit end
    local avg = sum.Unit
    if avg.Magnitude < 0.001 then return args, false end
    for _, idx in ipairs(dirIdxs) do
        newArgs[idx] = avg * args[idx].Magnitude
    end
    return newArgs, true
end

-- Damage up: kalikan argumen numerik yang plausibel sebagai damage.
-- Heuristik: integer > 0 dan < 100000, berada setelah direction/endpoint,
-- bukan waktu/tick/seed (kita batasi range 1..10000 untuk hindari tick).
local function applyDamageUp(args)
    if not State.combat.damageUp.enabled then return args, false end
    local mult = State.combat.damageUp.multiplier
    local newArgs = {}
    for i = 1, #args do newArgs[i] = args[i] end
    local changed = false
    -- Cari index direction pertama sebagai anchor
    local anchor = 0
    for i = 1, #args do
        if typeof(args[i]) == "Vector3" and looksLikeDirection(args[i]) then
            anchor = i
        end
    end
    for i = math.max(anchor + 1, 1), #args do
        local v = args[i]
        if type(v) == "number" and v > 0 and v < 10000 and v == math.floor(v) then
            -- skip jika di range waktu (16..17, 60..61) — heuristic lemah,
            -- tapi anchor sudah memastikan kita hanya lihat argumen setelah direction
            newArgs[i] = v * mult
            changed = true
        end
    end
    return newArgs, changed
end

-- Rapidfire: throttle FireServer. speed 0 = mati, 100 = secepat mungkin.
-- Kita tidak memodifikasi RemoteEvent internal — kita hanya disable click debounce
-- dan tool cooldown dengan set tool.Enabled = true berulang kali saat heartbeat,
-- dan jika user menembak, kita panggil FireServer berulang pada remote yang sama.
local rapidFireState = {
    lastFireTime = 0,
    lastRemote = nil,
    lastArgs = nil,
    tool = nil,
}

local function getEquippedTool()
    local char = LocalPlayer.Character
    if not char then return nil end
    return char:FindFirstChildOfClass("Tool")
end

local function applyRapidFireTick()
    if not State.combat.rapidFire.enabled then return end
    local tool = getEquippedTool()
    if not tool then return end
    local ok = pcall(function()
        if tool.Enabled == false then tool.Enabled = true end
    end)
    if not ok then return end
    -- Beberapa game menggunakan Value "Cooldown" / "FireRate" di tool
    for _, child in ipairs(tool:GetChildren()) do
        if child:IsA("NumberValue") then
            local n = child.Name:lower()
            if n:find("cooldown") or n:find("firerate") or n:find("delay") then
                pcall(function() child.Value = 0 end)
            end
        end
    end
end

RunService.Heartbeat:Connect(applyRapidFireTick)

-- ============================================================
-- __namecall hook — satu pintu untuk silent aim + no spread + damage up
-- ============================================================
local oldNamecall
local hookInstalled = false

local function shouldProcessRemote(self, method)
    if method ~= "FireServer" and method ~= "InvokeServer" then return false end
    -- self harus Instance, dan RemoteEvent/RemoteFunction/UnreliableRemoteEvent
    if typeof(self) ~= "Instance" then return false end
    local cn = self.ClassName
    if cn ~= "RemoteEvent" and cn ~= "RemoteFunction"
        and cn ~= "UnreliableRemoteEvent" and cn ~= "BindableEvent" then
        return false
    end
    return true
end

local function installNamecallHook()
    if hookInstalled then return end
    local mt = getrawmetatable(game)
    if not mt then return end
    setreadonly(mt, false)
    oldNamecall = mt.__namecall
    mt.__namecall = newcclosure(function(self, ...)
        local method = getnamecallmethod()
        if shouldProcessRemote(self, method) then
            local args = {...}
            local changed = false

            if State.silentAim.enabled and silentState.targetPart then
                local newArgs, didChange = applySilentAimToArgs(args)
                if didChange then args = newArgs; changed = true end
            end
            if State.combat.noSpread then
                local newArgs, didChange = applyNoSpread(args)
                if didChange then args = newArgs; changed = true end
            end
            if State.combat.damageUp.enabled then
                local newArgs, didChange = applyDamageUp(args)
                if didChange then args = newArgs; changed = true end
            end

            -- Rapidfire: panggil remote berulang sesuai speed
            if State.combat.rapidFire.enabled and State.combat.rapidFire.speed > 0 then
                local s = State.combat.rapidFire.speed
                -- speed 0 = sekali, 100 = ~30x per detik. Mapping linear:
                local repeats = math.floor(1 + (s / 100) * 4) -- 1..5
                for _ = 2, repeats do
                    task.spawn(function()
                        pcall(function() oldNamecall(self, table.unpack(args)) end)
                    end)
                end
            end

            if changed then
                return oldNamecall(self, table.unpack(args))
            end
        end
        return oldNamecall(self, ...)
    end)
    setreadonly(mt, true)
    hookInstalled = true
end
installNamecallHook()

-- ============================================================
-- No Recoil — lock Camera.CFrame tiap RenderStepped
-- ============================================================
-- Recoil Roblox biasanya: kamera di-rotate lokal setelah FireServer, atau
-- script game set Camera.CFrame. Kita tidak bisa cegah set CFrame, tapi kita
-- bisa restore setiap frame ke CFrame yang sudah di-capture. Focus pada rotasi
-- (pitch/yaw) agar player masih bisa free look: kita hanya lock orientasi saat
-- tombol fire ditekan + 0.25s setelahnya.
local recoilLock = {
    active = false,
    baseCF = nil,
    baseRot = nil,
    untilTime = 0,
}

local function onFireInputStart()
    if not State.camera.noRecoil or not Camera then return end
    recoilLock.active = true
    recoilLock.baseCF = Camera.CFrame
    recoilLock.baseRot = Camera.CFrame.Rotation
    recoilLock.untilTime = os.clock() + 0.35
end

local function onFireInputStop()
    -- biarkan release
end

UserInputService.InputBegan:Connect(function(input, gp)
    if gp then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.KeyCode == Enum.KeyCode.ButtonR2 then
        onFireInputStart()
    end
end)

UserInputService.InputEnded:Connect(function(input, gp)
    if gp then return end
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.KeyCode == Enum.KeyCode.ButtonR2 then
        onFireInputStop()
    end
end)

RunService.RenderStepped:Connect(function()
    if not State.camera.noRecoil then
        recoilLock.active = false
        recoilLock.baseCF = nil
        return
    end
    if not recoilLock.active or not recoilLock.baseCF or not Camera then return end
    if os.clock() > recoilLock.untilTime then
        recoilLock.active = false
        return
    end
    -- Preserve posisi + rotasi kamera saat ini (biar free look), tapi clamp
    -- tambahan rotasi (pitch/yaw) yang diinduksi recoil setelah FireServer.
    local current = Camera.CFrame
    -- Recoil manifests as rotation offset; kita lerp balik ke baseRot
    local basePos = recoilLock.baseCF.Position
    local targetCF = CFrame.new(basePos) * recoilLock.baseRot
    -- Blend: cepat tapi tidak instan, biar tidak terlihat snap
    Camera.CFrame = current:Lerp(targetCF, 0.85)
end)

-- ============================================================
-- ESP
-- ============================================================
local ESPObjects = {}

local function clearESPFor(player)
    local obj = ESPObjects[player]
    if not obj then return end
    for _, d in pairs(obj) do
        if typeof(d) == "Instance" then
            pcall(function() d:Destroy() end)
        else
            pcall(function() d:Remove() end)
        end
    end
    ESPObjects[player] = nil
end

local function clearAllESP()
    for player in pairs(ESPObjects) do clearESPFor(player) end
end

local function newDrawing(kind)
    local ok, d = pcall(function() return Drawing.new(kind) end)
    if ok then return d end
    return nil
end

local function buildESPFor(player)
    if ESPObjects[player] then return end
    local obj = {}
    obj.box = newDrawing("Square")
    obj.name = newDrawing("Text")
    obj.health = newDrawing("Line")
    obj.distance = newDrawing("Text")
    obj.skeleton = {}
    for i = 1, 6 do obj.skeleton[i] = newDrawing("Line") end
    if obj.name then
        obj.name.Center = true; obj.name.Outline = true; obj.name.Size = 14
    end
    if obj.distance then
        obj.distance.Center = true; obj.distance.Outline = true; obj.distance.Size = 12
    end
    if obj.box then obj.box.Thickness = 1; obj.box.Filled = false end
    if obj.health then obj.health.Thickness = 2 end
    for i = 1, 6 do
        if obj.skeleton[i] then obj.skeleton[i].Thickness = 1 end
    end
    ESPObjects[player] = obj
end

local skeletonBones = {
    {"Head", "UpperTorso"},
    {"UpperTorso", "LowerTorso"},
    {"UpperTorso", "LeftUpperArm"},
    {"LeftUpperArm", "LeftLowerArm"},
    {"LeftLowerArm", "LeftHand"},
    {"UpperTorso", "RightUpperArm"},
}

local function updateESP()
    if not State.esp.enabled then
        clearAllESP()
        return
    end
    local seen = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and isAlive(player.Character) then
            local char = player.Character
            local hum = getHumanoid(char)
            local hrp = getHRP(char)
            if hum and hrp then
                if State.esp.teamCheck and isSameTeam(LocalPlayer, player) then
                    if ESPObjects[player] then clearESPFor(player) end
                else
                    seen[player] = true
                    buildESPFor(player)
                    local obj = ESPObjects[player]
                    if obj then
                        local head = char:FindFirstChild("Head")
                        local rootPos = hrp.Position
                        local headPos = head and head.Position or (rootPos + Vector3.new(0, 2, 0))
                        local topScreen, topOn = worldToViewport(headPos)
                        local botScreen, botOn = worldToViewport(rootPos - Vector3.new(0, 3, 0))
                        if topOn and botOn and topScreen.Y < botScreen.Y then
                            local h = botScreen.Y - topScreen.Y
                            local w = h * 0.55
                            local centerX = (topScreen.X + botScreen.X) / 2
                            if obj.box then
                                obj.box.Size = Vector2.new(w, h)
                                obj.box.Position = Vector2.new(centerX - w / 2, topScreen.Y)
                                obj.box.Color = State.esp.color
                                obj.box.Visible = State.esp.box
                            end
                            if obj.name then
                                obj.name.Text = player.Name
                                obj.name.Position = Vector2.new(centerX, topScreen.Y - 16)
                                obj.name.Color = State.esp.textColor
                                obj.name.Visible = State.esp.name
                            end
                            if obj.distance then
                                local dist = (Camera.CFrame.Position - rootPos).Magnitude
                                obj.distance.Text = string.format("[%d]", math.floor(dist))
                                obj.distance.Position = Vector2.new(centerX, botScreen.Y + 2)
                                obj.distance.Color = State.esp.textColor
                                obj.distance.Visible = State.esp.distance
                            end
                            if obj.health then
                                local hp = hum.Health / math.max(hum.MaxHealth, 1)
                                local barH = h * hp
                                obj.health.From = Vector2.new(topScreen.X - w / 2 - 4, botScreen.Y - barH)
                                obj.health.To = Vector2.new(topScreen.X - w / 2 - 4, botScreen.Y)
                                obj.health.Color = Color3.fromRGB(
                                    255 - math.floor(255 * hp),
                                    math.floor(255 * hp),
                                    40
                                )
                                obj.health.Visible = State.esp.health
                            end
                            if State.esp.skeleton then
                                for i, pair in ipairs(skeletonBones) do
                                    local a = char:FindFirstChild(pair[1])
                                    local b = char:FindFirstChild(pair[2])
                                    local line = obj.skeleton[i]
                                    if a and b and line then
                                        local pa, onA = worldToViewport(a.Position)
                                        local pb, onB = worldToViewport(b.Position)
                                        if onA and onB then
                                            line.From = pa; line.To = pb
                                            line.Color = State.esp.color
                                            line.Visible = true
                                        else
                                            line.Visible = false
                                        end
                                    elseif line then
                                        line.Visible = false
                                    end
                                end
                            else
                                for i = 1, #obj.skeleton do
                                    if obj.skeleton[i] then obj.skeleton[i].Visible = false end
                                end
                            end
                        else
                            if obj.box then obj.box.Visible = false end
                            if obj.name then obj.name.Visible = false end
                            if obj.distance then obj.distance.Visible = false end
                            if obj.health then obj.health.Visible = false end
                            for i = 1, #obj.skeleton do
                                if obj.skeleton[i] then obj.skeleton[i].Visible = false end
                            end
                        end
                    end
                end
            else
                if ESPObjects[player] then clearESPFor(player) end
            end
        elseif ESPObjects[player] then
            clearESPFor(player)
        end
    end
    for player in pairs(ESPObjects) do
        if not seen[player] then clearESPFor(player) end
    end
end

RunService.RenderStepped:Connect(updateESP)
Players.PlayerRemoving:Connect(function(p) clearESPFor(p) end)

-- ============================================================
-- Mentos Makro
-- ============================================================
-- Auto-consume item "Mentos". Dua jalur:
--   1. Tool di backpack bernama Mentos/MentosCola -> equip -> Activate -> unequip
--   2. RemoteEvent bernama UseItem/ConsumeItem/UseInventory -> FireServer("Mentos")
local mentosConnection
local function tryUseMentos()
    local char = LocalPlayer.Character
    if not char then return end
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local candidates = {}
    for _, name in ipairs(State.mentos.toolNames) do
        local t = char:FindFirstChild(name) or (backpack and backpack:FindFirstChild(name))
        if t then table.insert(candidates, t) end
    end
    for _, tool in ipairs(candidates) do
        local hum = getHumanoid(char)
        if hum then
            local originalParent = tool.Parent
            pcall(function()
                tool.Parent = char
                hum:EquipTool(tool)
            end)
            task.wait(0.15)
            pcall(function() tool:Activate() end)
            task.wait(0.05)
            pcall(function()
                hum:UnequipTools()
                if originalParent then tool.Parent = originalParent end
            end)
        end
    end
    -- Remote jalur
    local remotes = {}
    for _, d in ipairs(game:GetDescendants()) do
        if d:IsA("RemoteEvent") or d:IsA("RemoteFunction") then
            local n = d.Name:lower()
            if n:find("useitem") or n:find("consume") or n:find("useinventory")
                or n:find("use_mentos") then
                table.insert(remotes, d)
            end
        end
    end
    for _, r in ipairs(remotes) do
        pcall(function()
            if r:IsA("RemoteEvent") then
                r:FireServer("Mentos")
            else
                r:InvokeServer("Mentos")
            end
        end)
    end
end

local function startMentosLoop()
    if mentosConnection then mentosConnection:Disconnect(); mentosConnection = nil end
    if not State.mentos.enabled then return end
    mentosConnection = task.spawn(function()
        while State.mentos.enabled do
            pcall(tryUseMentos)
            task.wait(State.mentos.interval)
        end
    end)
end

-- ============================================================
-- FPS Boost
-- ============================================================
local fpsBoostState = {
    savedLighting = nil,
    savedQuality = nil,
    hiddenParticles = {},
}

local function enableFpsBoost()
    if not fpsBoostState.savedLighting then
        fpsBoostState.savedLighting = {
            GlobalShadows = Lighting.GlobalShadows,
            ShadowSoftness = Lighting.ShadowSoftness,
            Brightness = Lighting.Brightness,
            Ambient = Lighting.Ambient,
            OutdoorAmbient = Lighting.OutdoorAmbient,
            FogEnd = Lighting.FogEnd,
            QualityLevel = Lighting.QualityLevel or nil,
        }
    end
    pcall(function()
        Lighting.GlobalShadows = false
        Lighting.ShadowSoftness = 0
        Lighting.FogEnd = 100000
        Lighting.Brightness = 1
        Lighting.Ambient = Color3.fromRGB(128,128,128)
        Lighting.OutdoorAmbient = Color3.fromRGB(128,128,128)
    end)
    pcall(function()
        settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
    end)
    pcall(function()
        for _, d in ipairs(Workspace:GetDescendants()) do
            if d:IsA("ParticleEmitter") and d.Enabled then
                fpsBoostState.hiddenParticles[d] = true
                d.Enabled = false
            elseif d:IsA("Trail") and d.Enabled then
                fpsBoostState.hiddenParticles[d] = true
                d.Enabled = false
            elseif d:IsA("Smoke") and d.Enabled then
                fpsBoostState.hiddenParticles[d] = true
                d.Enabled = false
            elseif d:IsA("Fire") and d.Enabled then
                fpsBoostState.hiddenParticles[d] = true
                d.Enabled = false
            elseif d:IsA("Sparkles") and d.Enabled then
                fpsBoostState.hiddenParticles[d] = true
                d.Enabled = false
            end
        end
    end)
    -- Post-processing effects di Lighting
    for _, child in ipairs(Lighting:GetChildren()) do
        if child:IsA("BlurEffect") or child:IsA("BloomEffect")
            or child:IsA("SunRaysEffect") or child:IsA("ColorCorrectionEffect")
            or child:IsA("DepthOfFieldEffect") then
            if child.Enabled then
                fpsBoostState.hiddenParticles[child] = true
                pcall(function() child.Enabled = false end)
            end
        end
    end
end

local function disableFpsBoost()
    if fpsBoostState.savedLighting then
        local s = fpsBoostState.savedLighting
        pcall(function()
            Lighting.GlobalShadows = s.GlobalShadows
            Lighting.ShadowSoftness = s.ShadowSoftness
            Lighting.Brightness = s.Brightness
            Lighting.Ambient = s.Ambient
            Lighting.OutdoorAmbient = s.OutdoorAmbient
            Lighting.FogEnd = s.FogEnd
        end)
        fpsBoostState.savedLighting = nil
    end
    pcall(function()
        settings().Rendering.QualityLevel = Enum.QualityLevel.Level07
    end)
    for obj in pairs(fpsBoostState.hiddenParticles) do
        pcall(function()
            if obj.Parent then obj.Enabled = true end
        end)
    end
    fpsBoostState.hiddenParticles = {}
end

-- ============================================================
-- Fake FPS Overlay
-- ============================================================
local FakeFpsGui
local function buildFakeFpsGui()
    if FakeFpsGui then return end
    local ok, gui = pcall(function()
        local sg = Instance.new("ScreenGui")
        sg.Name = "MelzFakeFps"
        sg.ResetOnSpawn = false
        sg.IgnoreGuiInset = true
        sg.DisplayOrder = 999999
        sg.Parent = game:GetService("CoreGui")
        local label = Instance.new("TextLabel")
        label.Name = "FpsLabel"
        label.BackgroundTransparency = 1
        label.Position = UDim2.new(0, 8, 0, 8)
        label.Size = UDim2.new(0, 160, 0, 22)
        label.Font = Enum.Font.Code
        label.TextSize = 18
        label.TextColor3 = Color3.fromRGB(120, 255, 120)
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextStrokeTransparency = 0.6
        label.Text = "FPS: " .. State.perf.fakeFpsValue
        label.Parent = sg
        return { gui = sg, label = label }
    end)
    if ok then FakeFpsGui = gui end
end

local function updateFakeFps()
    if not State.perf.fakeFps then
        if FakeFpsGui then
            pcall(function() FakeFpsGui.gui:Destroy() end)
            FakeFpsGui = nil
        end
        return
    end
    buildFakeFpsGui()
    if FakeFpsGui then
        FakeFpsGui.label.Text = "FPS: " .. tostring(State.perf.fakeFpsValue)
    end
end

-- ============================================================
-- Movement / Camera helpers
-- ============================================================
local energyConnection
local function applyInfiniteEnergy()
    local char = getChar(LocalPlayer)
    if not char then return end
    local hum = getHumanoid(char)
    if not hum then return end
    local roots = { char, LocalPlayer, LocalPlayer:FindFirstChild("PlayerGui") }
    for _, root in ipairs(roots) do
        if root then
            for _, child in ipairs(root:GetDescendants()) do
                if child:IsA("NumberValue") or child:IsA("IntValue") then
                    local n = child.Name:lower()
                    if n:find("energy") or n:find("stamina") or n:find("sprint") then
                        pcall(function()
                            if child:IsA("NumberValue") then child.Value = 1e9
                            else child.Value = math.huge end
                        end)
                    end
                end
            end
        end
    end
    if State.movement.infiniteEnergy then
        hum.WalkSpeed = math.max(hum.WalkSpeed, State.movement.walkSpeed)
    end
end

local function startEnergyLoop()
    if energyConnection then energyConnection:Disconnect(); energyConnection = nil end
    if not State.movement.infiniteEnergy then return end
    energyConnection = RunService.Heartbeat:Connect(function()
        if not State.movement.infiniteEnergy then return end
        local char = getChar(LocalPlayer)
        local hum = getHumanoid(char)
        if hum then
            pcall(function() hum.Health = hum.MaxHealth end)
            pcall(function() hum.JumpPower = 100; hum.UseJumpPower = true end)
        end
        applyInfiniteEnergy()
    end)
end

local function applyWalkSpeed(speed)
    State.movement.walkSpeed = speed
    local hum = getHumanoid(getChar(LocalPlayer))
    if hum then pcall(function() hum.WalkSpeed = speed end) end
end

local function applyCameraFov(fov)
    State.camera.fov = fov
    if Camera then pcall(function() Camera.FieldOfView = fov end) end
end

LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.4)
    applyWalkSpeed(State.movement.walkSpeed)
    applyCameraFov(State.camera.fov)
    if State.movement.infiniteEnergy then startEnergyLoop() end
end)

-- ============================================================
-- UI
-- ============================================================
local AimTab = Window:CreateTab("Aimlock", 4483362458)
AimTab:CreateSection("Aimlock")
AimTab:CreateToggle({
    Name = "Aimlock", CurrentValue = false, Flag = "aimlock_enabled",
    Callback = function(v) State.aimlock.enabled = v end,
})
AimTab:CreateSlider({
    Name = "FOV Radius", Range = {0, 800}, Increment = 1, Suffix = "px",
    CurrentValue = State.aimlock.fov, Flag = "aimlock_fov",
    Callback = function(v) State.aimlock.fov = v end,
})
AimTab:CreateSlider({
    Name = "FOV Thickness", Range = {1, 8}, Increment = 1,
    CurrentValue = State.aimlock.size, Flag = "aimlock_size",
    Callback = function(v) State.aimlock.size = v end,
})
AimTab:CreateColorPicker({
    Name = "FOV Color", Color = State.aimlock.color, Flag = "aimlock_color",
    Callback = function(c) State.aimlock.color = c end,
})
AimTab:CreateDropdown({
    Name = "Aim Part", Options = {"Head", "HumanoidRootPart", "UpperTorso"},
    CurrentOption = {"Head"}, MultipleOptions = false, Flag = "aimlock_part",
    Callback = function(opt) State.aimlock.part = type(opt) == "table" and opt[1] or opt end,
})
AimTab:CreateSlider({
    Name = "Smoothing", Range = {1, 100}, Increment = 1, Suffix = "%",
    CurrentValue = math.floor(State.aimlock.smoothing * 100), Flag = "aimlock_smooth",
    Callback = function(v) State.aimlock.smoothing = v / 100 end,
})
AimTab:CreateToggle({
    Name = "Wall Check", CurrentValue = true, Flag = "aimlock_wall",
    Callback = function(v) State.aimlock.wallCheck = v end,
})

local SilentTab = Window:CreateTab("Silent Aim", 4483362458)
SilentTab:CreateSection("Silent Aim (FIX)")
SilentTab:CreateToggle({
    Name = "Silent Aim", CurrentValue = false, Flag = "silent_enabled",
    Callback = function(v) State.silentAim.enabled = v end,
})
SilentTab:CreateSlider({
    Name = "FOV Radius", Range = {0, 800}, Increment = 1, Suffix = "px",
    CurrentValue = State.silentAim.fov, Flag = "silent_fov",
    Callback = function(v) State.silentAim.fov = v end,
})
SilentTab:CreateSlider({
    Name = "FOV Thickness", Range = {1, 8}, Increment = 1,
    CurrentValue = State.silentAim.size, Flag = "silent_size",
    Callback = function(v) State.silentAim.size = v end,
})
SilentTab:CreateColorPicker({
    Name = "FOV Color", Color = State.silentAim.color, Flag = "silent_color",
    Callback = function(c) State.silentAim.color = c end,
})
SilentTab:CreateToggle({
    Name = "Invisible FOV", CurrentValue = true, Flag = "silent_invis",
    Callback = function(v) State.silentAim.invisibleFov = v end,
})
SilentTab:CreateDropdown({
    Name = "Hit Part", Options = {"Head", "HumanoidRootPart", "UpperTorso"},
    CurrentOption = {"Head"}, MultipleOptions = false, Flag = "silent_part",
    Callback = function(opt) State.silentAim.part = type(opt) == "table" and opt[1] or opt end,
})
SilentTab:CreateToggle({
    Name = "Wall Check", CurrentValue = false, Flag = "silent_wall",
    Callback = function(v) State.silentAim.wallCheck = v end,
})
SilentTab:CreateSlider({
    Name = "Prediction (lead)", Range = {0, 100}, Increment = 1, Suffix = "ms",
    CurrentValue = math.floor(State.silentAim.prediction * 1000), Flag = "silent_pred",
    Callback = function(v) State.silentAim.prediction = v / 1000 end,
})

local CombatTab = Window:CreateTab("Combat", 4483362458)
CombatTab:CreateSection("No Spread / No Recoil")
CombatTab:CreateToggle({
    Name = "No Spread", CurrentValue = false, Flag = "combat_nospread",
    Callback = function(v) State.combat.noSpread = v end,
})
CombatTab:CreateToggle({
    Name = "No Recoil", CurrentValue = false, Flag = "combat_norecoil",
    Callback = function(v) State.camera.noRecoil = v end,
})

CombatTab:CreateSection("Rapid Fire")
CombatTab:CreateToggle({
    Name = "Rapid Fire", CurrentValue = false, Flag = "combat_rapid",
    Callback = function(v) State.combat.rapidFire.enabled = v end,
})
CombatTab:CreateSlider({
    Name = "Rapid Fire Speed", Range = {0, 100}, Increment = 1, Suffix = "%",
    CurrentValue = State.combat.rapidFire.speed, Flag = "combat_rapid_speed",
    Callback = function(v) State.combat.rapidFire.speed = v end,
})

CombatTab:CreateSection("Damage Up")
CombatTab:CreateToggle({
    Name = "Damage Up (x2)", CurrentValue = false, Flag = "combat_dmgup",
    Callback = function(v) State.combat.damageUp.enabled = v end,
})

CombatTab:CreateSection("Mentos Makro")
CombatTab:CreateToggle({
    Name = "Auto Mentos", CurrentValue = false, Flag = "mentos_enabled",
    Callback = function(v)
        State.mentos.enabled = v
        startMentosLoop()
    end,
})
CombatTab:CreateSlider({
    Name = "Mentos Interval", Range = {1, 30}, Increment = 1, Suffix = "s",
    CurrentValue = 1, Flag = "mentos_interval",
    Callback = function(v) State.mentos.interval = v end,
})

local EspTab = Window:CreateTab("ESP Visual", 4483362458)
EspTab:CreateSection("ESP Visual")
EspTab:CreateToggle({
    Name = "Enable ESP", CurrentValue = false, Flag = "esp_enabled",
    Callback = function(v) State.esp.enabled = v end,
})
EspTab:CreateToggle({
    Name = "Name", CurrentValue = true, Flag = "esp_name",
    Callback = function(v) State.esp.name = v end,
})
EspTab:CreateToggle({
    Name = "Box", CurrentValue = true, Flag = "esp_box",
    Callback = function(v) State.esp.box = v end,
})
EspTab:CreateToggle({
    Name = "Skeleton", CurrentValue = true, Flag = "esp_skeleton",
    Callback = function(v) State.esp.skeleton = v end,
})
EspTab:CreateToggle({
    Name = "Health Bar", CurrentValue = true, Flag = "esp_health",
    Callback = function(v) State.esp.health = v end,
})
EspTab:CreateToggle({
    Name = "Distance", CurrentValue = true, Flag = "esp_dist",
    Callback = function(v) State.esp.distance = v end,
})
EspTab:CreateToggle({
    Name = "Team Check", CurrentValue = false, Flag = "esp_team",
    Callback = function(v) State.esp.teamCheck = v end,
})
EspTab:CreateColorPicker({
    Name = "ESP Color", Color = State.esp.color, Flag = "esp_color",
    Callback = function(c) State.esp.color = c end,
})

local MoveTab = Window:CreateTab("Movement", 4483362458)
MoveTab:CreateSection("Movement")
MoveTab:CreateToggle({
    Name = "Infinite Energy", CurrentValue = false, Flag = "move_inf_energy",
    Callback = function(v)
        State.movement.infiniteEnergy = v
        startEnergyLoop()
        if not v and energyConnection then
            energyConnection:Disconnect(); energyConnection = nil
        end
    end,
})
MoveTab:CreateSlider({
    Name = "WalkSpeed", Range = {0, 100}, Increment = 1, Suffix = "studs",
    CurrentValue = State.movement.walkSpeed, Flag = "move_ws",
    Callback = function(v) applyWalkSpeed(v) end,
})

local CamTab = Window:CreateTab("Camera", 4483362458)
CamTab:CreateSection("Camera")
CamTab:CreateSlider({
    Name = "Camera FOV", Range = {20, 120}, Increment = 1, Suffix = "°",
    CurrentValue = State.camera.fov, Flag = "cam_fov",
    Callback = function(v) applyCameraFov(v) end,
})
CamTab:CreateButton({
    Name = "Reset Camera FOV",
    Callback = function()
        applyCameraFov(State.camera.defaultFov)
        pcall(function() Rayfield:Notify({
            Title = "Melz", Content = "Camera FOV reset",
            Duration = 3,
        }) end)
    end,
})

local PerfTab = Window:CreateTab("Performance", 4483362458)
PerfTab:CreateSection("FPS Boost")
PerfTab:CreateToggle({
    Name = "FPS Boost", CurrentValue = false, Flag = "perf_fpsboost",
    Callback = function(v)
        State.perf.fpsBoost = v
        if v then enableFpsBoost() else disableFpsBoost() end
    end,
})

PerfTab:CreateSection("Fake FPS")
PerfTab:CreateToggle({
    Name = "Show Fake FPS", CurrentValue = false, Flag = "perf_fakefps",
    Callback = function(v) State.perf.fakeFps = v; updateFakeFps() end,
})
PerfTab:CreateSlider({
    Name = "Fake FPS Value", Range = {30, 1000}, Increment = 1, Suffix = "",
    CurrentValue = State.perf.fakeFpsValue, Flag = "perf_fakefps_val",
    Callback = function(v) State.perf.fakeFpsValue = v; updateFakeFps() end,
})

-- ============================================================
-- Cleanup
-- ============================================================
local function unload()
    if aimConnection then aimConnection:Disconnect() end
    if silentConnection then silentConnection:Disconnect() end
    if energyConnection then energyConnection:Disconnect() end
    if mentosConnection then State.mentos.enabled = false end
    clearAllESP()
    if AimlockFovCircle then pcall(function() AimlockFovCircle:Remove() end) end
    if SilentFovCircle then pcall(function() SilentFovCircle:Remove() end) end
    if FakeFpsGui then pcall(function() FakeFpsGui.gui:Destroy() end); FakeFpsGui = nil end
    if State.perf.fpsBoost then disableFpsBoost() end
    applyWalkSpeed(State.movement.defaultWalkSpeed)
    applyCameraFov(State.camera.defaultFov)
    if hookInstalled and oldNamecall then
        local mt = getrawmetatable(game)
        setreadonly(mt, false)
        mt.__namecall = oldNamecall
        setreadonly(mt, true)
        hookInstalled = false
    end
end

pcall(function() Rayfield:Notify({
    Title = "Melz Hub V1.1",
    Content = "Silent aim fix + combat suite loaded.",
    Duration = 4,
}) end)

getgenv().MelzHub = {
    state = State,
    unload = unload,
    window = Window,
}

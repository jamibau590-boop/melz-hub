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
-- Rayfield loader (embedded)
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
    Name = "Melz Hub V1.0",
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
-- Shared state
-- ============================================================
local State = {
    aimlock = {
        enabled = false,
        fov = 120,
        color = Color3.fromRGB(255, 60, 60),
        size = 2,
        part = "Head",
        smoothing = 0.25,
        wallCheck = true,
    },
    silentAim = {
        enabled = false,
        fov = 150,
        color = Color3.fromRGB(60, 180, 255),
        size = 2,
        invisibleFov = true,
        part = "Head",
        wallCheck = false,
    },
    esp = {
        enabled = false,
        name = true,
        box = true,
        skeleton = true,
        health = true,
        distance = true,
        teamCheck = false,
        color = Color3.fromRGB(80, 200, 255),
        textColor = Color3.fromRGB(255, 255, 255),
    },
    movement = {
        infiniteEnergy = false,
        walkSpeed = 16,
        defaultWalkSpeed = 16,
    },
    camera = {
        fov = 70,
        defaultFov = Camera and Camera.FieldOfView or 70,
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

local function getChar(player)
    return player and player.Character
end

local function getHRP(character)
    return character and character:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid(character)
    return character and character:FindFirstChildOfClass("Humanoid")
end

local function isSameTeam(a, b)
    if not a or not b then return false end
    local ta = a.Team
    local tb = b.Team
    return ta ~= nil and tb ~= nil and ta == tb
end

local function worldToViewport(pos)
    local sp, onScreen = Camera:WorldToViewportPoint(pos)
    return Vector2.new(sp.X, sp.Y), onScreen, sp.Z
end

local function hasLineOfSight(targetPart)
    if not targetPart then return false end
    local origin = Camera.CFrame.Position
    local dir = (targetPart.Position - origin)
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
    return character:FindFirstChild(partName) or character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart")
end

-- ============================================================
-- Aimlock
-- ============================================================
local AimlockFovCircle
local function ensureAimFovCircle()
    if AimlockFovCircle then return end
    local ok, circle = pcall(function()
        return Drawing.new("Circle")
    end)
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
        AimlockFovCircle.Position = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    end
end

local function findNearestPlayer(fovRadius, partName, wallCheck, teamCheck)
    local center = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    local best, bestDist = nil, fovRadius
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and isAlive(player.Character) then
            if teamCheck and isSameTeam(LocalPlayer, player) then
                -- skip
            else
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

local currentAimTarget = nil
local aimConnection
local function startAimlock()
    if aimConnection then aimConnection:Disconnect(); aimConnection = nil end
    aimConnection = RunService.RenderStepped:Connect(function(dt)
        updateAimFovCircle()
        if not State.aimlock.enabled then return end
        if not Camera then return end

        local target = findNearestPlayer(
            State.aimlock.fov,
            State.aimlock.part,
            State.aimlock.wallCheck,
            false
        )
        if target then
            currentAimTarget = target
            local goal = CFrame.new(Camera.CFrame.Position, target.part.Position)
            local smooth = math.clamp(State.aimlock.smoothing, 0.01, 1)
            Camera.CFrame = Camera.CFrame:Lerp(goal, smooth)
        else
            currentAimTarget = nil
        end
    end)
end
startAimlock()

-- ============================================================
-- Silent Aim (metamethod hook on CFrame.lookAt / mouse hit)
-- ============================================================
local silentState = {
    enabled = false,
    targetPart = nil,
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
        SilentFovCircle.Position = Vector2.new(Camera.ViewportSize.X / 2, Camera.ViewportSize.Y / 2)
    end
end

-- Silent aim via hooking namecall on mouse.Hit + CFrame.lookAt
local oldNamecall
local function installSilentHook()
    if oldNamecall then return end
    local mt = getrawmetatable(game)
    setreadonly(mt, false)
    oldNamecall = mt.__namecall
    mt.__namecall = newcclosure(function(self, ...)
        local method = getnamecallmethod()
        if State.silentAim.enabled and (method == "FindPartOnRayWithIgnoreList" or method == "FindPartOnRayWithWhitelist") then
            -- passthrough
        elseif State.silentAim.enabled and method == "FireServer" and self.Name == "Hit" then
            -- legacy mouse.Hit path
        end
        return oldNamecall(self, ...)
    end)
    setreadonly(mt, true)
end

-- Prefer __index / CFrame.lookAt hook when supported
local function installLookAtHook()
    local ok = pcall(function()
        local cfMt = getrawmetatable(game)
        setreadonly(cfMt, false)
        local oldIndex = cfMt.__index
        cfMt.__index = newcclosure(function(self, key)
            if State.silentAim.enabled and key == "lookAt" and rawequal(self, CFrame) then
                return function(originCF, targetPos)
                    if silentState.targetPart then
                        local look = CFrame.new(originCF.Position, silentState.targetPart.Position)
                        return oldIndex(self, "lookAt")(look, silentState.targetPart.Position)
                    end
                    return oldIndex(self, "lookAt")(originCF, targetPos)
                end
            end
            return oldIndex(self, key)
        end)
        setreadonly(cfMt, true)
    end)
    return ok
end
installLookAtHook()

local silentConnection = RunService.RenderStepped:Connect(function()
    updateSilentFovCircle()
    if not State.silentAim.enabled then
        silentState.targetPart = nil
        return
    end
    local target = findNearestPlayer(
        State.silentAim.fov,
        State.silentAim.part,
        State.silentAim.wallCheck,
        true
    )
    if target then
        silentState.targetPart = target.part
    else
        silentState.targetPart = nil
    end
end)

-- ============================================================
-- ESP
-- ============================================================
local ESPObjects = {} -- [player] = { drawing objects }

local function clearESPFor(player)
    local obj = ESPObjects[player]
    if not obj then return end
    for _, d in pairs(obj) do
        pcall(function() d:Remove() end)
    end
    ESPObjects[player] = nil
end

local function clearAllESP()
    for player in pairs(ESPObjects) do
        clearESPFor(player)
    end
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
    for i = 1, 6 do
        obj.skeleton[i] = newDrawing("Line")
    end
    if obj.name then
        obj.name.Center = true
        obj.name.Outline = true
        obj.name.Size = 14
    end
    if obj.distance then
        obj.distance.Center = true
        obj.distance.Outline = true
        obj.distance.Size = 12
    end
    if obj.box then
        obj.box.Thickness = 1
        obj.box.Filled = false
    end
    if obj.health then
        obj.health.Thickness = 2
    end
    for i = 1, 6 do
        if obj.skeleton[i] then
            obj.skeleton[i].Thickness = 1
        end
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
                    -- skip drawing but keep clear
                    if ESPObjects[player] then clearESPFor(player) end
                else
                    seen[player] = true
                    buildESPFor(player)
                    local obj = ESPObjects[player]
                    if not obj then continue end

                    -- Box from head + root
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
                                        line.From = pa
                                        line.To = pb
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
                        -- offscreen
                        if obj.box then obj.box.Visible = false end
                        if obj.name then obj.name.Visible = false end
                        if obj.distance then obj.distance.Visible = false end
                        if obj.health then obj.health.Visible = false end
                        for i = 1, #obj.skeleton do
                            if obj.skeleton[i] then obj.skeleton[i].Visible = false end
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
    for player, _ in pairs(ESPObjects) do
        if not seen[player] then
            clearESPFor(player)
        end
    end
end

RunService.RenderStepped:Connect(updateESP)

Players.PlayerRemoving:Connect(function(player)
    clearESPFor(player)
end)

-- ============================================================
-- Infinite Energy / Infinity Run
-- ============================================================
local energyConnection
local function applyInfiniteEnergy()
    local char = getChar(LocalPlayer)
    if not char then return end
    local hum = getHumanoid(char)
    if not hum then return end
    -- Many Roblox games use an "Energy" / "Stamina" IntValue or NumberValue on the character or player
    local roots = { char, LocalPlayer, LocalPlayer:FindFirstChild("PlayerGui") }
    for _, root in ipairs(roots) do
        if root then
            for _, child in ipairs(root:GetDescendants()) do
                if child:IsA("NumberValue") then
                    local n = child.Name:lower()
                    if n:find("energy") or n:find("stamina") or n:find("sprint") then
                        pcall(function() child.Value = 1e9 end)
                    end
                elseif child:IsA("IntValue") then
                    local n = child.Name:lower()
                    if n:find("energy") or n:find("stamina") or n:find("sprint") then
                        pcall(function() child.Value = math.huge end)
                    end
                end
            end
        end
    end
    -- Universal falls: restore health + jump power so you never "run out"
    if State.movement.infiniteEnergy then
        hum.WalkSpeed = math.max(hum.WalkSpeed, State.movement.walkSpeed)
    end
end

local function startEnergyLoop()
    if energyConnection then energyConnection:Disconnect() end
    if not State.movement.infiniteEnergy then return end
    energyConnection = RunService.Heartbeat:Connect(function()
        if not State.movement.infiniteEnergy then return end
        local char = getChar(LocalPlayer)
        local hum = getHumanoid(char)
        if hum then
            pcall(function()
                hum.Health = hum.MaxHealth
            end)
            pcall(function()
                hum.JumpPower = 100
                hum.UseJumpPower = true
            end)
        end
        applyInfiniteEnergy()
    end)
end

-- ============================================================
-- Movement / Camera helpers
-- ============================================================
local function applyWalkSpeed(speed)
    State.movement.walkSpeed = speed
    local char = getChar(LocalPlayer)
    local hum = getHumanoid(char)
    if hum then
        pcall(function() hum.WalkSpeed = speed end)
    end
end

local function applyCameraFov(fov)
    State.camera.fov = fov
    if Camera then
        pcall(function() Camera.FieldOfView = fov end)
    end
end

-- Re-apply on respawn
LocalPlayer.CharacterAdded:Connect(function()
    task.wait(0.4)
    applyWalkSpeed(State.movement.walkSpeed)
    applyCameraFov(State.camera.fov)
    if State.movement.infiniteEnergy then startEnergyLoop() end
end)

-- ============================================================
-- UI — Aimlock
-- ============================================================
local AimTab = Window:CreateTab("Aimlock", 4483362458)
local AimSection = AimTab:CreateSection("Aimlock")

AimTab:CreateToggle({
    Name = "Aimlock",
    CurrentValue = false,
    Flag = "aimlock_enabled",
    Callback = function(v) State.aimlock.enabled = v end,
})

AimTab:CreateSlider({
    Name = "FOV Radius",
    Range = {0, 800},
    Increment = 1,
    Suffix = "px",
    CurrentValue = State.aimlock.fov,
    Flag = "aimlock_fov",
    Callback = function(v) State.aimlock.fov = v end,
})

AimTab:CreateSlider({
    Name = "FOV Thickness",
    Range = {1, 8},
    Increment = 1,
    CurrentValue = State.aimlock.size,
    Flag = "aimlock_size",
    Callback = function(v) State.aimlock.size = v end,
})

AimTab:CreateColorPicker({
    Name = "FOV Color",
    Color = State.aimlock.color,
    Flag = "aimlock_color",
    Callback = function(c) State.aimlock.color = c end,
})

AimTab:CreateDropdown({
    Name = "Aim Part",
    Options = {"Head", "HumanoidRootPart", "UpperTorso"},
    CurrentOption = {"Head"},
    MultipleOptions = false,
    Flag = "aimlock_part",
    Callback = function(opt)
        State.aimlock.part = type(opt) == "table" and opt[1] or opt
    end,
})

AimTab:CreateSlider({
    Name = "Smoothing",
    Range = {1, 100},
    Increment = 1,
    Suffix = "%",
    CurrentValue = math.floor(State.aimlock.smoothing * 100),
    Flag = "aimlock_smooth",
    Callback = function(v) State.aimlock.smoothing = v / 100 end,
})

AimTab:CreateToggle({
    Name = "Wall Check",
    CurrentValue = true,
    Flag = "aimlock_wall",
    Callback = function(v) State.aimlock.wallCheck = v end,
})

-- ============================================================
-- UI — Silent Aim
-- ============================================================
local SilentTab = Window:CreateTab("Silent Aim", 4483362458)
SilentTab:CreateSection("Silent Aim")

SilentTab:CreateToggle({
    Name = "Silent Aim",
    CurrentValue = false,
    Flag = "silent_enabled",
    Callback = function(v) State.silentAim.enabled = v end,
})

SilentTab:CreateSlider({
    Name = "FOV Radius",
    Range = {0, 800},
    Increment = 1,
    Suffix = "px",
    CurrentValue = State.silentAim.fov,
    Flag = "silent_fov",
    Callback = function(v) State.silentAim.fov = v end,
})

SilentTab:CreateSlider({
    Name = "FOV Thickness",
    Range = {1, 8},
    Increment = 1,
    CurrentValue = State.silentAim.size,
    Flag = "silent_size",
    Callback = function(v) State.silentAim.size = v end,
})

SilentTab:CreateColorPicker({
    Name = "FOV Color",
    Color = State.silentAim.color,
    Flag = "silent_color",
    Callback = function(c) State.silentAim.color = c end,
})

SilentTab:CreateToggle({
    Name = "Invisible FOV",
    CurrentValue = true,
    Flag = "silent_invis",
    Callback = function(v) State.silentAim.invisibleFov = v end,
})

SilentTab:CreateDropdown({
    Name = "Hit Part",
    Options = {"Head", "HumanoidRootPart", "UpperTorso"},
    CurrentOption = {"Head"},
    MultipleOptions = false,
    Flag = "silent_part",
    Callback = function(opt)
        State.silentAim.part = type(opt) == "table" and opt[1] or opt
    end,
})

SilentTab:CreateToggle({
    Name = "Wall Check",
    CurrentValue = false,
    Flag = "silent_wall",
    Callback = function(v) State.silentAim.wallCheck = v end,
})

-- ============================================================
-- UI — ESP
-- ============================================================
local EspTab = Window:CreateTab("ESP Visual", 4483362458)
EspTab:CreateSection("ESP Visual")

EspTab:CreateToggle({
    Name = "Enable ESP",
    CurrentValue = false,
    Flag = "esp_enabled",
    Callback = function(v) State.esp.enabled = v end,
})

EspTab:CreateToggle({
    Name = "Name",
    CurrentValue = true,
    Flag = "esp_name",
    Callback = function(v) State.esp.name = v end,
})

EspTab:CreateToggle({
    Name = "Box",
    CurrentValue = true,
    Flag = "esp_box",
    Callback = function(v) State.esp.box = v end,
})

EspTab:CreateToggle({
    Name = "Skeleton",
    CurrentValue = true,
    Flag = "esp_skeleton",
    Callback = function(v) State.esp.skeleton = v end,
})

EspTab:CreateToggle({
    Name = "Health Bar",
    CurrentValue = true,
    Flag = "esp_health",
    Callback = function(v) State.esp.health = v end,
})

EspTab:CreateToggle({
    Name = "Distance",
    CurrentValue = true,
    Flag = "esp_dist",
    Callback = function(v) State.esp.distance = v end,
})

EspTab:CreateToggle({
    Name = "Team Check",
    CurrentValue = false,
    Flag = "esp_team",
    Callback = function(v) State.esp.teamCheck = v end,
})

EspTab:CreateColorPicker({
    Name = "ESP Color",
    Color = State.esp.color,
    Flag = "esp_color",
    Callback = function(c) State.esp.color = c end,
})

-- ============================================================
-- UI — Movement
-- ============================================================
local MoveTab = Window:CreateTab("Movement", 4483362458)
MoveTab:CreateSection("Movement")

MoveTab:CreateToggle({
    Name = "Infinite Energy",
    CurrentValue = false,
    Flag = "move_inf_energy",
    Callback = function(v)
        State.movement.infiniteEnergy = v
        startEnergyLoop()
        if not v and energyConnection then
            energyConnection:Disconnect()
            energyConnection = nil
        end
    end,
})

MoveTab:CreateSlider({
    Name = "WalkSpeed",
    Range = {0, 100},
    Increment = 1,
    Suffix = "studs",
    CurrentValue = State.movement.walkSpeed,
    Flag = "move_ws",
    Callback = function(v) applyWalkSpeed(v) end,
})

-- ============================================================
-- UI — Camera
-- ============================================================
local CamTab = Window:CreateTab("Camera", 4483362458)
CamTab:CreateSection("Camera")

CamTab:CreateSlider({
    Name = "Camera FOV",
    Range = {20, 120},
    Increment = 1,
    Suffix = "°",
    CurrentValue = State.camera.fov,
    Flag = "cam_fov",
    Callback = function(v) applyCameraFov(v) end,
})

CamTab:CreateButton({
    Name = "Reset Camera FOV",
    Callback = function()
        applyCameraFov(State.camera.defaultFov)
        if Rayfield then pcall(function() Rayfield:Notify({
            Title = "Melz",
            Content = "Camera FOV reset to " .. tostring(math.floor(State.camera.defaultFov)),
            Duration = 3,
        }) end) end
    end,
})

-- ============================================================
-- Cleanup hooks
-- ============================================================
local function unload()
    if aimConnection then aimConnection:Disconnect() end
    if silentConnection then silentConnection:Disconnect() end
    if energyConnection then energyConnection:Disconnect() end
    clearAllESP()
    if AimlockFovCircle then pcall(function() AimlockFovCircle:Remove() end) end
    if SilentFovCircle then pcall(function() SilentFovCircle:Remove() end) end
    applyWalkSpeed(State.movement.defaultWalkSpeed)
    applyCameraFov(State.camera.defaultFov)
end

if Rayfield then
    pcall(function()
        Rayfield:Notify({
            Title = "Melz Hub V1.0",
            Content = "Loaded. Universal client — aim, ESP, movement, camera.",
            Duration = 4,
        })
    end)
end

-- Expose for executor console / debugging
getgenv().MelzHub = {
    state = State,
    unload = unload,
    window = Window,
}
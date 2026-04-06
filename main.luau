local ContentProvider   = game:GetService("ContentProvider")
local Debris            = game:GetService("Debris")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local SoundService      = game:GetService("SoundService")
local UserInputService  = game:GetService("UserInputService")

local Spring      = require(script.spring)
local OffsetStack = require(script.offsetstack)

local Player = Players.LocalPlayer

local VIEWMODEL_REST_POS = Vector3.new(0, 10_000_000, 0)
local BOB_SPEED_DIVISOR  = 700
local SWAY_MOUSE_DIVISOR = 800
local LEAN_LERP_SPEED    = 0.1
local BREATHE_AMPLITUDE  = 0.08
local BREATHE_FREQUENCY  = 1.5

local FIREMODE_SEMI  = "Semi"
local FIREMODE_BURST = "Burst"
local FIREMODE_AUTO  = "Auto"

local function getBobbing(freq: number): number
	local t = tick()
	return math.sin(t * freq * 1.3) * 0.45
		+ math.sin(t * freq * 2.6) * 0.1
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function playDetachedSound(sound: Sound)
	local clone = sound:Clone()
	clone.Parent = SoundService
	clone:Play()
	Debris:AddItem(clone, clone.TimeLength + 0.1)
end

local WeaponSystem   = {}
WeaponSystem.__index = WeaponSystem

function WeaponSystem.new()
	local self = setmetatable({}, WeaponSystem)

	self.Camera  = workspace.CurrentCamera
	self.Weapons = ReplicatedStorage:WaitForChild("Weapons")

	self.Viewmodel = self:_initViewmodel()
	self.Animator  = self.Viewmodel.Humanoid.Animator

	self.PreloadedAnimations = {}
	self.LoadedAnimations    = {}

	self.CurrentWeapon = nil

	self.CamBob     = Spring.create(nil, 6, 60, 4, 5)
	self.LeanSpring = Spring.create(nil, 5, 70, 4, 6)

	self.LeanValue  = 0
	self.LeanTarget = 0

	self.IsFiring    = false
	self.IsReloading = false
	self.BurstCount  = 0
	self.FireAccum   = 0

	self._charRoot = nil
	local function cacheRoot(char)
		self._charRoot = char:WaitForChild("HumanoidRootPart")
	end
	if Player.Character then cacheRoot(Player.Character) end
	Player.CharacterAdded:Connect(cacheRoot)

	RunService.RenderStepped:Connect(function(delta)
		self:_onRenderStep(delta)
	end)

	return self
end

function WeaponSystem:_initViewmodel()
	local vm = ReplicatedStorage:WaitForChild("Viewmodel"):Clone()
	vm.Parent = self.Camera
	vm.HumanoidRootPart.CFrame = CFrame.new(VIEWMODEL_REST_POS)
	return vm
end

function WeaponSystem:_onRenderStep(delta: number)
	local root = self._charRoot
	if not root then return end

	local velocity   = root.AssemblyLinearVelocity
	local horizVel   = velocity * Vector3.new(1, 0, 1)
	local horizSpeed = horizVel.Magnitude

	local bobInput = Vector3.new(getBobbing(5), getBobbing(10), getBobbing(5))
		* (horizSpeed * delta * 60 / BOB_SPEED_DIVISOR) / 100
	self.CamBob:shove(bobInput)
	local camBob = self.CamBob:update(delta)

	self.LeanValue = lerp(self.LeanValue, self.LeanTarget, delta * 60 * LEAN_LERP_SPEED)

	self.Camera.CFrame = self.Camera.CFrame
		* CFrame.Angles(camBob.X, camBob.Y, camBob.Z)
		* CFrame.new(self.LeanValue * 0.5, 0, 0)
		* CFrame.Angles(0, 0, math.rad(-self.LeanValue * 20))

	if not self.CurrentWeapon then
		self.Viewmodel.HumanoidRootPart.CFrame = CFrame.new(VIEWMODEL_REST_POS)
		return
	end

	local weapon = self.CurrentWeapon
	if self.IsFiring and not self.IsReloading then
		local mode     = weapon.FireMode
		local interval = 1 / weapon.Config.Firerate.ShotsPerSecond

		self.FireAccum = self.FireAccum + delta

		if mode == FIREMODE_AUTO then
			while self.FireAccum >= interval do
				self.FireAccum = self.FireAccum - interval
				self:_fireSingleShot()
			end

		elseif mode == FIREMODE_BURST then
			while self.FireAccum >= interval and self.BurstCount > 0 do
				self.FireAccum = self.FireAccum - interval
				self:_fireSingleShot()
				self.BurstCount = self.BurstCount - 1
			end
			if self.BurstCount <= 0 then
				self.IsFiring  = false
				self.FireAccum = 0
			end

		elseif mode == FIREMODE_SEMI then
			if self.FireAccum >= interval then
				self.FireAccum = 0
				self:_fireSingleShot()
				self.IsFiring = false
			end
		end
	else
		self.FireAccum = 0
	end

	local hipConfig   = weapon.Config.Hip
	local adsAlpha    = weapon.Offsets:GetWeight("Aim")
	local mouseDelta  = UserInputService:GetMouseDelta()
	local relHorizVel = self.Camera.CFrame:VectorToObjectSpace(horizVel)

	local swayStrength = 1 - adsAlpha * 0.7

	local scaledMouse = mouseDelta / SWAY_MOUSE_DIVISOR * swayStrength
	weapon.Springs.Sway:shove(Vector3.new(scaledMouse.X, scaledMouse.Y, scaledMouse.X * 0.4))
	local sway = weapon.Springs.Sway:update(delta)

	local bobbing = Vector3.new(getBobbing(10) * 1.2, getBobbing(5) * 1.5, getBobbing(5))
	weapon.Springs.Walk:shove(bobbing * (horizSpeed * swayStrength * delta * 60 / BOB_SPEED_DIVISOR))
	local bob = weapon.Springs.Walk:update(delta)

	local breathe = math.sin(tick() * BREATHE_FREQUENCY) * BREATHE_AMPLITUDE
	weapon.Springs.Detail:shove(Vector3.new(
		relHorizVel.X / 1000 * swayStrength,
		-velocity.Y    / 3000 * swayStrength,
		breathe       / 50
		))
	local detail = weapon.Springs.Detail:update(delta)

	local hip = weapon.Hip - Vector2.new(-mouseDelta.X, mouseDelta.Y)
		* (hipConfig.Speed * (1 - adsAlpha) * delta * 60)
	hip = Vector2.new(math.clamp(hip.X, -1, 1), math.clamp(hip.Y, -1, 1))
	hip = hip:Lerp(Vector2.zero, adsAlpha * delta * 10)
	weapon.Hip = hip

	local hipRot = hip * hipConfig.Limits.Rotation
	local hipPos = hip * hipConfig.Limits.Position

	local recoil    = weapon.Springs.Recoil:update(delta)    * swayStrength
	local aimRecoil = weapon.Springs.AimRecoil:update(delta) * adsAlpha
	local camRecoil = weapon.Springs.CamRecoil:update(delta) / 10

	weapon.Hip = Vector2.new(
		math.clamp(weapon.Hip.X + recoil.Y * 1.25 * (1 - adsAlpha), -1, 1),
		math.clamp(weapon.Hip.Y + recoil.X / 5   * (1 - adsAlpha), -1, 1)
	)

	if weapon.BoltMotor and weapon.BoltRestC1 then
		local boltCfg = weapon.Config.Bolt
		weapon.BoltTarget = math.max(0, weapon.BoltTarget - delta * boltCfg.DecaySpeed)
		weapon.BoltMotor.C1 = weapon.BoltRestC1:Lerp(
			weapon.BoltRestC1 * CFrame.new(0, 0, -boltCfg.TravelDist),
			weapon.BoltTarget
		)
	end

	weapon.Offsets:SetWeight("Sprint", horizSpeed >= 20 and 1 or 0)

	self.Viewmodel.HumanoidRootPart.CFrame =
		self.Camera.CFrame
		* CFrame.Angles(aimRecoil.X, aimRecoil.Y, 0)
		* weapon.Offsets:Resolve()
		* CFrame.Angles(math.rad(hipRot.Y), math.rad(-hipRot.X), 0)
		* CFrame.new(hipPos.X, hipPos.Y, 0)
		* CFrame.new(-sway.X, sway.Y, 0)
		* CFrame.Angles(-sway.Y, -sway.X, -sway.X)
		* CFrame.Angles(bob.X, bob.Y, bob.Z)
		* CFrame.Angles(-detail.Y, 0, -detail.X)
		* CFrame.Angles(detail.Z, 0, 0)
		* CFrame.Angles(recoil.X, recoil.Y, 0)
		* CFrame.new(0, 0, recoil.Z)

	self.Camera.CFrame = self.Camera.CFrame
		* CFrame.Angles(camRecoil.X, camRecoil.Y, camRecoil.Z)
end

function WeaponSystem:_fireSingleShot()
	local weapon = self.CurrentWeapon
	if not weapon then return false end
	if self.IsReloading then return false end

	if weapon.Ammo <= 0 then
		self:_beginReload()
		return false
	end

	weapon.Ammo = weapon.Ammo - 1

	local rc  = weapon.Config.Recoil
	local crc = weapon.Config.CamRecoil

	local rx = (math.random(-100, 100) / 1000) * rc.RandomX
	local ry = (math.random(-100, 100) / 1000) * rc.RandomY
	weapon.Springs.Recoil:shove(Vector3.new(rc.KickX + rx, ry, rc.KickZ))
	weapon.Springs.AimRecoil:shove(Vector3.new((rc.KickX + rx) * rc.AimMult, ry * rc.AimMult, 0))

	local crx = (math.random(-100, 100) / 1000) * crc.RandomX
	local cry = (math.random(-100, 100) / 1000) * crc.RandomY
	weapon.Springs.CamRecoil:shove(Vector3.new(crc.KickX + crx, cry, crc.KickZ))

	if weapon.Muzzle then
		for _, v in ipairs(weapon.Muzzle:GetChildren()) do
			if v:IsA("ParticleEmitter") then
				v:Emit(10)
			elseif v:IsA("PointLight") then
				v.Enabled = true
				task.delay(0.1, function() v.Enabled = false end)
			elseif v:IsA("Sound") then
				playDetachedSound(v)
			end
		end
	end

	if weapon.BoltMotor then
		weapon.BoltTarget = 1
	end

	return true
end

function WeaponSystem:_beginReload()
	local weapon = self.CurrentWeapon
	if not weapon then return end
	if self.IsReloading then return end
	if weapon.Reserve <= 0 then return end
	if weapon.Ammo >= weapon.Config.Ammo.MagSize then return end

	self.IsReloading = true
	self:_playAnimation(weapon.Name, "Reload")

	task.delay(weapon.Config.Ammo.ReloadTime, function()
		if not self.CurrentWeapon or self.CurrentWeapon.Name ~= weapon.Name then return end

		local needed  = weapon.Config.Ammo.MagSize - weapon.Ammo
		local given   = math.min(needed, weapon.Reserve)
		weapon.Ammo    = weapon.Ammo + given
		weapon.Reserve = weapon.Reserve - given
		self.IsReloading = false
	end)
end

function WeaponSystem:_cycleFireMode()
	local weapon = self.CurrentWeapon
	if not weapon then return end

	local modes   = weapon.Config.Firerate.Modes
	local current = weapon.FireMode
	local nextIdx = 1

	for i, mode in ipairs(modes) do
		if mode == current then
			nextIdx = (i % #modes) + 1
			break
		end
	end

	weapon.FireMode = modes[nextIdx]
end

function WeaponSystem:_weldParts(part0: BasePart, part1: BasePart)
	local motor    = Instance.new("Motor6D")
	motor.Part0    = part0
	motor.Part1    = part1
	motor.C0       = part0.CFrame:Inverse() * part1.CFrame
	motor.C1       = CFrame.new()
	motor.Parent   = part0
end

function WeaponSystem:_weldModel(model: Model, parentPart: BasePart?)
	local primary = model.PrimaryPart
	if not primary then
		warn("[WeaponSystem] " .. model.Name .. " has no PrimaryPart — skipping weld")
		return
	end

	primary.CanCollide = false
	primary.Anchored   = false

	for _, child in ipairs(model:GetDescendants()) do
		if child:IsA("BasePart") and child ~= primary then
			child.CanCollide = false
			child.Anchored   = false
			local directParent = child.Parent
			local weldTarget = (directParent == model) and primary
				or (directParent:IsA("BasePart") and directParent)
				or nil
			if weldTarget then
				self:_weldParts(weldTarget, child)
			end
		end
	end

	if parentPart and parentPart:IsA("BasePart") then
		self:_weldParts(parentPart, primary)
		parentPart.CanCollide = false
		parentPart.Anchored   = false
	end
end

function WeaponSystem:_connectAnimationSounds(track: AnimationTrack, weaponName: string)
	track.KeyframeReached:Connect(function(keyframeName)
		local weapon = self.CurrentWeapon
		if not weapon or weapon.Name ~= weaponName then return end

		local sound = weapon.Model.PrimaryPart:FindFirstChild(keyframeName)
		if sound and sound:IsA("Sound") then
			playDetachedSound(sound)
		end
	end)
end

function WeaponSystem:_loadAnimations(weaponName: string, animations: { [string]: string })
	local toPreload = {}

	for animName, animId in pairs(animations) do
		local key = weaponName .. "_" .. animName
		if self.LoadedAnimations[key] then continue end

		local anim              = Instance.new("Animation")
		anim.Name               = animName
		anim.AnimationId        = animId
		anim.Parent             = self.Viewmodel
		self.PreloadedAnimations[key] = anim
		table.insert(toPreload, anim)
	end

	if #toPreload > 0 then
		ContentProvider:PreloadAsync(toPreload)
	end

	for key, anim in pairs(self.PreloadedAnimations) do
		if not self.LoadedAnimations[key] then
			local track = self.Animator:LoadAnimation(anim)
			self.LoadedAnimations[key] = track
			self:_connectAnimationSounds(track, key:match("^(.-)_"))
		end
	end
end

function WeaponSystem:_playAnimation(weaponName: string, animName: string)
	local track = self.LoadedAnimations[weaponName .. "_" .. animName]
	if track then
		track:Play(0)
	else
		warn("[WeaponSystem] Animation not found: " .. weaponName .. "_" .. animName)
	end
end

function WeaponSystem:_stopAllAnimations()
	for _, track in pairs(self.LoadedAnimations) do
		if track.IsPlaying then
			track:Stop(0)
		end
	end
end

function WeaponSystem:LoadWeapon(name: string)
	local template = self.Weapons:FindFirstChild(name)
	if not template then warn("[WeaponSystem] Weapon not found: " .. name) return end

	local configModule = template:FindFirstChild("Config")
	if not configModule then warn("[WeaponSystem] Config missing for: " .. name) return end
	local config = require(configModule)

	self:_stopAllAnimations()

	if config.Animations then
		self:_loadAnimations(name, config.Animations)
	end

	local model = template:Clone()
	self:_weldModel(model, nil)
	model.Parent = self.Viewmodel
	model.PrimaryPart.CFrame = self.Viewmodel.HumanoidRootPart.CFrame

	local mainMotor        = Instance.new("Motor6D")
	mainMotor.Part0        = self.Viewmodel.HumanoidRootPart
	mainMotor.Part1        = model.PrimaryPart
	mainMotor.Parent       = model.PrimaryPart

	local offsets = config.Offsets
	local stack   = OffsetStack.new(offsets.Idle)

	local layerOrder = offsets.Layers
	if layerOrder then
		for _, layerName in ipairs(layerOrder) do
			if offsets[layerName] then
				stack:AddLayer(layerName, offsets[layerName].CFrame, offsets[layerName].TweenInfo)
			end
		end
	else
		for layerName, data in pairs(offsets) do
			if layerName ~= "Idle" and layerName ~= "Layers" and typeof(data) == "table" then
				stack:AddLayer(layerName, data.CFrame, data.TweenInfo)
			end
		end
	end

	local char       = self._charRoot and self._charRoot.Parent
	local bodyColors = char and char:FindFirstChild("Body Colors")
	if bodyColors then
		self.Viewmodel["Left Arm"].Color  = bodyColors.LeftArmColor3
		self.Viewmodel["Right Arm"].Color = bodyColors.RightArmColor3
	end

	self.Viewmodel["Left Arm"].CanCollide  = false
	self.Viewmodel["Right Arm"].CanCollide = false

	local existingShirt = self.Viewmodel:FindFirstChildOfClass("Shirt")
	if existingShirt then existingShirt:Destroy() end

	local charShirt = char and char:FindFirstChildOfClass("Shirt")
	if charShirt then
		charShirt:Clone().Parent = self.Viewmodel
	end

	local boltMotor
	for _, child in ipairs(model.PrimaryPart:GetChildren()) do
		if child:IsA("Motor6D") and child.Part1 and child.Part1.Name == "Bolt" then
			boltMotor = child
			break
		end
	end

	self:_playAnimation(name, "Idle")
	stack:SetInstantWeight("Equip", 1)

	local rs  = config.Recoil.Spring    or {}
	local crs = config.CamRecoil.Spring or {}

	local ammoCfg = config.Ammo or {}
	local magSize = ammoCfg.MagSize or 30
	local reserve = ammoCfg.Reserve or 90

	self.CurrentWeapon = {
		Model      = model,
		Config     = config,
		Name       = name,
		Offsets    = stack,
		Muzzle     = model.PrimaryPart:FindFirstChild("Muzzle"),
		BoltMotor  = boltMotor,
		BoltRestC1 = boltMotor and boltMotor.C1 or nil,
		BoltTarget = 0,
		Hip        = Vector2.zero,
		Ammo       = magSize,
		Reserve    = reserve,
		FireMode   = (config.Firerate and config.Firerate.Modes and config.Firerate.Modes[1]) or FIREMODE_SEMI,
		Springs    = {
			Walk      = Spring.create(),
			Detail    = Spring.create(),
			Sway      = Spring.create(nil, 6,         80,          3.5,         5),
			Recoil    = Spring.create(nil, rs.Mass  or 8,  rs.Force  or 120, rs.Damping  or 2.5, rs.Speed  or 3),
			AimRecoil = Spring.create(nil, rs.Mass  or 6,  rs.Force  or 100, rs.Damping  or 2.5, rs.Speed  or 3),
			CamRecoil = Spring.create(nil, crs.Mass or 4,  crs.Force or 140, crs.Damping or 3,   crs.Speed or 4),
		},
	}

	self.IsReloading = false
	self.IsFiring    = false
	self.BurstCount  = 0
	self.FireAccum   = 0

	stack:SetWeight("Equip", 0)
	UserInputService.MouseIconEnabled = false
end

function WeaponSystem:UnloadWeapon(callback: (() -> ())?)
	if not self.CurrentWeapon then return end

	self.CurrentWeapon.Offsets:SetWeight("Equip", 1, function()
		if self.CurrentWeapon and self.CurrentWeapon.Model then
			self.CurrentWeapon.Model:Destroy()
		end
		self.CurrentWeapon = nil
		self.Viewmodel.HumanoidRootPart.CFrame = CFrame.new(VIEWMODEL_REST_POS)
		UserInputService.MouseIconEnabled = true
		if callback then callback() end
	end)
end

function WeaponSystem:SetLayerActive(layerName: string, active: boolean)
	if not self.CurrentWeapon then return end
	self.CurrentWeapon.Offsets:SetWeight(layerName, active and 1 or 0)
end

function WeaponSystem:SetLayerWeight(layerName: string, weight: number)
	if not self.CurrentWeapon then return end
	self.CurrentWeapon.Offsets:SetWeight(layerName, weight)
end

local system = WeaponSystem.new()

local WEAPON_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.One] = "MP5",
}

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end

	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		system:SetLayerActive("Aim", true)
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		local weapon = system.CurrentWeapon
		if not weapon then return end

		system.IsFiring = true

		if weapon.FireMode == FIREMODE_BURST then
			system.BurstCount = weapon.Config.Firerate.BurstSize or 3
		end
		return
	end

	if input.KeyCode == Enum.KeyCode.R then
		if system.CurrentWeapon then
			system:_beginReload()
		end
		return
	end

	if input.KeyCode == Enum.KeyCode.V then
		system:_cycleFireMode()
		return
	end

	if input.KeyCode == Enum.KeyCode.Q then
		system.LeanTarget = -1
		return
	end

	if input.KeyCode == Enum.KeyCode.E then
		system.LeanTarget = 1
		return
	end

	local targetWeapon = WEAPON_KEYS[input.KeyCode]
	if not targetWeapon then return end

	local current = system.CurrentWeapon
	if not current then
		system:LoadWeapon(targetWeapon)
	elseif current.Name == targetWeapon then
		system:UnloadWeapon()
	else
		system:UnloadWeapon(function()
			system:LoadWeapon(targetWeapon)
		end)
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		system:SetLayerActive("Aim", false)
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		system.IsFiring   = false
		system.BurstCount = 0
		return
	end

	if input.KeyCode == Enum.KeyCode.Q and system.LeanTarget == -1 then
		system.LeanTarget = 0
	elseif input.KeyCode == Enum.KeyCode.E and system.LeanTarget == 1 then
		system.LeanTarget = 0
	end
end)

return system
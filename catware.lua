-- Catware - Blox League (place 118675786171302). Obsidian UI, built/tested on Volt.
-- The game sim is a Luau RocketSim port and server-authoritative, so everything here works through
-- inputs (Input.Read hook) + a private ball-prediction Arena.
-- Run: loadstring(game:HttpGet("https://gitlab.com/azulacs/catware-blox-league/-/raw/main/catware.lua"))()
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LP = game:GetService("Players").LocalPlayer

-- running it twice (or via auto-load) replaces the old instance instead of stacking hooks
if getgenv().CatwareBloxLeagueUnload then pcall(getgenv().CatwareBloxLeagueUnload) end

-- may run straight after a teleport (auto-load), before the game's modules replicate
local Shared = RS:WaitForChild("Shared")
local Client = LP:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Sim = Shared:WaitForChild("Sim")
local Arena = require(Sim:WaitForChild("Arena"))
local Prediction = require(Shared:WaitForChild("Net"):WaitForChild("Prediction"))
local Input = require(Client:WaitForChild("Input"))
local Coords = require(Client:WaitForChild("Coords"))

local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local Library = loadstring(game:HttpGet(repo .. "Library.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local Options, Toggles = Library.Options, Library.Toggles

---------------------------------------------------------------- state
local P -- live Prediction instance (the client's u4)
for _, t in getgc(true) do
	if type(t) == "table" and rawget(t, "shadow") and rawget(t, "carsById") then P = t break end
end
local origStep, origRead = Prediction.Step, Input.Read
Prediction.Step = function(self, ...) P = self return origStep(self, ...) end

local TICK = 1 / 120
local path = {} -- predicted ball {pos, t} every PATH_STRIDE ticks
local PATH_STRIDE = 4
local simArena, simMutators

local function localCar()
	return P and P.tick and P:LocalCar()
end

local UU_PER_BT = 1 / require(Sim.Consts).UU_TO_BT
local function predictBall(seconds) -- ponytail: re-sims from scratch (~1ms/s of flight); the RenderStepped loop runs it every other frame
	table.clear(path)
	if not (P and P.tick) then return end
	local muts = P.arena.mutators
	if simMutators ~= muts then simArena, simMutators = Arena.New({ mutators = muts }), muts end
	simArena.ball:SetState(P.arena.ball:GetState())
	for i = 1, math.floor(seconds * 120) do
		simArena:Step(1)
		if i % PATH_STRIDE == 0 then
			table.insert(path, { pos = simArena.ball.body.pos * UU_PER_BT, t = i * TICK })
		end
	end
end

---------------------------------------------------------------- control helpers (signs measured in-sim)
-- steer/yaw + turns toward rot.right, pitch + = nose up, roll + tilts up toward rot.right
-- rates: pitch = -w·right, yaw = w·up, roll = -w·forward
local UP = vector.create(0, 0, 1)
local function clamp1(x) return math.clamp(x, -1, 1) end
local function flat(v) return vector.create(v.x, v.y, 0) end
local function mag(v) return vector.magnitude(v) end
local function angleTo(rot, dir)
	return math.atan2(vector.dot(dir, rot.right), vector.dot(dir, rot.forward))
end

local function nearBall(st, within)
	-- ball vs car 0.15s ahead; must be roughly in front and on our height, not just "close"
	local b = path[math.max(1, math.floor(0.15 / (PATH_STRIDE * TICK)))]
	if not b or st.rot.up.z < 0.7 then return nil end -- never flip off walls/ceiling
	local d = b.pos - (st.pos + st.vel * 0.15)
	if b.pos.z > 220 or math.abs(d.z) > 200 then return nil end
	local fwd, side = vector.dot(d, st.rot.forward), vector.dot(d, st.rot.right)
	if mag(flat(d)) < within and fwd > -40 and math.abs(side) < 130 then return b.pos end
end

---------------------------------------------------------------- mechanics (correction layer)
-- The policy picks the intent; this fixes the execution. It runs after Nexto and never against it:
-- analog aim on a strikable ball, flips at contact instead of at random, air recovery, wall escape,
-- boost discipline. One dodge state machine, owned here.
local Mech = {}
local dodge

function Mech.reset() dodge = nil end

local function orient(c, st, f)
	local rot, w = st.rot, st.angVel
	local eRoll = math.atan2(vector.dot(UP, rot.right), vector.dot(UP, rot.up))
	local ePitch = math.atan2(vector.dot(f, rot.up), vector.dot(f, rot.forward))
	local eYaw = math.atan2(vector.dot(f, rot.right), vector.dot(f, rot.forward))
	c.roll = clamp1(3 * eRoll + 0.6 * vector.dot(w, rot.forward))
	c.pitch = clamp1(3.5 * ePitch + 0.8 * vector.dot(w, rot.right))
	c.yaw = clamp1(3.5 * eYaw - 0.8 * vector.dot(w, rot.up))
end

local function recover(c, st, heading)
	local h = heading or flat(st.rot.forward)
	if mag(h) < 1 then h = vector.create(0, 1, 0) end
	orient(c, st, vector.normalize(h))
end

-- start a front/diagonal dodge toward target; refuses anything too far off the nose
function Mech.startFlip(st, target, tick)
	if dodge or not st.isOnGround or st.isFlipping then return false end
	local a = angleTo(st.rot, flat(target - st.pos))
	if math.abs(a) > 1.2 then return false end
	local p, y = -math.cos(a), math.sin(a)
	local m = math.max(math.abs(p), math.abs(y), 1e-3)
	dodge = { t0 = tick, pitch = p / m, yaw = y / m }
	return true
end

local function runDodge(c, tick)
	if not dodge then return false end
	local dt = (tick - dodge.t0) * TICK
	if dt > 0.9 or dt < 0 then dodge = nil return false end
	c.pitch, c.yaw, c.roll, c.boost = 0, 0, 0, false
	if dt < 0.08 then
		c.jump = true
	elseif dt < 0.13 then
		c.jump = false
	elseif dt < 0.2 then
		c.jump, c.pitch, c.yaw = true, dodge.pitch, dodge.yaw
	else
		c.jump, c.pitch, c.yaw = false, dodge.pitch, dodge.yaw
	end
	return true
end

-- c: controls to mutate. ctx: {tick, ball, ballVel, target, lastMan, kickoff, opts}
function Mech.correct(c, st, ctx)
	if not (st and st.rot and ctx) then return end
	local o = ctx.opts or {}

	-- a flip owns the controls outright
	if runDodge(c, ctx.tick) then return end

	local toBall = ctx.ball - st.pos
	local dist = mag(flat(toBall))
	local fwd = vector.dot(toBall, st.rot.forward)
	local side = vector.dot(toBall, st.rot.right)
	local speed = mag(flat(st.vel))

	-- 1. never boost past top speed, and don't burn the tank on a ball that is leaving
	if c.boost and speed > 2180 then c.boost = false end
	if c.boost and o.boostSave and st.boost < 12 and dist > 3000
		and vector.dot(ctx.ballVel, flat(st.pos - ctx.ball)) < 0 then
		c.boost = false
	end

	-- 2. air recovery whenever the policy gives no air input of its own
	local idleAir = math.abs(c.pitch) + math.abs(c.yaw) + math.abs(c.roll) < 0.1
	if o.recover and idleAir and not st.isOnGround and not st.isFlipping then
		local v = flat(st.vel)
		recover(c, st, speed > 300 and v or nil)
	end

	-- 3. off the wall: nose down and forward, the policy likes to sit up there
	if o.wall and math.abs(st.rot.up.z) < 0.45 and ctx.ball.z < 400 then
		recover(c, st, flat(st.rot.forward) - UP * 2)
	end

	-- 4. analog aim on a genuinely strikable ball
	if o.aim and st.isOnGround and dist < 420 and fwd > -30 and math.abs(side) < 200
		and math.abs(ctx.ball.z - st.pos.z) < 260 then
		local a = angleTo(st.rot, flat(ctx.target - st.pos))
		if math.abs(a) < 0.7 then
			c.steer = clamp1(c.steer * 0.3 + clamp1(a * 2.2) * 0.7)
		end
	end

	-- 5. flip at contact instead of driving into the ball; never as last man on a long ball, never during kickoff
	if o.flip and not ctx.kickoff and st.isOnGround and st.rot.up.z > 0.7 and ctx.ball.z < 220
		and dist < o.flipRange and fwd > -40 and math.abs(side) < 150
		and (not ctx.lastMan or dist < 260) then
		if Mech.startFlip(st, ctx.ball, ctx.tick) then runDodge(c, ctx.tick) end
	end
end

---------------------------------------------------------------- Nexto (neural bot)
-- Nexto by Rolv-Arild & co (github.com/Rolv-Arild/Necto, CC BY-NC-SA 4.0), ported to Luau in Nexto.lua.
-- Nexto.lua + nexto_weights.lua come from the workspace (Catware/BloxLeague/) or the repo.
-- Obs follows rlbot-support/Nexto/nexto_obs.py + rlgym_compat 1.0.2 exactly.
local NX
-- load at startup: executor APIs (readfile/crypt) aren't reachable from the game's input thread
local REPO = "https://raw.githubusercontent.com/jasonsmote-cell/Turb-bot/main/"
local DIR = "Catware/BloxLeague/"
-- cached workspace copy while its version stamp matches, else download and re-cache
-- bump when Nexto.lua or its weights change on the repo: caches without this stamp re-download once
local NEXTO_VERSION = "3"
local STAMP = DIR .. "nexto.version"
local fresh = isfile(STAMP) and readfile(STAMP) == NEXTO_VERSION
local function source(name)
	if fresh and isfile(DIR .. name) then return readfile(DIR .. name) end
	local src = game:HttpGet(REPO .. name)
	pcall(function()
		if not isfolder("Catware") then makefolder("Catware") end
		if not isfolder(DIR) then makefolder(DIR) end
		writefile(DIR .. name, src)
	end)
	return src
end
local nxOk, nxErr = pcall(function()
	NX = loadstring(source("Nexto.lua"))().load(loadstring(source("nexto_weights.lua"))())
	if not fresh then pcall(writefile, STAMP, NEXTO_VERSION) end -- only once both loaded fine
end)
if not nxOk then warn("[Catware] Nexto failed to load:", nxErr) end
local nx = { action = {0,0,0,0,0,0,0,0}, nextTick = 0, job = nil, kick = -1, lastGround = {}, ms = 0, lat = 0 }

-- rlbot kickoff taker rule: closest (within 10uu); ties -> "left goes"
local function kickoffTaker(me)
	local ball = P.arena.ball:GetState().pos
	local function d(car) return mag(flat(car:GetState().pos - ball)) end
	local mine, minD = d(me), math.huge
	for _, car in P.arena.cars do minD = math.min(minD, d(car)) end
	if math.abs(minD - mine) > 10 then return false end
	local mx = me:GetState().pos.x
	for _, car in P.arena.cars do
		if car ~= me and car.team == me.team and math.abs(d(car) - mine) <= 10 then
			local ox = car:GetState().pos.x
			local isLeft = me.team == 0 and ox < mx or me.team == 1 and ox > mx
			if not isLeft then return false end
		end
	end
	return true
end

local NX_BUDGET = 0.006 -- seconds of inference per frame
local function nextoControls(c, me, st)
	if not NX then error("Nexto isn't loaded (see the earlier warning)") end
	-- kick off a new decision every 8 ticks (tick skip 8, like the trained bot)
	if not nx.job and P.tick >= nx.nextTick then
		nx.nextTick = P.tick + 8
		local q, kv = NX.buildObs(P.arena, me, P.tick, nx)
		nx.job = coroutine.create(function()
			local t0 = os.clock()
			local startedAt = t0
			local used = 0
			NX.step = function()
				if os.clock() - t0 > NX_BUDGET then
					used += os.clock() - t0
					coroutine.yield()
					t0 = os.clock()
				end
			end
			local best = NX:forward(q, kv)
			used += os.clock() - t0
			nx.ms = used * 1000
			return best
		end)
	end
	if nx.job then
		local ok, best = coroutine.resume(nx.job)
		if not ok then nx.job = nil error(best) end
		if coroutine.status(nx.job) == "dead" then
			nx.job = nil
			nx.action = NX.ACTIONS[best]
			nx.lastBest = best
			-- what the next observation is extrapolated by: the inference time just measured + input/packet delay
			nx.lat = math.clamp(nx.ms / 1000 + 0.02, 0, 0.25)
		end
	end
	local a = nx.action
	-- scripted kickoff while the ball sits untouched at centre
	local ball = P.arena.ball:GetState()
	local kickoffPause = ball.pos.x == 0 and ball.pos.y == 0 and mag(ball.vel) == 0
	if kickoffPause then
		-- the ball resets before cars are moved to their spawns (replay + countdown), so keep
		-- re-picking the taker until we actually start driving, then lock the decision
		local speed = mag(st.vel)
		if speed < 5 then nx.kickArmed = true end -- parked at spawn for the countdown
		if nx.kickTick == nil then
			nx.kick = kickoffTaker(me) and 0 or -2
			if nx.kickArmed and speed > 5 then nx.kickTick = nx.kick == 0 and P.tick or false end -- false = locked, not taker
		end
		if nx.kick >= 0 then
			if nx.kickTick then nx.kick = P.tick - nx.kickTick end
			if NX.KICKOFF[nx.kick + 1] then a = NX.KICKOFF[nx.kick + 1] nx.action = a end
		end
	else
		nx.kick, nx.kickTick, nx.kickArmed = -1, nil, false
	end
	c.throttle, c.steer, c.pitch, c.yaw, c.roll = a[1], a[2], a[3], a[4], a[5]
	c.jump, c.boost, c.handbrake = a[6] > 0, a[7] > 0, a[8] > 0
	getgenv().BL_NX = { ms = nx.ms, lat = nx.lat, best = nx.lastBest, kick = nx.kick }
end

---------------------------------------------------------------- context for the mechanics layer
local OWN_GOAL, OPP_GOAL = vector.create(0, -5120, 321), vector.create(0, 5120, 321)
local function ctxFor(me, st)
	local own = me.team == 0 and OWN_GOAL or OPP_GOAL
	local target = me.team == 0 and OPP_GOAL or OWN_GOAL
	-- last man = nobody on our team is between us and our own net
	local lastMan, mine = true, mag(flat(st.pos - own))
	for _, car in P.arena.cars do
		if car ~= me and car.team == me.team and mag(flat(car:GetState().pos - own)) < mine then
			lastMan = false
			break
		end
	end
	local b = P.arena.ball:GetState()
	return {
		tick = P.tick, ball = b.pos, ballVel = b.vel, target = target, lastMan = lastMan,
		kickoff = nx.kick >= 0,
		opts = {
			aim = Toggles.MechAim.Value, flip = Toggles.AutoFlip.Value, recover = Toggles.AutoRecover.Value,
			wall = Toggles.MechWall.Value, boostSave = Toggles.MechBoost.Value,
			flipRange = Options.FlipRange.Value,
		},
	}
end

---------------------------------------------------------------- input hook
Input.Read = function(...)
	local c = origRead(...)
	local car = localCar()
	if not car or Library.Unloaded then return c end
	local st = car:GetState()

	if Toggles.NextoBot.Value then
		local ok, err = pcall(nextoControls, c, car, st)
		if not ok then nx.job = nil warn("[bl] nexto:", err) end
	elseif Toggles.AutoFlip.Value then
		local b = nearBall(st, Options.FlipRange.Value)
		if b then Mech.startFlip(st, b, P.tick) end
	end

	-- the mechanics layer always runs: it is the execution fix for whichever source produced c
	local ok, err = pcall(Mech.correct, c, st, ctxFor(car, st))
	if not ok then warn("[bl] mech:", err) end
	return c
end

---------------------------------------------------------------- visuals (Drawing)
local cam = workspace.CurrentCamera
local lines, texts = {}, {}
local landing = Drawing.new("Circle")
landing.Thickness, landing.NumSides, landing.Filled = 2, 24, false

local function line(i)
	local l = lines[i]
	if not l then l = Drawing.new("Line") l.Thickness = 2 lines[i] = l end
	return l
end
local function text(i)
	local t = texts[i]
	if not t then t = Drawing.new("Text") t.Size, t.Center, t.Outline = 16, true, true texts[i] = t end
	return t
end
local function screen(uu)
	local v, on = cam:WorldToViewportPoint(Coords.Pos(uu))
	return Vector2.new(v.X, v.Y), on
end

local function draw()
	local n = 0
	landing.Visible = false
	if Toggles.BallPath.Value and #path > 1 then
		local col = Options.PathColor.Value
		local prev, prevOn = screen(P.arena.ball:GetState().pos)
		for _, pt in path do
			local s, on = screen(pt.pos)
			if on and prevOn then
				n += 1
				local l = line(n)
				l.From, l.To, l.Color, l.Visible = prev, s, col, true
			end
			prev, prevOn = s, on
		end
		-- first ground contact after now
		for _, pt in path do
			if pt.pos.z < 110 then
				local s, on = screen(pt.pos)
				if on then
					landing.Position, landing.Radius, landing.Color, landing.Visible = s, 12, col, true
				end
				break
			end
		end
	end
	for i = n + 1, #lines do lines[i].Visible = false end

	local m = 0
	local me = localCar()
	if Toggles.BoostESP.Value and P and P.tick then
		for _, car in P.arena.cars do
			if car ~= me then
				local st = car.state
				local s, on = screen(car.body.pos * UU_PER_BT + vector.create(0, 0, 90))
				if on then
					m += 1
					local t = text(m)
					t.Text = string.format("%d", math.floor(st.boost))
					t.Color = (me and car.team == me.team) and Color3.fromRGB(90, 170, 255) or Color3.fromRGB(255, 110, 60)
					t.Position, t.Visible = s, true
				end
			end
		end
	end
	for i = m + 1, #texts do texts[i].Visible = false end
end

local frame = 0
local conn = RunService.RenderStepped:Connect(function()
	frame += 1
	local ok, err = pcall(function()
		local want = Toggles.BallPath.Value or Toggles.AutoFlip.Value
		-- the path re-sims up to 6s of physics; every other frame is enough and leaves the net some CPU
		if want and frame % 2 == 0 then
			predictBall(Options.PathSeconds.Value)
		elseif not want then
			table.clear(path)
		end
		draw()
	end)
	if not ok then warn("[bl]", err) end
end)

---------------------------------------------------------------- UI
local hasExecutor, executorName = pcall(identifyexecutor) -- nil or erroring on executors without it
local Window = Library:CreateWindow({ Title = "Catware", Footer = "Blox League | " .. (hasExecutor and executorName or "Unknown"), Icon = "cat", NotifySide = "Right", ShowCustomCursor = false })
local Tabs = {
	Main = Window:AddTab("Main", "car"),
	Visuals = Window:AddTab("Visuals", "eye"),
	["UI Settings"] = Window:AddTab("UI Settings", "settings"),
}

local Bot = Tabs.Main:AddLeftGroupbox("Bot", "bot")
Bot:AddToggle("NextoBot", { Text = "Nexto (neural bot)", Default = false, Risky = true, Tooltip = "Nexto by Rolv-Arild et al., CC BY-NC-SA 4.0." })
	:AddKeyPicker("NextoBotKey", { Default = "N", SyncToggleState = true, Mode = "Toggle", Text = "Nexto" })

local Assist = Tabs.Main:AddRightGroupbox("Mechanics", "hand-helping")
Assist:AddToggle("MechAim", { Text = "Analog aim assist", Default = true, Tooltip = "Steers onto the goal line when the ball is actually strikable" })
Assist:AddToggle("AutoFlip", { Text = "Flip into ball", Default = true, Tooltip = "Front/diagonal dodge at contact, skipped as last man" })
Assist:AddSlider("FlipRange", { Text = "Flip range (uu)", Default = 240, Min = 150, Max = 450, Rounding = 0 })
Assist:AddToggle("AutoRecover", { Text = "Air recovery", Default = true, Tooltip = "Lands you on wheels whenever the bot gives no air input" })
Assist:AddToggle("MechWall", { Text = "Wall escape", Default = true, Tooltip = "Drives off walls and ceiling toward a low ball" })
Assist:AddToggle("MechBoost", { Text = "Boost discipline", Default = true, Tooltip = "No boosting past top speed, saves the tank on a leaving ball" })

local Vis = Tabs.Visuals:AddLeftGroupbox("Ball", "circle")
Vis:AddToggle("BallPath", { Text = "Ball prediction path", Default = true })
	:AddColorPicker("PathColor", { Default = Color3.fromRGB(255, 220, 60) })
Vis:AddSlider("PathSeconds", { Text = "Prediction seconds", Default = 3, Min = 1, Max = 6, Rounding = 1 })
Tabs.Visuals:AddRightGroupbox("Cars", "car"):AddToggle("BoostESP", { Text = "Boost amount over cars", Default = true })

local MenuGroup = Tabs["UI Settings"]:AddLeftGroupbox("Menu", "wrench")
-- matches are a teleport away from the lobby; queue ourselves so Catware comes along
local AUTOLOAD_FLAG = "Catware/BloxLeague/autoload"
local LOADER = 'if not game:IsLoaded() then game.Loaded:Wait() end local p = "Catware/BloxLeague/catware.lua" '
	.. 'loadstring(isfile(p) and readfile(p) or game:HttpGet("' .. REPO .. 'catware.lua"))()'
MenuGroup:AddToggle("AutoLoad", { Text = "Auto-load after teleport", Default = isfile(AUTOLOAD_FLAG),
	Tooltip = "Re-runs Catware when you teleport into a match (and back to the lobby)" })
MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "RightShift", NoUI = true, Text = "Menu keybind" })
MenuGroup:AddButton("Unload", function() Library:Unload() end)
Library.ToggleKeybind = Options.MenuKeybind

-- toggling the bot off mid-decision must drop the half-run job, and a dodge must not survive the switch
Toggles.NextoBot:OnChanged(function(on)
	if not on then nx.job = nil end
	Mech.reset()
end)

Toggles.AutoLoad:OnChanged(function(on)
	if on then writefile(AUTOLOAD_FLAG, "1") elseif isfile(AUTOLOAD_FLAG) then delfile(AUTOLOAD_FLAG) end
end)
local queued = false
local teleportConn = LP.OnTeleport:Connect(function(state)
	if state == Enum.TeleportState.Started and Toggles.AutoLoad.Value and not queued then
		queued = true -- Started can fire again on retries; queue once
		queue_on_teleport(LOADER)
	end
end)

getgenv().CatwareBloxLeagueUnload = function() Library:Unload() end
Library:OnUnload(function()
	getgenv().CatwareBloxLeagueUnload = nil
	teleportConn:Disconnect()
	conn:Disconnect()
	Prediction.Step, Input.Read = origStep, origRead
	Mech.reset()
	nx.job = nil
	for _, d in lines do d:Remove() end
	for _, d in texts do d:Remove() end
	landing:Remove()
end)

ThemeManager:SetLibrary(Library)
SaveManager:SetLibrary(Library)
SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "MenuKeybind", "AutoLoad" }) -- AutoLoad lives in its own flag file
ThemeManager:SetFolder("Catware/BloxLeague") -- per-game themes: Catware/<Game>/{themes,settings}
SaveManager:SetFolder("Catware/BloxLeague")
SaveManager:BuildConfigSection(Tabs["UI Settings"])
ThemeManager:SetDefaultTheme(ThemeManager.BuiltInThemes["Catppuccin"][2]) -- a theme saved as default in the menu still wins
ThemeManager:ApplyToTab(Tabs["UI Settings"])
SaveManager:LoadAutoloadConfig()

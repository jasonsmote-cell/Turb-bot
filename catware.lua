-- Catware - Turbo Soccer (place 101880234193261). Obsidian UI, port of Catware - Blox League.
-- Turbo Soccer runs its own RocketSim-style sim (ReplicatedStorage.Shared.Sim, uu, 120Hz, same axis/sign
-- conventions as RocketSim). Matches go through Net.Prediction:step(controls) (server-authoritative, inputs
-- only); training/tutorial/free play runs a local single-car Sim.World. Both are hooked at their step.
-- Run: loadstring(game:HttpGet("https://raw.githubusercontent.com/jasonsmote-cell/Turb-bot/main/catware.lua"))()
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local LP = game:GetService("Players").LocalPlayer

if getgenv().CatwareTurboSoccerUnload then pcall(getgenv().CatwareTurboSoccerUnload) end

local Shared = RS:WaitForChild("Shared")
local Client = LP:WaitForChild("PlayerScripts"):WaitForChild("Client")
local Sim = Shared:WaitForChild("Sim")
local World = require(Sim:WaitForChild("World"))
local BallPrediction = require(Sim:WaitForChild("BallPrediction"))
local Prediction = require(Shared:WaitForChild("Net"):WaitForChild("Prediction"))
local Protocol = require(Shared.Net:WaitForChild("Protocol"))
local Units = require(Client:WaitForChild("Units"))
local Motion = require(Client:WaitForChild("Motion")) -- atMenu(): title screen (the menu backdrop is a live World)

local repo = "https://raw.githubusercontent.com/deividcomsono/Obsidian/main/"
local Library = loadstring(game:HttpGet(repo .. "Library.lua"))()
local ThemeManager = loadstring(game:HttpGet(repo .. "addons/ThemeManager.lua"))()
local SaveManager = loadstring(game:HttpGet(repo .. "addons/SaveManager.lua"))()
local Options, Toggles = Library.Options, Library.Toggles

---------------------------------------------------------------- live sim
-- live = { cars = {{car, team, index}}, ball, pads, tick, me = entry } of whichever sim stepped last
local live
local lastMatchAt = -1
local TICK = 1 / 120
local path = {} -- predicted ball {pos, t} every PATH_STRIDE ticks
local PATH_STRIDE = 4
local ballPred = BallPrediction.new()

local function fromMatch(P)
	local m = P.match
	local cars = {}
	for _, e in m.cars do
		if not e.vacant then table.insert(cars, e) end
	end
	return { cars = cars, ball = m.ball, pads = m.pads and m.pads.pads or {}, tick = m.tick, me = P.localIndex and m.cars[P.localIndex] }
end
local function fromWorld(w)
	local me = { car = w.car, team = 0, index = 1 }
	return { cars = { me }, ball = w.ball, pads = w.pads and w.pads.pads or {}, tick = w.tick, me = me }
end

-- Blox League-style read-only view of a car, so the control code below ports verbatim
local function stateOf(car)
	local b = car.body
	return {
		pos = b.pos, vel = b.vel, angVel = b.angVel, rot = { forward = b.fwd, right = b.right, up = b.up },
		boost = car.boost, isOnGround = car.isOnGround, isFlipping = car.isFlipping,
		hasFlipped = car.hasFlipped, hasDoubleJumped = car.hasDoubleJumped, isDemoed = car.isDemoed,
	}
end

local function predictBall(seconds)
	table.clear(path)
	if not live then return end
	ballPred:run(live.ball, seconds, PATH_STRIDE)
	for i = 2, #ballPred.points do
		table.insert(path, { pos = ballPred.points[i], t = ballPred.times[i] })
	end
end

---------------------------------------------------------------- helpers (signs from Sim.Car)
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
	local b = path[math.max(1, math.floor(0.15 / (PATH_STRIDE * TICK)))]
	if not b or st.rot.up.z < 0.7 then return nil end
	local d = b.pos - (st.pos + st.vel * 0.15)
	if b.pos.z > 220 or math.abs(d.z) > 200 then return nil end
	local fwd, side = vector.dot(d, st.rot.forward), vector.dot(d, st.rot.right)
	if mag(flat(d)) < within and fwd > -40 and math.abs(side) < 130 then return b.pos end
end

---------------------------------------------------------------- mechanics (correction layer)
-- The policy picks the intent; this fixes the execution. Runs after Nexto, never against it.
-- It never takes the decision away: no early return, no state that outlives its own dodge.
local Mech = {}
local dodge
local stuck = { until_ = 0, steer = 1, last = -999 }

function Mech.reset() dodge = nil stuck.until_ = 0 end

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
	local tick = ctx.tick

	if runDodge(c, tick) then return end

	local toBall = ctx.ball - st.pos
	local dist = mag(flat(toBall))
	local fwd = vector.dot(toBall, st.rot.forward)
	local side = vector.dot(toBall, st.rot.right)
	local speed = mag(flat(st.vel))

	-- unstick: pinned on the ground with no speed, reverse out on a cooldown
	if o.unstick and st.isOnGround and speed < 160 and tick * TICK - stuck.last > 2.2 then
		if stuck.until_ == 0 then
			stuck.until_ = tick + 60
			stuck.steer = math.random() > 0.5 and 1 or -1
			stuck.last = tick * TICK
		end
	end
	if stuck.until_ > 0 then
		if tick > stuck.until_ or speed > 380 then
			stuck.until_ = 0
		else
			c.throttle, c.steer, c.boost = -1, stuck.steer, false
			return
		end
	end

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

	-- 5. carry assist: only when the ball is above us and the policy is giving no air input of its own
	if o.carry and idleAir and not st.isOnGround and not st.isFlipping
		and dist < 260 and ctx.ball.z > st.pos.z + 20 then
		local dir = vector.normalize(ctx.ball + UP * 35 - st.pos)
		c.pitch = clamp1(c.pitch * 0.5 + 1.8 * math.atan2(vector.dot(dir, st.rot.up), vector.dot(dir, st.rot.forward)) * 0.5)
		c.yaw = clamp1(c.yaw * 0.5 + 1.5 * math.atan2(vector.dot(dir, st.rot.right), vector.dot(dir, st.rot.forward)) * 0.5)
		if dist < 200 and st.boost > 8 then c.boost = true end
	end

	-- 6. flip at contact instead of driving into the ball; never as last man on a long ball, never during kickoff
	if o.flip and not ctx.kickoff and st.isOnGround and st.rot.up.z > 0.7 and ctx.ball.z < 220
		and dist < o.flipRange and fwd > -40 and math.abs(side) < 150
		and (not ctx.lastMan or dist < 260) then
		if Mech.startFlip(st, ctx.ball, tick) then runDodge(c, tick) end
	end
end

---------------------------------------------------------------- Nexto (neural bot)
-- Nexto by Rolv-Arild & co (github.com/Rolv-Arild/Necto, CC BY-NC-SA 4.0), Luau port shared with Blox League.
local NX
local REPO = "https://raw.githubusercontent.com/jasonsmote-cell/Turb-bot/main/"
local DIR = "Catware/TurboSoccer/"
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
local nx = { action = {0,0,0,0,0,0,0,0}, nextTick = 0, job = nil, kick = -1, lastGround = {}, spent = 0, deadline = 0, ms = 0, lat = 0 }

-- Nexto.lua speaks the Blox League arena API; wrap the live sim in it
local function nxArena()
	local cars, me = {}, nil
	for _, e in live.cars do
		local w = { team = e.team, id = e.index, GetState = function() return stateOf(e.car) end }
		table.insert(cars, w)
		if e == live.me then me = w end
	end
	local ball = live.ball.body
	return {
		cars = cars, boostPads = live.pads,
		ball = { GetState = function() return { pos = ball.pos, vel = ball.vel, angVel = ball.angVel } end },
	}, me
end

local function kickoffTaker(arena, me)
	local ball = arena.ball:GetState().pos
	local function d(car) return mag(flat(car:GetState().pos - ball)) end
	local mine, minD = d(me), math.huge
	for _, car in arena.cars do minD = math.min(minD, d(car)) end
	if math.abs(minD - mine) > 10 then return false end
	local mx = me:GetState().pos.x
	for _, car in arena.cars do
		if car ~= me and car.team == me.team and math.abs(d(car) - mine) <= 10 then
			local ox = car:GetState().pos.x
			local isLeft = me.team == 0 and ox < mx or me.team == 1 and ox > mx
			if not isLeft then return false end
		end
	end
	return true
end

-- seconds of inference per frame: the game can run several ticks in one frame when catching up,
-- so the budget is shared by all of them (nx.spent resets on RenderStepped)
local NX_BUDGET = 0.006
if NX then
	NX.step = function()
		if os.clock() > nx.deadline then coroutine.yield() end
	end
end

local function nextoControls(c, st)
	if not NX then error("Nexto isn't loaded (see the earlier warning)") end
	local tick = live.tick
	local arena, me
	if nx.pads ~= live.pads then nx.pads, nx.padMap = live.pads, nil end -- new sim, re-match pads
	if not nx.job and tick >= nx.nextTick then
		nx.nextTick = tick + 8
		arena, me = nxArena()
		local q, kv = NX.buildObs(arena, me, tick, nx)
		nx.job = coroutine.create(function() return NX:forward(q, kv) end)
	end
	if nx.job and nx.spent < NX_BUDGET then
		local t0 = os.clock()
		nx.deadline = t0 + NX_BUDGET - nx.spent
		local ok, best = coroutine.resume(nx.job)
		nx.spent += os.clock() - t0
		if not ok then nx.job = nil error(best) end
		if coroutine.status(nx.job) == "dead" then
			nx.job = nil
			nx.action = NX.ACTIONS[best]
			nx.lastBest = best
			nx.ms = nx.spent * 1000
			-- what the next observation is extrapolated by: inference time just measured + input/packet delay
			nx.lat = math.clamp(nx.ms / 1000 + 0.02, 0, 0.25)
		end
	end
	local a = nx.action
	local ball = live.ball.body
	local kickoffPause = ball.pos.x == 0 and ball.pos.y == 0 and mag(ball.vel) == 0
	if kickoffPause then
		local speed = mag(st.vel)
		if speed < 5 then nx.kickArmed = true end
		if nx.kickTick == nil then
			if not arena then arena, me = nxArena() end
			nx.kick = kickoffTaker(arena, me) and 0 or -2
			if nx.kickArmed and speed > 5 then nx.kickTick = nx.kick == 0 and tick or false end
		end
		if nx.kick >= 0 then
			if nx.kickTick then nx.kick = tick - nx.kickTick end
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
	local lastMan, mine = true, mag(flat(st.pos - own))
	for _, e in live.cars do
		if e ~= me and e.team == me.team and mag(flat(e.car.body.pos - own)) < mine then
			lastMan = false
			break
		end
	end
	local b = live.ball.body
	return {
		tick = live.tick, ball = b.pos, ballVel = b.vel, target = target, lastMan = lastMan,
		kickoff = nx.kick >= 0,
		opts = {
			aim = Toggles.MechAim.Value, flip = Toggles.AutoFlip.Value, recover = Toggles.AutoRecover.Value,
			wall = Toggles.MechWall.Value, boostSave = Toggles.MechBoost.Value, unstick = Toggles.MechUnstick.Value,
			carry = Toggles.MechCarry.Value, flipRange = Options.FlipRange.Value,
		},
	}
end

---------------------------------------------------------------- step hooks
-- c: the controls about to be simulated for our car this tick
local function drive(c)
	local me = live.me
	if not me or Library.Unloaded then return end
	local st = stateOf(me.car)

	if Toggles.NextoBot.Value then
		local ok, err = pcall(nextoControls, c, st)
		if not ok then nx.job = nil warn("[Catware] nexto:", err) end
	elseif Toggles.AutoFlip.Value then
		local b = nearBall(st, Options.FlipRange.Value)
		if b then Mech.startFlip(st, b, live.tick) end
	end

	-- always runs: it is the execution fix for whichever source produced c
	local ok, err = pcall(Mech.correct, c, st, ctxFor(me, st))
	if not ok then warn("[Catware] mech:", err) end
end

local origPStep, origWStep = Prediction.step, World.step
Prediction.step = function(self, controls, ...)
	lastMatchAt = os.clock()
	live = fromMatch(self)
	-- only while the ball is live: goal replays, countdowns and the end screen keep stepping too
	if controls and self.match.phase == "play" then
		drive(controls)
		Protocol.quantize(controls) -- same rounding the game applies before step, so server and history agree
	end
	return origPStep(self, controls, ...)
end
World.step = function(self, ...)
	-- the menu/training world can keep ticking during a match; the match wins
	if os.clock() - lastMatchAt > 0.25 then
		if Motion.atMenu() then
			live = nil
		else
			live = fromWorld(self)
			drive(self.car.controls)
		end
	end
	return origWStep(self, ...)
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
	local v, on = cam:WorldToViewportPoint(Units.pos(uu))
	return Vector2.new(v.X, v.Y), on
end

local function draw()
	local n = 0
	landing.Visible = false
	if Toggles.BallPath.Value and #path > 1 then
		local col = Options.PathColor.Value
		local prev, prevOn = screen(live.ball.body.pos)
		for _, pt in path do
			local s, on = screen(pt.pos)
			if on and prevOn then
				n += 1
				local l = line(n)
				l.From, l.To, l.Color, l.Visible = prev, s, col, true
			end
			prev, prevOn = s, on
		end
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
	local me = live and live.me
	if Toggles.BoostESP.Value and live then
		for _, e in live.cars do
			if e ~= me and not e.car.isDemoed then
				local s, on = screen(e.car.body.pos + vector.create(0, 0, 90))
				if on then
					m += 1
					local t = text(m)
					t.Text = string.format("%d", math.floor(e.car.boost))
					t.Color = (me and e.team == me.team) and Color3.fromRGB(90, 170, 255) or Color3.fromRGB(255, 110, 60)
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
		-- the path re-sims the ball; every other frame is enough and leaves the net some CPU
		if want and frame % 2 == 0 then
			predictBall(Options.PathSeconds.Value)
		elseif not want then
			table.clear(path)
		end
		draw()
	end)
	nx.spent = 0
	if not ok then warn("[Catware]", err) end
end)

---------------------------------------------------------------- UI
local hasExecutor, executorName = pcall(identifyexecutor)
local Window = Library:CreateWindow({ Title = "Catware", Footer = "Turbo Soccer | " .. (hasExecutor and executorName or "Unknown"), Icon = "cat", NotifySide = "Right", ShowCustomCursor = false })
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
Assist:AddToggle("MechUnstick", { Text = "Unstick", Default = true, Tooltip = "Reverses out when pinned with no speed" })
Assist:AddToggle("MechCarry", { Text = "Carry assist", Default = true, Tooltip = "Nudges a ball above you on target when the bot gives no air input" })

local Vis = Tabs.Visuals:AddLeftGroupbox("Ball", "circle")
Vis:AddToggle("BallPath", { Text = "Ball prediction path", Default = true })
	:AddColorPicker("PathColor", { Default = Color3.fromRGB(255, 220, 60) })
Vis:AddSlider("PathSeconds", { Text = "Prediction seconds", Default = 2, Min = 1, Max = 6, Rounding = 1 })
Tabs.Visuals:AddRightGroupbox("Cars", "car"):AddToggle("BoostESP", { Text = "Boost amount over cars", Default = true })

local MenuGroup = Tabs["UI Settings"]:AddLeftGroupbox("Menu", "wrench")
-- queue ourselves on teleport (server hops, private servers, tournaments) so Catware comes along
local AUTOLOAD_FLAG = DIR .. "autoload"
local LOADER = 'if not game:IsLoaded() then game.Loaded:Wait() end local p = "' .. DIR .. 'catware.lua" '
	.. 'loadstring(isfile(p) and readfile(p) or game:HttpGet("' .. REPO .. 'catware.lua"))()'
MenuGroup:AddToggle("AutoLoad", { Text = "Auto-load after teleport", Default = isfile(AUTOLOAD_FLAG),
	Tooltip = "Re-runs Catware when you teleport to another Turbo Soccer server" })
MenuGroup:AddLabel("Menu bind"):AddKeyPicker("MenuKeybind", { Default = "RightShift", NoUI = true, Text = "Menu keybind" })
MenuGroup:AddButton("Unload", function() Library:Unload() end)
Library.ToggleKeybind = Options.MenuKeybind

-- toggling the bot off mid-decision must drop the half-run job, and a dodge must not survive the switch
Toggles.NextoBot:OnChanged(function(on)
	if not on then nx.job = nil end
	Mech.reset()
end)

Toggles.AutoLoad:OnChanged(function(on)
	if on then
		if not isfolder("Catware") then makefolder("Catware") end
		if not isfolder(DIR) then makefolder(DIR) end
		writefile(AUTOLOAD_FLAG, "1")
	elseif isfile(AUTOLOAD_FLAG) then
		delfile(AUTOLOAD_FLAG)
	end
end)
local queued = false
local teleportConn = LP.OnTeleport:Connect(function(state)
	if state == Enum.TeleportState.Started and Toggles.AutoLoad.Value and not queued then
		queued = true -- Started can fire again on retries; queue once
		queue_on_teleport(LOADER)
	end
end)

getgenv().CatwareTurboSoccerUnload = function() Library:Unload() end
Library:OnUnload(function()
	getgenv().CatwareTurboSoccerUnload = nil
	teleportConn:Disconnect()
	conn:Disconnect()
	Prediction.step, World.step = origPStep, origWStep
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
ThemeManager:SetFolder("Catware/TurboSoccer")
SaveManager:SetFolder("Catware/TurboSoccer")
SaveManager:BuildConfigSection(Tabs["UI Settings"])
ThemeManager:SetDefaultTheme(ThemeManager.BuiltInThemes["Catppuccin"][2])
ThemeManager:ApplyToTab(Tabs["UI Settings"])
SaveManager:LoadAutoloadConfig()

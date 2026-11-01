-- mech.lua - mechanical correction layer for Catware - Blox League.
-- The policy picks the intent; this fixes the execution. Runs after Nexto, never against it.
local Mech = {}

local UP = vector.create(0, 0, 1)
local TICK = 1 / 120
local function clamp1(x) return math.clamp(x, -1, 1) end
local function flat(v) return vector.create(v.x, v.y, 0) end
local function mag(v) return vector.magnitude(v) end
local function angleTo(rot, dir) return math.atan2(vector.dot(dir, rot.right), vector.dot(dir, rot.forward)) end

local dodge
function Mech.reset() dodge = nil end
function Mech.busy() return dodge ~= nil end

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

-- c: controls to mutate. ctx: {tick, ball, ballVel, target, lastMan, opts}
function Mech.correct(c, st, ctx)
	if not (st and st.rot and ctx) then return end
	local o = ctx.opts or {}
	local tick = ctx.tick

	-- a flip owns the controls outright
	if runDodge(c, tick) then return end

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

	-- 3. off the wall: point the nose down and forward, the policy likes to sit up there
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

	-- 5. flip at contact instead of driving into the ball, but never as last man on a long ball
	if o.flip and st.isOnGround and st.rot.up.z > 0.7 and ctx.ball.z < 220
		and dist < o.flipRange and fwd > -40 and math.abs(side) < 150
		and (not ctx.lastMan or dist < 260) then
		if Mech.startFlip(st, ctx.ball, tick) then runDodge(c, tick) end
	end
end

return Mech

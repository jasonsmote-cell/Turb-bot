-- Cronus (github.com/devynfisher10/Cronus) ported to Luau. Freestyle 1v1 PPO bot, AdvancedObs, 228 actions.
-- Forward pass only: no training. Policy net is 512-256-256 LeakyReLU(0.01) -> 228 logits, argmax.
local Cronus = {}

local vcreate, vzero = vector.create, vector.zero

-- rlgym AdvancedObs: POS_STD 2300, ANG_STD 5.5, 70 numbers.
local POS_STD, ANG_STD = 2300, 5.5
local OBS_DIM = 70
Cronus.OBS_DIM = OBS_DIM

local function packRows(buf, off, rows, cols)
	local n3 = math.ceil(cols / 3)
	local out = table.create(rows * n3)
	for r = 0, rows - 1 do
		local base = off + r * cols
		for j = 0, n3 - 1 do
			local c = j * 3
			local a = buffer.readf32(buf, (base + c) * 4)
			local b = c + 1 < cols and buffer.readf32(buf, (base + c + 1) * 4) or 0
			local d = c + 2 < cols and buffer.readf32(buf, (base + c + 2) * 4) or 0
			out[r * n3 + j + 1] = vcreate(a, b, d)
		end
	end
	return { w = out, rows = rows, n3 = n3 }
end
local function readVec(buf, off, n)
	local t = table.create(n)
	for i = 1, n do t[i] = buffer.readf32(buf, (off + i - 1) * 4) end
	return t
end
local function pack(x, n)
	local n3 = math.ceil(n / 3)
	local p = table.create(n3)
	for j = 0, n3 - 1 do
		local c = j * 3
		p[j + 1] = vcreate(x[c + 1] or 0, x[c + 2] or 0, x[c + 3] or 0)
	end
	return p
end

local SLOPE = 0.01 -- torch LeakyReLU default
local function linear(L, xp, bias, out)
	out = out or table.create(L.rows)
	local w, n3 = L.w, L.n3
	for r = 0, L.rows - 1 do
		local acc = vzero
		local base = r * n3
		for j = 1, n3 do acc += w[base + j] * xp[j] end
		local s = acc.x + acc.y + acc.z + bias[r + 1]
		if s < 0 then s = s * SLOPE end
		out[r + 1] = s
	end
	return out
end

function Cronus.load(w)
	local buf = buffer.fromstring(crypt.base64decode(w.data))
	if w.obs_dim ~= OBS_DIM then
		error(("Cronus obs mismatch: weights want %d, builder makes %d"):format(w.obs_dim, OBS_DIM))
	end
	local man = w.off
	local function M(n) local e = man[n] return packRows(buf, e[1], e[2], e[3]) end
	local function V(n) local e = man[n] return readVec(buf, e[1], e[2]) end
	local self = {}
	self.W0, self.b0 = M("W0"), V("b0")
	self.W1, self.b1 = M("W1"), V("b1")
	self.W2, self.b2 = M("W2"), V("b2")
	self.Wo, self.bo = M("Wo"), V("bo")
	if self.Wo.rows ~= 228 then error(("action head is %d, expected 228"):format(self.Wo.rows)) end
	return setmetatable(self, { __index = Cronus })
end

-- obs: 70 numbers. Returns best action index (1-based), logits.
function Cronus:forward(obs)
	local x = linear(self.W0, pack(obs, OBS_DIM), self.b0)
	x = linear(self.W1, pack(x, 512), self.b1)
	x = linear(self.W2, pack(x, 256), self.b2)
	local logits = linear(self.Wo, pack(x, 256), self.bo)
	local best, bestV = 1, -math.huge
	for i = 1, #logits do
		if logits[i] > bestV then best, bestV = i, logits[i] end
	end
	return best, logits
end

---------------------------------------------------------------- observation (rlgym AdvancedObs)
Cronus.PADS = { -- rlgym BOOST_LOCATIONS order
	{0,-4240},{-1792,-4184},{1792,-4184},{-3072,-4096},{3072,-4096},{-940,-3308},{940,-3308},{0,-2816},
	{-3584,-2484},{3584,-2484},{-1788,-2300},{1788,-2300},{-2048,-1036},{0,-1024},{2048,-1036},{-3584,0},
	{-1024,0},{1024,0},{3584,0},{-2048,1036},{0,1024},{2048,1036},{-1788,2300},{1788,2300},{-3584,2484},
	{3584,2484},{0,2816},{-940,3310},{940,3308},{-3072,4096},{3072,4096},{-1792,4184},{1792,4184},{0,4240},
}
-- pad i mirrors to pad PAD_MIRROR[i] (point symmetry through the centre)
Cronus.PAD_MIRROR = {}
for i = 1, 34 do Cronus.PAD_MIRROR[i] = 35 - i end

-- arena: Sim arena (cars with GetState, ball with GetState, boostPads). me: our car.
-- mem: {action, padMap, padArena, lat}. lat shifts everything along its velocity by the measured latency.
function Cronus.buildObs(arena, me, mem)
	local invert = me.team == 1
	local lat = mem.lat or 0
	if mem.padArena ~= arena then mem.padArena, mem.padMap = arena, nil end
	if not mem.padMap then
		mem.padMap = {}
		for i, L in Cronus.PADS do
			local best, bd
			for j, pad in arena.boostPads do
				local d = (pad.pos.x - L[1]) ^ 2 + (pad.pos.y - L[2]) ^ 2
				if not bd or d < bd then best, bd = j, d end
			end
			mem.padMap[i] = best
		end
	end

	local st = me:GetState()
	local p, v, w, f, u = st.pos, st.vel, st.angVel, st.rot.forward, st.rot.up
	local b = arena.ball:GetState()
	local o = table.create(OBS_DIM)
	local s = invert and -1 or 1
	local function put(i, x) o[i] = x end

	-- ball (world or inverted frame)
	put(1, b.pos.x * s / POS_STD) put(2, b.pos.y * s / POS_STD) put(3, b.pos.z / POS_STD)
	put(4, b.vel.x * s / POS_STD) put(5, b.vel.y * s / POS_STD) put(6, b.vel.z / POS_STD)
	put(7, b.angVel.x * s / ANG_STD) put(8, b.angVel.y * s / ANG_STD) put(9, b.angVel.z / ANG_STD)
	-- boost pads (active 1/0, mirrored for orange)
	for i = 1, 34 do
		local pad = arena.boostPads[mem.padMap[invert and Cronus.PAD_MIRROR[i] or i]]
		put(9 + i, pad and pad.isActive and 1 or 0)
	end
	-- our car
	put(44, p.x * s / POS_STD) put(45, p.y * s / POS_STD) put(46, p.z / POS_STD)
	put(47, v.x * s / POS_STD) put(48, v.y * s / POS_STD) put(49, v.z / POS_STD)
	put(50, w.x * s / ANG_STD) put(51, w.y * s / ANG_STD) put(52, w.z / ANG_STD)
	put(53, f.x * s) put(54, f.y * s) put(55, f.z)
	put(56, u.x * s) put(57, u.y * s) put(58, u.z)
	put(59, st.boost / 100)
	put(60, st.isOnGround and 1 or 0)
	put(61, (st.hasFlipped or st.hasDoubleJumped) and 0 or 1)
	put(62, st.isDemoed and 1 or 0)
	for i = 1, 8 do put(62 + i, mem.action[i]) end

	-- latency: shift the ball and us forward, then re-derive nothing else (AdvancedObs has no relative terms)
	o[1] = (b.pos.x + b.vel.x * lat) * s / POS_STD
	o[2] = (b.pos.y + b.vel.y * lat) * s / POS_STD
	o[3] = (b.pos.z + b.vel.z * lat) / POS_STD
	o[44] = (p.x + v.x * lat) * s / POS_STD
	o[45] = (p.y + v.y * lat) * s / POS_STD
	o[46] = (p.z + v.z * lat) / POS_STD
	return o
end

-- scripted speed-flip kickoff (Cronus ships none; same shape as Nexto's)
Cronus.KICKOFF = {}
do
	local function add(n, a) for _ = 1, n * 4 do table.insert(Cronus.KICKOFF, a) end end
	add(11, {1,0,0,0,0,0,1,0}) add(4, {1,-1,0,0,0,0,1,0}) add(2, {1,0,0,0,0,1,1,0}) add(1, {1,0,0,0,0,0,1,0})
	add(1, {1,0,-0.7,0.8,0,1,1,0}) add(13, {1,0,1,0,0,0,1,0}) add(10, {1,0,0.5,0,1,0,0,0})
end

-- 228-action table, exact sprinter_parser.LookupAction order
do
	local A = {}
	for _, th in { -1, 0, 1 } do
		for _, st in { -1, 0, 1 } do
			for _, bo in { 0, 1 } do
				for _, hb in { 0, 1 } do
					if not (bo == 1 and th ~= 1) then
						table.insert(A, { th ~= 0 and th or bo, st, 0, st, 0, 0, bo, hb })
					end
				end
			end
		end
	end
	for _, p in { -1, 0, 1 } do
		for _, y in { -1, 0, 1 } do
			for _, r in { -1, 0, 1 } do
				for _, j in { 0, 1 } do
					for _, bo in { 0, 1 } do
						for _, hb in { 0, 1 } do
							if not (p == 0 and r == 0 and j == 0) then
								table.insert(A, { bo, y, p, y, r, j, bo, hb })
							end
						end
					end
				end
			end
		end
	end
	Cronus.ACTIONS = A
end

return Cronus

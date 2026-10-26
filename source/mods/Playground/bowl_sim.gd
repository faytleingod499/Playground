extends Reference

# Playground: the bowling physics.
#
# A small flat (top-down) simulation of one roll: the ball, the ten pins, and whatever the pins knock into.
# It uses a fixed time step and no randomness, so every player with the mod who runs the same roll from
# the same starting pins gets the same result, and everybody sees the same pins fall.
#
# Lane space: u is across the lane (+ is to the bowler's right), d is along it from the foul line.

const LANE_HALF = 1.05        # half the width you can roll on; past it the ball drops in the gutter
const GUTTER_AT = 1.19        # where a ball in the gutter runs
const HEAD = 14.0             # the foul line to the head pin
const ROW = 0.528             # between rows of pins
const SPACING = 0.61          # between neighbouring pins in a row
const WALL_U = 1.45           # the walls at either side of the pin deck
const BACK = 16.2             # the back of the pit, and the end of the pin deck
const BALL_R = 0.22
const PIN_R = 0.12
const HIT_R = 0.17            # a pin that's flying or lying hits others with this reach
const BALL_MASS = 7.0
const PIN_MASS = 1.6
const BOUNCE = 0.5
const DT = 1.0 / 120.0
const DRAG = 3.2              # per second, how fast a knocked pin slows
const SLIDE = 3.0             # plus this much m/s^2
const FALL_TIME = 0.45        # a hit pin takes this long to go over
const MAX_TIME = 7.0
const HOOK = 0.04             # how much a full spin turns the ball, in radians per metre rolled, once it's out of the oil
const HOOK_FROM = 4.5         # the first stretch of the lane is oily: the ball runs straight, then hooks
const ALL = 1023

var ball = Vector2()
var ball_v = Vector2()
var spin = 0.0                # -1 (hooks left) to 1 (hooks right)
var touched = false           # the ball has hit a pin, so it stops curving
var ball_in = false           # ball is in play (on the lane or in the gutter)
var gutter = false
var ball_gone = false         # past the pins
var pin_p = []                # Vector2 each
var pin_v = []                # Vector2 each
var pin_state = []            # 0 standing, 1 knocked
var pin_t = []                # seconds since each was hit
var pin_dir = []              # the way each fell
var pin_speed0 = []           # how hard it was hit
var time = 0.0
var done = true
var knocked_now = 0           # how many went over in this roll so far
var events = []               # [time, 0 ball hit a pin | 1 pin hit a pin, where], for the sounds


# how much the ball bites at a distance down the lane: nothing in the oil, then more and more
static func _oil(d):
	return clamp((d - HOOK_FROM) / (HEAD - HOOK_FROM), 0.0, 1.0)


# where a ball will go with no pins in the way: [position, heading] every `spacing` metres down the lane
static func path_points(u0, angle, spin_, spacing, reach):
	var pts = []
	var pos = Vector2(clamp(u0, -0.95, 0.95), 0.0)
	var a = angle
	var ds = 0.02
	var next = 0.0
	var gut = false
	while pos.y < reach:
		if pos.y >= next:
			pts.append([pos, a])
			next += spacing
		if not gut and abs(pos.x) > LANE_HALF + 0.02:
			gut = true
			a = 0.0
			pos.x = GUTTER_AT * sign(pos.x)
		if not gut:
			a += spin_ * HOOK * _oil(pos.y) * ds
		pos += Vector2(sin(a), cos(a)) * ds
	return pts


static func pin_home(i):
	# rows of 1, 2, 3 and 4; pin 0 is the head pin, the back row is 6 to 9
	var row = 0
	var first = 0
	for r in range(4):
		if i < first + r + 1:
			row = r
			break
		first += r + 1
	var k = i - first
	return Vector2((k - row / 2.0) * SPACING, HEAD + row * ROW)


func start(mask, u0, angle, speed, spin_ = 0.0):
	pin_p = []
	pin_v = []
	pin_state = []
	pin_t = []
	pin_dir = []
	pin_speed0 = []
	for i in range(10):
		pin_p.append(pin_home(i))
		pin_v.append(Vector2())
		pin_state.append(0 if (mask >> i) & 1 == 1 else 2)   # 2: not there at all
		pin_t.append(0.0)
		pin_dir.append(Vector2(0, 1))
		pin_speed0.append(0.0)
	ball = Vector2(clamp(u0, -0.95, 0.95), 0.0)
	ball_v = Vector2(sin(angle), cos(angle)) * speed
	spin = clamp(spin_, -1.0, 1.0)
	touched = false
	ball_in = true
	gutter = false
	ball_gone = false
	time = 0.0
	done = false
	knocked_now = 0
	events = []


func standing_mask():
	var m = 0
	for i in range(10):
		if pin_state[i] == 0:
			m |= 1 << i
	return m


func step():
	if done:
		return
	time += DT
	# the ball
	if ball_in and not ball_gone:
		if not gutter and not touched and spin != 0.0:
			var turn = spin * HOOK * _oil(ball.y) * ball_v.length() * DT
			ball_v = ball_v.rotated(-turn)
		ball += ball_v * DT
		if not gutter and abs(ball.x) > LANE_HALF + 0.02:
			gutter = true
			ball_v = Vector2(0, max(ball_v.y, 1.0))
			ball.x = GUTTER_AT * sign(ball.x)
		if gutter:
			ball.x = GUTTER_AT * sign(ball.x) if ball.x != 0 else GUTTER_AT
		if ball.y > BACK:
			ball_gone = true
		if not gutter:
			for i in range(10):
				if pin_state[i] == 0:
					_ball_hits(i)
	# the pins
	for i in range(10):
		if pin_state[i] != 1:
			continue
		pin_t[i] += DT
		var v = pin_v[i]
		var sp = v.length()
		if sp > 0.0:
			var slow = sp - (sp * DRAG + SLIDE) * DT
			v = v * (max(slow, 0.0) / sp)
			pin_v[i] = v
			pin_p[i] += v * DT
		# the walls and the back
		var p = pin_p[i]
		if p.y > BACK - 0.1:
			p.y = BACK - 0.1
			pin_v[i].y = 0.0
		if abs(p.x) > WALL_U:
			p.x = WALL_U * sign(p.x)
			pin_v[i].x = 0.0
		pin_p[i] = p
	# the ones flying around hit the ones still standing
	for i in range(10):
		if pin_state[i] == 1 and pin_t[i] < 1.4 and pin_v[i].length() > 0.4:
			for j in range(10):
				if pin_state[j] == 0:
					_pin_hits(i, j)
	# finished: nothing is moving any more, or too long
	var busy = false
	if ball_in and not ball_gone:
		busy = true
	for i in range(10):
		if pin_state[i] == 1 and (pin_v[i].length() > 0.05 or pin_t[i] < FALL_TIME):
			busy = true
	if not busy or time > MAX_TIME:
		done = true


func _ball_hits(i):
	var d = pin_p[i] - ball
	var dist = d.length()
	if dist >= BALL_R + PIN_R or dist < 0.0001:
		return
	var n = d / dist
	var rel = ball_v.dot(n)
	if rel <= 0.0:
		return
	touched = true
	var j = (1.0 + BOUNCE) * rel / (1.0 / BALL_MASS + 1.0 / PIN_MASS)
	ball_v -= n * (j / BALL_MASS)
	_knock(i, n * (j / PIN_MASS))
	events.append([time, 0, pin_p[i]])


func _pin_hits(i, j):
	var d = pin_p[j] - pin_p[i]
	var dist = d.length()
	if dist >= HIT_R + PIN_R or dist < 0.0001:
		return
	var n = d / dist
	var rel = pin_v[i].dot(n)
	if rel <= 0.0:
		return
	var imp = (1.0 + BOUNCE) * rel / 2.0     # equal masses
	pin_v[i] -= n * imp
	_knock(j, n * imp)
	events.append([time, 1, pin_p[j]])


func _knock(i, v):
	pin_state[i] = 1
	pin_v[i] = v
	pin_t[i] = 0.0
	pin_speed0[i] = v.length()
	pin_dir[i] = v.normalized() if v.length() > 0.001 else Vector2(0, 1)
	knocked_now += 1


# --- scoring (ten pin bowling) ---

# rolls: an array of pin counts, one per ball. Returns the frames: [{"rolls": [..], "score": total or -1}]
static func frames_of(rolls):
	var frames = []
	var i = 0
	for f in range(10):
		var fr = {"rolls": [], "score": -1}
		if i >= rolls.size():
			frames.append(fr)
			continue
		if f < 9:
			if rolls[i] == 10:
				fr["rolls"] = [10]
				fr["bonus"] = 2
				i += 1
			else:
				fr["rolls"] = [rolls[i]]
				i += 1
				if i < rolls.size():
					fr["rolls"].append(rolls[i])
					i += 1
					fr["bonus"] = 1 if fr["rolls"][0] + fr["rolls"][1] == 10 else 0
		else:
			while i < rolls.size() and fr["rolls"].size() < 3:
				fr["rolls"].append(rolls[i])
				i += 1
				var r = fr["rolls"]
				if r.size() == 2 and r[0] != 10 and r[0] + r[1] < 10:
					break
		frames.append(fr)
	# scores
	var total = 0
	var pos = 0
	for f in range(10):
		var fr = frames[f]
		var r = fr["rolls"]
		if r.empty():
			break
		var n = r.size()
		var sc = -1
		if f < 9:
			if r[0] == 10:
				if pos + 2 < rolls.size():
					sc = 10 + rolls[pos + 1] + rolls[pos + 2]
				pos += 1
			else:
				if n == 2:
					if r[0] + r[1] == 10:
						if pos + 2 < rolls.size():
							sc = 10 + rolls[pos + 2]
					else:
						sc = r[0] + r[1]
				pos += n
		else:
			var sum = 0
			for x in r:
				sum += x
			var need = 2
			if n >= 1 and r[0] == 10:
				need = 3
			elif n >= 2 and r[0] + r[1] == 10:
				need = 3
			if n >= need:
				sc = sum
			pos += n
		if sc >= 0 and total >= 0:
			total += sc
			fr["score"] = total
		else:
			total = -1
	return frames


# true when the rolls so far make a finished game
static func game_over(rolls):
	var fr = frames_of(rolls)[9]
	var r = fr["rolls"]
	if r.size() < 2:
		return false
	if r[0] == 10 or r[0] + r[1] == 10:
		return r.size() >= 3
	return true


# which pins are up for the next ball: all ten after a strike, a spare or a new frame, else the ones still
# standing after the last ball
static func next_mask(rolls, standing_after_last):
	var f = 0
	var b = 0
	var up = 10
	for r in rolls:
		up -= r
		if f < 9:
			if b == 0 and up > 0:
				b = 1
			else:
				f += 1
				b = 0
				up = 10
		else:
			b += 1
			if up <= 0:
				up = 10
	return ALL if up >= 10 else standing_after_last

extends Node

# Playground: bowling
#
# Anyone with the mod can lay down a bowling lane (Playground menu > Place a bowling lane): it runs away from
# you from just in front of your feet, with ten pins at the far end. Walk onto the approach and press E to
# bowl. A and D slide you across the lane, the left and right arrow keys turn your aim, and Space starts the
# power bar; Space again rolls. Ten frames, the usual scoring, strikes and spares. A pin that falls knocks
# over the ones behind it. Every roll is worked out by every player's mod from the same starting pins with
# the same fixed-step physics (bowl_sim.gd), so everybody sees the same pins fall, and the scores are kept
# by the one bowling and shown to everyone near the lane.
#
# Lobby member data:
#   "playground_lane":   1;<x>;<y>;<z>;<yaw>;<zone>;<zone owner>             my lane, where it lies
#   "playground_bowl":   1;<lane owner>;<n>;<pins up>;<u*100>;<angle*1000>;<speed*10>    my latest roll
#   "playground_bowlr":  1;<lane owner>;<pins up>                              I'm at the line, these pins are up
#   "playground_bowls":  1;<lane owner>;<pins knocked by each roll, joined by ,>     my game so far

const LANE_KEY = "playground_lane"
const ROLL_KEY = "playground_bowl"
const READY_KEY = "playground_bowlr"
const SCORE_KEY = "playground_bowls"

const APPROACH = 3.0         # the floor behind the foul line
const PLACE_AHEAD = 1.2      # the foul line goes this far in front of me, so I'm standing on the approach
const RISE = 0.5             # seconds a set-up pin takes to pop up
const SWEEP_AFTER = 1.3      # seconds after a roll before the fallen pins are cleared
const NEXT_AFTER = 1.6       # and before the next ball is up
const LEVEL_LIMIT = 0.9      # the ground under the lane can differ this much, or it's too bumpy
const MOVE_SPEED = 0.9       # across the lane, metres per second
const AIM_SPEED = 0.09       # radians per second
const AIM_MAX = 0.14
const SLOW = 6.5             # the softest and hardest roll, metres per second
const FAST = 15.5
const METER_PERIOD = 1.6
const BOARD_RANGE = 24.0     # the score board shows for a lane this near
const KEEP_SCORE = 25.0      # seconds my finished game stays up after I step away

var main
var Sim
var clock = 0.0
var read_timer = 0.0
var next_check = 0.0

var lanes = {}               # owner id -> the lane (see _parse_lane and _build_lane)
var others = {}              # steam id -> {"roll", "ready", "score"} (the texts I last saw)
var roll_seen = {}           # steam id -> the roll text I last saw, so one roll plays once
var score_seen = {}          # steam id -> the score text I last saw

# my lane
var my_lane_text = ""

# me bowling
var mode = 0                 # 0 not bowling, 1 aiming, 2 power bar, 3 the ball is rolling, 4 game over
var bowl_owner = 0
var u0 = 0.0                 # where I stand across the lane (+ is my right)
var aim = 0.0
var meter_t = 0.0
var rolls = []               # pins knocked by each of my rolls this game
var mask = 1023              # pins up for my next roll
var mask_before = 1023
var roll_n = 0
var rolled_at = 0.0
var next_at = -1.0
var was_locked = false
var was_gravity = false
var ready_text = ""
var score_text = ""
var clear_score_at = -1.0
var last_gutter = false

# the screen
var prompt
var hud_panel
var hint_label
var meter
var board_panel
var board
var board_rows = []
var materials = {}
var pin_mesh = null
var ball_mesh = null
var aim_line = null


func _ready():
	process_priority = 100
	Sim = load("res://mods/Playground/bowl_sim.gd")
	_make_materials()
	_build_ui()


func _exit_tree():
	if mode != 0:
		_leave(false)
	for id in lanes.keys():
		if is_instance_valid(lanes[id]["node"]):
			lanes[id]["node"].queue_free()
	lanes = {}
	if aim_line != null and is_instance_valid(aim_line):
		aim_line.queue_free()
	my_lane_text = ""
	ready_text = ""
	score_text = ""
	_write(LANE_KEY, "")
	_write(READY_KEY, "")
	_write(SCORE_KEY, "")
	_write(ROLL_KEY, "")


# --- laying down and picking up ---

func has_lane():
	return my_lane_text != ""


func place_lane():
	var me = _my_player()
	if me == null:
		return
	var size = main._player_size(me)
	var f = _facing(me)
	var feet = me.global_transform.origin - Vector3.UP * 1.0 * size
	var at = feet + f * PLACE_AHEAD
	# the ground all along it has to be fairly level, and not under water
	var low = 1000.0
	var high = -1000.0
	var y_at = feet.y
	for d in [-APPROACH, 0.0, 4.0, 8.0, 12.0, 16.0]:
		var p = at + f * d
		var y = _ground_y(p, 1000.0)
		if y > 999.0 or abs(y - feet.y) > LEVEL_LIMIT:
			main._show_toast("The ground here isn't flat enough for a lane. Try a flatter spot.")
			return
		low = min(low, y)
		high = max(high, y)
		if d == 0.0:
			y_at = y
	if high - low > LEVEL_LIMIT:
		main._show_toast("The ground here isn't flat enough for a lane. Try a flatter spot.")
		return
	at.y = y_at
	var yaw = atan2(f.x, f.z)   # down the lane is the way I'm facing
	my_lane_text = "1;%.2f;%.2f;%.2f;%.3f;%s;%d" % [at.x, at.y, at.z, yaw, str(me.get("current_zone")), int(me.get("current_zone_owner") if me.get("current_zone_owner") != null else -1)]
	_write(LANE_KEY, my_lane_text)
	main._show_toast("Lane down! Walk onto it and press E to bowl.")


func remove_lane():
	if mode != 0 and bowl_owner == _my_id():
		_leave(false)
	my_lane_text = ""
	_write(LANE_KEY, "")
	main._show_toast("Bowling lane picked up.")


func _ground_y(at, fallback):
	var world = get_tree().root.get_world()
	var space = world.direct_space_state if world != null else null
	if space == null:
		return fallback
	var hit = space.intersect_ray(at + Vector3.UP * 3.0, at + Vector3.DOWN * 6.0, [], 1)
	return hit["position"].y if hit.has("position") else fallback


# --- every frame ---

func _process(delta):
	clock += delta
	read_timer += delta
	if read_timer >= 0.2:
		read_timer = 0.0
		_read(main.steam)
	# make sure what I said stuck (a write made while joining a lobby is lost)
	if clock >= next_check:
		next_check = clock + 3.0
		if _read_mine(LANE_KEY) != my_lane_text:
			_write(LANE_KEY, my_lane_text)
		if _read_mine(READY_KEY) != ready_text:
			_write(READY_KEY, ready_text)
		if _read_mine(SCORE_KEY) != score_text:
			_write(SCORE_KEY, score_text)
	if clear_score_at > 0.0 and clock >= clear_score_at and mode == 0:
		clear_score_at = -1.0
		score_text = ""
		_write(SCORE_KEY, "")
	var me = _my_player()
	for owner in lanes.keys():
		_animate_lane(owner, me, delta)
	if mode != 0:
		_bowl(me, delta)
	_update_prompt(me)
	_update_hud()
	_update_board(me)


# --- what everyone else is doing ---

func _read(steam):
	var lobby = _lobby()
	var wanted = {}
	var my_id = _my_id()
	if my_lane_text != "":
		wanted[my_id] = my_lane_text
	var seen_players = {}
	if lobby > 0 and steam != null and steam.has_method("getLobbyMemberData"):
		for player in get_tree().get_nodes_in_group("player"):
			var id = player.get("owner_id")
			if id == null or int(id) <= 0 or int(id) == my_id:
				continue
			id = int(id)
			seen_players[id] = true
			var t = str(steam.getLobbyMemberData(lobby, id, LANE_KEY))
			if t.begins_with("1;"):
				wanted[id] = t
			others[id] = {
				"roll": str(steam.getLobbyMemberData(lobby, id, ROLL_KEY)),
				"ready": str(steam.getLobbyMemberData(lobby, id, READY_KEY)),
				"score": str(steam.getLobbyMemberData(lobby, id, SCORE_KEY)),
			}
	for id in others.keys():
		if not seen_players.has(id):
			others.erase(id)
			roll_seen.erase(id)
			score_seen.erase(id)

	# lanes that appeared, moved or went away
	for owner in lanes.keys():
		if not wanted.has(owner) or wanted[owner] != lanes[owner]["text"]:
			if is_instance_valid(lanes[owner]["node"]):
				lanes[owner]["node"].queue_free()
			lanes.erase(owner)
	for owner in wanted.keys():
		if not lanes.has(owner):
			var s = _parse_lane(wanted[owner])
			if s != null:
				s["text"] = wanted[owner]
				_build_lane(owner, s)
				lanes[owner] = s
	# the lane I'm bowling on went away
	if mode != 0 and not lanes.has(bowl_owner):
		main._show_toast("The lane was picked up.")
		_leave(false)

	for id in others.keys():
		var o = others[id]
		# a roll I haven't seen: play it (the first sight of someone's old roll is not played)
		if not roll_seen.has(id):
			roll_seen[id] = o["roll"]
		elif roll_seen[id] != o["roll"]:
			roll_seen[id] = o["roll"]
			_play_roll_text(o["roll"])
		if not score_seen.has(id):
			score_seen[id] = o["score"]
		elif score_seen[id] != o["score"]:
			var before = _rolls_of(score_seen[id])
			score_seen[id] = o["score"]
			var now = _rolls_of(o["score"])
			if now.size() == before.size() + 1 and now[now.size() - 1] == 10 and _near_lane(o["score"]):
				main._show_toast(main._name_of(id) + " rolled a strike!")
	# pins at a lane follow whoever is at the line (set up their pins)
	for owner in lanes.keys():
		var l = lanes[owner]
		var want = -1
		if mode != 0 and bowl_owner == owner:
			want = mask if mode != 3 else -1
		else:
			for id in others.keys():
				var r = str(others[id]["ready"]).split(";")
				if r.size() >= 3 and r[0] == "1" and int(r[1]) == owner:
					want = int(r[2])
		if want >= 0 and l["sim"] == null and l["shown"] != want:
			_show_pins(l, want, true)


func _parse_lane(text):
	var b = text.split(";")
	if b.size() < 7:
		return null
	return {"pos": Vector3(float(b[1]), float(b[2]), float(b[3])), "yaw": float(b[4]), "zone": b[5],
		"zone_owner": int(b[6]), "sim": null, "acc": 0.0, "shown": 1023, "rise": [], "pins": [],
		"events_i": 0, "sweep_at": -1.0, "last_sound": -1.0, "ball_rot": Basis(), "ball_last": Vector2()}


func _rolls_of(text):
	var out = []
	var b = str(text).split(";")
	if b.size() >= 3 and b[0] == "1" and b[2] != "":
		for x in b[2].split(","):
			out.append(int(x))
	return out


func _near_lane(score_text_):
	var b = str(score_text_).split(";")
	if b.size() < 3 or not lanes.has(int(b[1])):
		return false
	var me = _my_player()
	if me == null:
		return false
	var l = lanes[int(b[1])]
	return l["node"].visible and l["pos"].distance_to(me.global_transform.origin) < 40.0


# someone's roll: start it on their lane
func _play_roll_text(text):
	var b = str(text).split(";")
	if b.size() < 7 or b[0] != "1":
		return
	var owner = int(b[1])
	if not lanes.has(owner):
		return
	_start_roll(lanes[owner], int(b[3]), int(b[4]) / 100.0, int(b[5]) / 1000.0, int(b[6]) / 10.0)


func _start_roll(l, pins_up, u, angle, speed):
	l["sim"] = Sim.new()
	l["sim"].start(pins_up, u, angle, speed)
	l["acc"] = 0.0
	l["events_i"] = 0
	l["sweep_at"] = -1.0
	l["last_sound"] = -1.0
	l["shown"] = pins_up
	l["ball_rot"] = Basis()
	l["ball_last"] = Vector2(u, 0.0)
	# the pins that are up stand (no rising), the others are gone
	for i in range(10):
		l["rise"][i] = 0.0
	_sound_at(l, "woosh", Vector3(-u, 0.3, 0.0), 0.6)


# --- the lane itself, made from simple shapes ---

func _make_materials():
	materials["lane"] = _mat(Color(0.86, 0.68, 0.42))
	materials["approach"] = _mat(Color(0.74, 0.55, 0.33))
	materials["slab"] = _mat(Color(0.2, 0.2, 0.24))
	materials["dark"] = _mat(Color(0.09, 0.09, 0.11))
	materials["rail"] = _mat(Color(0.5, 0.18, 0.18))
	materials["mark"] = _mat(Color(0.25, 0.14, 0.08))
	materials["wood"] = _mat(Color(0.56, 0.37, 0.22))
	materials["pin"] = _mat(Color(0.97, 0.97, 0.94))
	materials["pin"].roughness = 0.35
	materials["pin"].emission_enabled = true
	materials["pin"].emission = Color(0.3, 0.3, 0.3)
	materials["stripe"] = _mat(Color(0.85, 0.12, 0.12))
	materials["hole"] = _mat(Color(0.02, 0.02, 0.03))
	materials["ball0"] = _mat(Color(0.18, 0.12, 0.62))
	materials["ball1"] = _mat(Color(0.75, 0.12, 0.15))
	materials["ball2"] = _mat(Color(0.12, 0.55, 0.3))
	for k in ["ball0", "ball1", "ball2"]:
		materials[k].roughness = 0.25
		materials[k].metallic = 0.3
	materials["aim"] = SpatialMaterial.new()
	materials["aim"].albedo_color = Color(0.55, 1.0, 1.0, 0.45)
	materials["aim"].flags_transparent = true
	materials["aim"].flags_unshaded = true


func _mat(c):
	var m = SpatialMaterial.new()
	m.albedo_color = c
	m.roughness = 1.0
	m.metallic_specular = 0.2
	return m


func _box(parent, size, at, mat):
	var mi = MeshInstance.new()
	var cube = CubeMesh.new()
	cube.size = size
	mi.mesh = cube
	mi.material_override = mat
	mi.translation = at
	parent.add_child(mi)
	return mi


# the pin: a turned shape, like the real one, from a list of (height, radius) as a share of the pin's height
func _make_pin_mesh():
	var H = 0.76
	var prof = [[0.0, 0.0], [0.0, 0.075], [0.04, 0.08], [0.12, 0.125], [0.20, 0.15], [0.30, 0.159], [0.40, 0.15],
		[0.50, 0.115], [0.60, 0.075], [0.667, 0.06], [0.75, 0.065], [0.83, 0.079], [0.9, 0.082], [0.96, 0.07],
		[0.99, 0.04], [1.0, 0.0]]
	var N = 16
	var st = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.add_smooth_group(true)
	for k in range(prof.size() - 1):
		var a = prof[k]
		var b = prof[k + 1]
		for s in range(N):
			var t0 = TAU * s / N
			var t1 = TAU * (s + 1) / N
			var p00 = Vector3(cos(t0) * a[1], a[0], sin(t0) * a[1]) * H
			var p01 = Vector3(cos(t1) * a[1], a[0], sin(t1) * a[1]) * H
			var p10 = Vector3(cos(t0) * b[1], b[0], sin(t0) * b[1]) * H
			var p11 = Vector3(cos(t1) * b[1], b[0], sin(t1) * b[1]) * H
			for v in [p00, p11, p10, p00, p01, p11]:
				st.add_vertex(v)
	st.generate_normals()
	return st.commit()


func _make_ball():
	var ball = Spatial.new()
	var mi = MeshInstance.new()
	var sphere = SphereMesh.new()
	sphere.radius = Sim.BALL_R
	sphere.height = Sim.BALL_R * 2.0
	sphere.radial_segments = 24
	sphere.rings = 12
	mi.mesh = sphere
	mi.material_override = materials["ball0"]
	ball.add_child(mi)
	# the three finger holes
	for dir in [Vector3(0.28, 0.9, 0.3), Vector3(-0.28, 0.9, 0.3), Vector3(0.0, 0.8, -0.45)]:
		var n = dir.normalized()
		var hole = MeshInstance.new()
		var cyl = CylinderMesh.new()
		cyl.top_radius = 0.03
		cyl.bottom_radius = 0.03
		cyl.height = 0.01
		cyl.radial_segments = 10
		hole.mesh = cyl
		hole.material_override = materials["hole"]
		var up = n
		var side = up.cross(Vector3.FORWARD if abs(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
		hole.transform = Transform(Basis(side, up, side.cross(up).normalized()), n * Sim.BALL_R)
		ball.add_child(hole)
	return ball


func _build_lane(owner, s):
	var parent = _my_player().get_parent() if _my_player() != null else get_tree().root
	if pin_mesh == null:
		pin_mesh = _make_pin_mesh()
	var root = Spatial.new()
	root.name = "PlaygroundLane"
	parent.add_child(root)
	root.global_transform = Transform(Basis(Vector3.UP, s["yaw"]), s["pos"])
	var L = Sim.BACK + APPROACH
	var mid = (Sim.BACK - APPROACH) / 2.0
	# in lane space x is minus "u" (to the bowler's right), z runs down the lane
	_box(root, Vector3(3.0, 1.2, L), Vector3(0, 0.03 - 0.6, mid), materials["slab"])
	_box(root, Vector3(2.1, 0.04, Sim.BACK - 0.3), Vector3(0, 0.03, (Sim.BACK - 0.3) / 2.0), materials["lane"])
	_box(root, Vector3(2.7, 0.04, APPROACH), Vector3(0, 0.03, -APPROACH / 2.0), materials["approach"])
	_box(root, Vector3(2.1, 0.005, 0.05), Vector3(0, 0.054, 0.0), materials["dark"])
	_box(root, Vector3(2.9, 0.045, 0.3), Vector3(0, 0.04, Sim.BACK - 0.15), materials["dark"])
	# the arrows
	for k in range(-3, 4):
		var dot = MeshInstance.new()
		var cyl = CylinderMesh.new()
		cyl.top_radius = 0.04
		cyl.bottom_radius = 0.04
		cyl.height = 0.004
		cyl.radial_segments = 8
		dot.mesh = cyl
		dot.material_override = materials["mark"]
		dot.translation = Vector3(k * 0.28, 0.054, 4.5 + 0.6 - abs(k) * 0.2)
		root.add_child(dot)
	# the rails along the sides, the back wall and the hood over the pins
	for x in [-1.44, 1.44]:
		_box(root, Vector3(0.1, 0.2, Sim.BACK), Vector3(x, 0.13, Sim.BACK / 2.0), materials["rail"])
	_box(root, Vector3(3.1, 2.6, 0.2), Vector3(0, 1.3, Sim.BACK + 0.1), materials["dark"])
	_box(root, Vector3(3.1, 0.45, 2.0), Vector3(0, 2.4, Sim.BACK - 0.9), materials["slab"])
	# the ball return, with a few balls on it, beside the approach
	_box(root, Vector3(0.55, 0.5, 0.9), Vector3(-1.85, 0.25, -1.5), materials["wood"])
	for k in range(3):
		var b = _make_ball()
		b.get_child(0).material_override = materials["ball" + str(k)]
		b.translation = Vector3(-1.85, 0.5 + Sim.BALL_R, -1.85 + k * 0.36)
		root.add_child(b)
	# the pins
	s["pins"] = []
	s["rise"] = []
	for i in range(10):
		var pin = Spatial.new()
		var mi = MeshInstance.new()
		mi.mesh = pin_mesh
		mi.material_override = materials["pin"]
		pin.add_child(mi)
		for band in [0.6, 0.675]:
			var ring = MeshInstance.new()
			var cyl = CylinderMesh.new()
			var r = 0.078 * 0.76 if band > 0.65 else 0.09 * 0.76
			cyl.top_radius = r
			cyl.bottom_radius = r
			cyl.height = 0.03
			cyl.radial_segments = 16
			ring.mesh = cyl
			ring.material_override = materials["stripe"]
			ring.translation = Vector3(0, band * 0.76 + 0.02, 0)
			pin.add_child(ring)
		root.add_child(pin)
		s["pins"].append(pin)
		s["rise"].append(0.0)
	# the ball that rolls (and sits at the line while I aim)
	s["ball"] = _make_ball()
	s["ball"].visible = false
	root.add_child(s["ball"])
	s["node"] = root
	_show_pins(s, 1023, false)


# which pins stand (a mask); those that weren't there before pop up
func _show_pins(l, pins_up, animate):
	for i in range(10):
		var was = (l["shown"] >> i) & 1 == 1
		var now = (pins_up >> i) & 1 == 1
		if now and (not was) and animate:
			l["rise"][i] = RISE
		elif not now:
			l["rise"][i] = 0.0
	l["shown"] = pins_up
	for i in range(10):
		var home = Sim.pin_home(i)
		var pin = l["pins"][i]
		pin.visible = (pins_up >> i) & 1 == 1
		pin.transform = Transform(Basis(), Vector3(-home.x, _rise_y(l["rise"][i]), home.y))


func _rise_y(rise):
	var k = rise / RISE
	return -0.9 * k * k


func _animate_lane(owner, me, delta):
	var l = lanes[owner]
	if not is_instance_valid(l["node"]):
		return
	var here = true
	if me != null and me.get("current_zone") != null:
		here = str(me.get("current_zone")) == l["zone"]
	l["node"].visible = here
	var sim = l["sim"]
	if sim != null:
		l["acc"] += min(delta, 0.1)
		while l["acc"] >= Sim.DT and not sim.done:
			l["acc"] -= Sim.DT
			sim.step()
		_play_events(l, sim, here)
		_pose_sim(l, sim)
		if sim.done:
			if l["sweep_at"] < 0.0:
				l["sweep_at"] = clock + SWEEP_AFTER
			elif clock >= l["sweep_at"]:
				# the fallen pins are cleared away
				var standing = sim.standing_mask()
				l["sim"] = null
				_show_pins(l, standing, false)
				l["ball"].visible = false
		return
	# no roll going: pins that are setting up rise, and the ball at the line while I aim
	for i in range(10):
		if l["rise"][i] > 0.0:
			l["rise"][i] = max(l["rise"][i] - delta, 0.0)
			var home = Sim.pin_home(i)
			l["pins"][i].translation = Vector3(-home.x, _rise_y(l["rise"][i]), home.y)
	var holding = mode != 0 and mode != 3 and bowl_owner == owner
	l["ball"].visible = holding
	if holding:
		l["ball"].transform = Transform(Basis(), Vector3(-u0, Sim.BALL_R + 0.054, -0.5))
	if aim_line != null and holding and aim_line.get_parent() == l["node"]:
		_place_aim(l)


func _pose_sim(l, sim):
	for i in range(10):
		var pin = l["pins"][i]
		if sim.pin_state[i] == 2:
			pin.visible = false
			continue
		pin.visible = true
		var p = sim.pin_p[i]
		if sim.pin_state[i] == 0:
			pin.transform = Transform(Basis(), Vector3(-p.x, 0.0, p.y))
			continue
		var t = sim.pin_t[i]
		var k = clamp(t / Sim.FALL_TIME, 0.0, 1.0)
		var theta = k * k * (PI / 2.0)
		var dir = sim.pin_dir[i]
		var dir3 = Vector3(-dir.x, 0.0, dir.y)
		var axis = Vector3.UP.cross(dir3).normalized()
		var hop = 0.35 * min(sim.pin_speed0[i] / 10.0, 1.0)
		var s = clamp(t / 0.7, 0.0, 1.0)
		var y = 4.0 * hop * s * (1.0 - s) + sin(theta) * Sim.PIN_R * 0.95
		var spin = min(t, 0.8) * sim.pin_speed0[i] * 0.5 * (1.0 if i % 2 == 0 else -1.0)
		pin.transform = Transform(Basis(axis, theta) * Basis(Vector3.UP, spin), Vector3(-p.x, y, p.y))
	# the ball
	var ball = l["ball"]
	if sim.ball_in and not sim.ball_gone:
		ball.visible = true
		var y = Sim.BALL_R + 0.054
		if sim.gutter:
			y = Sim.BALL_R * 0.55
		var at = Vector3(-sim.ball.x, y, sim.ball.y)
		var last = l["ball_last"]
		var moved = Vector2(sim.ball.x, sim.ball.y) - last
		l["ball_last"] = Vector2(sim.ball.x, sim.ball.y)
		if moved.length() > 0.0001:
			var dir3 = Vector3(-moved.x, 0.0, moved.y).normalized()
			var axis = Vector3.UP.cross(dir3).normalized()
			l["ball_rot"] = (Basis(axis, moved.length() / Sim.BALL_R) * l["ball_rot"]).orthonormalized()
		ball.transform = Transform(l["ball_rot"], at)
	else:
		ball.visible = false


func _play_events(l, sim, here):
	if not here:
		l["events_i"] = sim.events.size()
		return
	while l["events_i"] < sim.events.size():
		var ev = sim.events[l["events_i"]]
		l["events_i"] += 1
		if ev[0] - l["last_sound"] < 0.05 and l["last_sound"] >= 0.0:
			continue
		l["last_sound"] = ev[0]
		var p = ev[2]
		_sound_at(l, "punch", Vector3(-p.x, 0.3, p.y), 1.5 + 0.12 * (l["events_i"] % 5) - (0.25 if ev[1] == 1 else 0.0))


# a game sound, played only for me, at a spot in the lane's space
func _sound_at(l, id, local, pitch):
	var me = _my_player()
	if me == null or not l["node"].visible:
		return
	var sm = me.get("sound_manager")
	if sm != null and sm.has_method("_play_sound"):
		sm._play_sound(id, l["node"].global_transform.xform(local), pitch)


# --- bowling ---

func _enter(owner):
	var me = _my_player()
	if me == null or mode != 0 or not lanes.has(owner):
		return
	bowl_owner = owner
	mode = 1
	u0 = 0.0
	aim = 0.0
	rolls = []
	mask = 1023
	was_locked = me.get("locked") == true
	was_gravity = me.get("gravity_disable") == true
	clear_score_at = -1.0
	_publish(true)
	if aim_line == null:
		aim_line = MeshInstance.new()
		var cube = CubeMesh.new()
		cube.size = Vector3(0.05, 0.004, 1.0)
		aim_line.mesh = cube
		aim_line.material_override = materials["aim"]
	_attach_aim()
	main._show_toast("Bowling! A / D slide, arrow keys aim, Space for power.")


func _attach_aim():
	if aim_line.get_parent() != null:
		aim_line.get_parent().remove_child(aim_line)
	var l = lanes.get(bowl_owner)
	if l != null:
		l["node"].add_child(aim_line)
		aim_line.visible = true


func _place_aim(l):
	# a faint strip from the ball down the way it will go
	var reach = Sim.HEAD + 1.0
	var angle = -aim                                   # lane space has x the other way round
	var dirv = Vector3(sin(angle), 0, cos(angle))
	aim_line.transform = Transform(Basis(Vector3.UP, angle).scaled(Vector3(1, 1, reach)), Vector3(-u0, 0.058, 0.0) + dirv * (reach / 2.0))
	aim_line.visible = mode == 1 or mode == 2


func _leave(announce):
	var me = _my_player()
	var l = lanes.get(bowl_owner)
	clear_score_at = clock + (KEEP_SCORE if mode == 4 else 0.1)
	mode = 0
	if aim_line != null and aim_line.get_parent() != null:
		aim_line.get_parent().remove_child(aim_line)
	if l != null:
		l["ball"].visible = false
	ready_text = ""
	_write(READY_KEY, "")
	if me != null and is_instance_valid(me):
		me.set("locked", was_locked)
		me.set("gravity_disable", was_gravity)
	if announce:
		main._show_toast("Left the lane.")
	bowl_owner = 0


func _bowl(me, delta):
	if me == null or not lanes.has(bowl_owner):
		return
	var l = lanes[bowl_owner]
	if mode == 1:
		var moving = 0.0
		if Input.is_key_pressed(KEY_D):
			moving += 1.0
		if Input.is_key_pressed(KEY_A):
			moving -= 1.0
		u0 = clamp(u0 + moving * MOVE_SPEED * delta, -0.95, 0.95)
		var turning = 0.0
		if Input.is_key_pressed(KEY_RIGHT):
			turning += 1.0
		if Input.is_key_pressed(KEY_LEFT):
			turning -= 1.0
		aim = clamp(aim + turning * AIM_SPEED * delta, -AIM_MAX, AIM_MAX)
	elif mode == 2:
		meter_t += delta / (METER_PERIOD / 2.0)
		var turning2 = 0.0
		if Input.is_key_pressed(KEY_RIGHT):
			turning2 += 1.0
		if Input.is_key_pressed(KEY_LEFT):
			turning2 -= 1.0
		aim = clamp(aim + turning2 * AIM_SPEED * delta, -AIM_MAX, AIM_MAX)
	elif mode == 3:
		# after my roll finishes, count the pins and get the next ball ready
		if l["sim"] != null and l["sim"].done and next_at < 0.0:
			_roll_done(l)
		elif l["sim"] == null and next_at < 0.0:
			next_at = clock + 0.1       # the roll is gone somehow: carry on with the next ball
		if next_at > 0.0 and clock >= next_at:
			next_at = -1.0
			if Sim.game_over(rolls):
				mode = 4
				_publish(false)
			else:
				mode = 1
				_publish(true)
	# I stand on the approach at the line, facing down the lane, and slide as I move
	var size = main._player_size(me)
	var stand = l["node"].global_transform.xform(Vector3(-u0, 0.054, -0.9)) + Vector3.UP * 1.0 * size
	me.set("locked", true)
	me.set("gravity_disable", true)
	me.set("velocity", Vector3.ZERO)
	me.set("gravity_vec", Vector3.ZERO)
	me.global_transform.origin = stand
	me.rotation.y = l["yaw"] + PI


func _throw():
	var l = lanes.get(bowl_owner)
	if l == null:
		return
	var m = 1.0 - abs(fmod(meter_t, 2.0) - 1.0)
	var speed = SLOW + (FAST - SLOW) * m
	roll_n += 1
	mask_before = mask
	var uq = int(round(u0 * 100.0))
	var aq = int(round(aim * 1000.0))
	var sq = int(round(speed * 10.0))
	var text = "1;%d;%d;%d;%d;%d;%d" % [bowl_owner, roll_n + int(OS.get_unix_time() % 100000) * 100, mask, uq, aq, sq]
	_write(ROLL_KEY, text)
	mode = 3
	next_at = -1.0
	# I start it the same way everyone else will, from the same whole numbers
	_start_roll(l, mask, uq / 100.0, aq / 1000.0, sq / 10.0)
	if aim_line != null:
		aim_line.visible = false
	# still at the line, but rolling: nobody else can step up, and nobody resets the pins
	ready_text = "1;%d;-1" % bowl_owner
	_write(READY_KEY, ready_text)


func _roll_done(l):
	var sim = l["sim"]
	var after = sim.standing_mask()
	var down = _count(mask_before) - _count(after)
	var gutter = sim.gutter
	rolls.append(down)
	var text = ""
	if after == 0 and mask_before == 1023:
		text = "STRIKE!"
	elif after == 0:
		text = "Spare!"
	elif down == 0 and gutter:
		text = "Gutter ball..."
	elif down == 0:
		text = "Missed them all"
	else:
		text = str(down) + (" down" if down != 1 else " pin down")
	main._show_toast(text)
	if after == 0:
		_sound_at(l, "tambourine", Vector3(0, 1.0, -0.9), 1.0)
	elif gutter and down == 0:
		_sound_at(l, "poof", Vector3(0, 0.3, 8.0), 0.8)
	mask = Sim.next_mask(rolls, after)
	score_text = "1;%d;%s" % [bowl_owner, _csv(rolls)]
	_write(SCORE_KEY, score_text)
	next_at = clock + NEXT_AFTER


func _count(m):
	var n = 0
	for i in range(10):
		if (m >> i) & 1 == 1:
			n += 1
	return n


func _csv(list):
	var out = []
	for x in list:
		out.append(str(x))
	return PoolStringArray(out).join(",")


# tell everyone where I am and which pins are up for my next ball
func _publish(at_line):
	if at_line:
		ready_text = "1;%d;%d" % [bowl_owner, mask]
	else:
		ready_text = ""
	_write(READY_KEY, ready_text)
	score_text = "1;%d;%s" % [bowl_owner, _csv(rolls)]
	_write(SCORE_KEY, score_text)
	var l = lanes.get(bowl_owner)
	if l != null and l["sim"] == null and l["shown"] != mask and at_line:
		_show_pins(l, mask, true)


func _input(event):
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if main._typing():
		return
	if event.scancode == KEY_E:
		if mode != 0:
			_leave(true)
			get_tree().set_input_as_handled()
		elif prompt.visible and prompt_owner != 0:
			_enter(prompt_owner)
			get_tree().set_input_as_handled()
	elif event.scancode == KEY_SPACE and mode != 0:
		if mode == 1:
			mode = 2
			meter_t = 0.0
		elif mode == 2:
			_throw()
		elif mode == 4:
			rolls = []
			mask = 1023
			mode = 1
			_publish(true)
		get_tree().set_input_as_handled()


# --- "E  Bowl" at the start of a lane, and the help at the bottom ---

var prompt_owner = 0

func _update_prompt(me):
	prompt_owner = 0
	if me == null or mode != 0 or not main._hud_free():
		prompt.visible = false
		return
	var best_at = Vector3()
	var here = me.global_transform.origin
	for owner in lanes.keys():
		var l = lanes[owner]
		if not is_instance_valid(l["node"]) or not l["node"].visible:
			continue
		if _lane_busy(owner):
			continue
		var local = l["node"].global_transform.affine_inverse().xform(here)
		if abs(local.x) < 1.6 and local.z > -APPROACH and local.z < 0.6 and local.y > -0.5 and local.y < 3.5:
			prompt_owner = owner
			best_at = l["node"].global_transform.xform(Vector3(0, 1.4, -0.9))
			break
	if prompt_owner == 0:
		prompt.visible = false
		return
	main.swing._place_at(prompt, best_at)


# someone else is at the line of this lane
func _lane_busy(owner):
	for id in others.keys():
		var r = str(others[id]["ready"]).split(";")
		if r.size() >= 3 and r[0] == "1" and int(r[1]) == owner:
			return true
	return false


func _update_hud():
	if mode == 0 or not main._hud_free(true):
		hud_panel.visible = false
		return
	hud_panel.visible = true
	if mode == 1:
		hint_label.text = "A / D: slide      Left / Right: aim      Space: ready      E: leave"
	elif mode == 2:
		hint_label.text = "Space to roll!      Left / Right: aim"
	elif mode == 3:
		hint_label.text = "..."
	else:
		var sc = _final_score()
		hint_label.text = "Game over!  You scored " + str(sc) + ".      Space: new game      E: leave"
	meter.visible = mode == 2
	meter.update()
	hud_panel.rect_size = Vector2()
	var size = hud_panel.get_viewport_rect().size
	var own = hud_panel.get_combined_minimum_size()
	hud_panel.rect_position = Vector2((size.x - own.x) / 2.0, size.y * 0.8)


func _final_score():
	var frames = Sim.frames_of(rolls)
	var best = 0
	for fr in frames:
		if fr["score"] >= 0:
			best = fr["score"]
	return best


func _draw_meter():
	var box = meter.rect_size
	var x0 = 10.0
	var x1 = box.x - 10.0
	var y = box.y * 0.5
	meter.draw_rect(Rect2(x0, y - 7, x1 - x0, 14), Color(1, 1, 1, 0.15))
	var m = 1.0 - abs(fmod(meter_t, 2.0) - 1.0)
	var col = Color(0.4, 1.0, 0.75, 0.9).linear_interpolate(Color(1.0, 0.45, 0.35, 0.95), m)
	meter.draw_rect(Rect2(x0, y - 7, (x1 - x0) * m, 14), col)
	meter.draw_rect(Rect2(x0 + (x1 - x0) * m - 2, y - 11, 4, 22), Color(1, 1, 1, 0.95))


# --- the score board ---

func _update_board(me):
	if me == null:
		board_panel.visible = false
		return
	# the lane to show: mine while I'm bowling, else the nearest one close by
	var owner = 0
	if mode != 0:
		owner = bowl_owner
	else:
		var best = BOARD_RANGE
		for o in lanes.keys():
			var l = lanes[o]
			if is_instance_valid(l["node"]) and l["node"].visible:
				var d = l["node"].global_transform.xform(Vector3(0, 0, Sim.HEAD / 2.0)).distance_to(me.global_transform.origin)
				if d < best:
					best = d
					owner = o
	var rows = []
	if owner != 0:
		if mode != 0 and bowl_owner == owner:
			rows.append({"name": "You", "rolls": rolls})
		elif score_text != "" and _rolls_of(score_text).size() > 0 and int(score_text.split(";")[1]) == owner:
			rows.append({"name": "You", "rolls": _rolls_of(score_text)})
		for id in others.keys():
			var b = str(others[id]["score"]).split(";")
			if b.size() >= 3 and b[0] == "1" and int(b[1]) == owner and b[2] != "":
				rows.append({"name": main._name_of(id), "rolls": _rolls_of(others[id]["score"])})
	if rows.empty() or (not main._hud_free(true) and not main.menu.visible):
		board_panel.visible = false
		return
	board_panel.visible = true
	board_rows = rows
	board.rect_min_size = Vector2(440, 4 + rows.size() * 70)
	board.update()
	board_panel.rect_size = Vector2()
	var size = board_panel.get_viewport_rect().size
	var own = board_panel.get_combined_minimum_size()
	board_panel.rect_position = Vector2(size.x - own.x - 24, size.y * 0.16)


# what to write in the little boxes of a frame: X for a strike, / for a spare, - for none
func _pin(v):
	return "-" if v == 0 else str(v)


func _marks(fr, tenth):
	var r = fr["rolls"]
	var out = []
	if not tenth:
		if r.size() >= 1:
			if r[0] == 10:
				out.append("X")
			else:
				out.append(_pin(r[0]))
				if r.size() >= 2:
					out.append("/" if r[0] + r[1] == 10 else _pin(r[1]))
		return out
	for k in range(r.size()):
		var v = r[k]
		var m = ""
		if v == 10 and (k == 0 or r[k - 1] == 10 or (k == 2 and r[0] + r[1] == 10)):
			m = "X"
		elif k == 1 and r[0] != 10 and r[0] + v == 10:
			m = "/"
		elif k == 2 and r[0] == 10 and r[1] != 10 and r[1] + v == 10:
			m = "/"
		else:
			m = _pin(v)
		out.append(m)
	return out


func _draw_board():
	var rows = board_rows
	var font = board.get_font("font", "Label")
	var w = board.rect_size.x
	var cell = (w - 4.0) / 10.45
	for n in range(rows.size()):
		var top = 4.0 + n * 70.0
		var white = Color(1, 1, 1, 0.9)
		board.draw_string(font, Vector2(4, top + 12), rows[n]["name"], Color(0.55, 1.0, 1.0))
		var frames = Sim.frames_of(rows[n]["rolls"])
		for f in range(10):
			var x = 2.0 + f * cell
			var cw = cell * 1.45 if f == 9 else cell
			board.draw_rect(Rect2(x, top + 18, cw - 2, 44), Color(1, 1, 1, 0.1))
			board.draw_rect(Rect2(x, top + 18, cw - 2, 44), Color(0.55, 1.0, 1.0, 0.35), false)
			var fr = frames[f]
			var marks = _marks(fr, f == 9)
			for k in range(marks.size()):
				board.draw_string(font, Vector2(x + cw - 6 - (marks.size() - k) * 13, top + 33), marks[k], white)
			if fr["score"] >= 0:
				board.draw_string(font, Vector2(x + 5, top + 55), str(fr["score"]), Color(1.0, 0.9, 0.55))
			board.draw_string(font, Vector2(x + 3, top + 31), str(f + 1), Color(1, 1, 1, 0.35))


func _build_ui():
	prompt = main._panel(0.55)
	prompt.visible = false
	prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var row = HBoxContainer.new()
	row.add_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	prompt.add_child(row)
	var key = Label.new()
	key.text = "E"
	key.add_color_override("font_color", Color(0.55, 1.0, 1.0))
	row.add_child(key)
	var words = Label.new()
	words.text = "Bowl"
	words.add_color_override("font_color", Color(1, 1, 1, 0.9))
	row.add_child(words)
	prompt.rect_scale = Vector2(0.85, 0.85)

	hud_panel = main._panel(0.6)
	hud_panel.visible = false
	hud_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var col = main._column(hud_panel)
	meter = Control.new()
	meter.rect_min_size = Vector2(320, 26)
	meter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meter.connect("draw", self, "_draw_meter")
	col.add_child(meter)
	hint_label = Label.new()
	hint_label.align = Label.ALIGN_CENTER
	hint_label.add_color_override("font_color", Color(1, 1, 1, 0.9))
	col.add_child(hint_label)

	board_panel = main._panel(0.6)
	board_panel.visible = false
	board_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board = Control.new()
	board.mouse_filter = Control.MOUSE_FILTER_IGNORE
	board.rect_min_size = Vector2(420, 94)
	board.connect("draw", self, "_draw_board")
	main._column(board_panel).add_child(board)
	main.themed.append(prompt)
	main.themed.append(hud_panel)
	main.themed.append(board_panel)


# --- helpers ---

func _my_player():
	var list = get_tree().get_nodes_in_group("controlled_player")
	return list[0] if not list.empty() and is_instance_valid(list[0]) else null


func _facing(node):
	var f = -node.global_transform.basis.z
	f.y = 0
	return f.normalized() if f.length() > 0.001 else Vector3(0, 0, -1)


func _lobby():
	var net = get_node_or_null("/root/Network")
	if net != null and not net.PLAYING_OFFLINE and net.STEAM_LOBBY_ID > 0:
		return net.STEAM_LOBBY_ID
	return 0


func _my_id():
	var net = get_node_or_null("/root/Network")
	return int(net.STEAM_ID) if net != null else 0


func _read_mine(key):
	var lobby = _lobby()
	if lobby <= 0 or main.steam == null or not main.steam.has_method("getLobbyMemberData"):
		return ""
	return str(main.steam.getLobbyMemberData(lobby, _my_id(), key))


func _write(key, text):
	var lobby = _lobby()
	if lobby <= 0 or main == null or main.steam == null or not main.steam.has_method("setLobbyMemberData"):
		return
	main.steam.setLobbyMemberData(lobby, key, text)

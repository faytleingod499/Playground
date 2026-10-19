extends Node

# Playground
# Games for everyone who has the mod, on any server: Tag and Hide and Seek (and a swing set, swing.gd).
#
# Hide and Seek: the same join window and trip to spawn, then one seeker (picked at random) counts to 45
# with their screen dark and can't move while everyone else hides. For the next 5 minutes the seeker
# hunts: close to a hider, "F  Found!" appears over them. The starter chooses whether found hiders join
# the seekers or are out. A seeker can't see the hiders' name tags. Everyone found: the seekers win;
# anyone still hidden when time runs out: the hiders win. Its roles go out with "hs" in front
# ("hsopen", "hsgo", ...), and its open/go lines end with ";1" (found join the seekers) or ";0".
#
# Click the little star button (drag it anywhere, like the EtherPets paw) or press J to open the
# Playground menu and start a round. Everyone with the mod gets a notice and has
# 10 seconds to join (Y). Then everyone who joined, and whoever started it, is sent back to spawn and a
# 5 second countdown begins. One player, picked at random, is "it": a glowing white star floats over
# their head and they run 10% faster. "It" stays put during the countdown, so everyone else gets a head
# start. Touch someone to make them "it" (no tagging back the one who just got you for a few seconds).
# After 3 minutes the round ends and everyone sees how long each player was "it": the least time wins.
#
# Everything goes through the Steam lobby member data ("playground"), so it works on any server.
# Players without the mod see nothing unusual.
#
# What each player says in "playground" (round = "<starter's steam id>x<number>"):
#   starter, collecting players:   1;<round>;open;tag
#   a player who said yes:         1;<round>;join
#   starter, once it's on:         1;<round>;go;<ids joined by ,>;<seconds>;<n>;<target>;<t>
#   everyone else playing:         1;<round>;play;<n>;<target>;<t>
# <n>;<target>;<t> is the last tag that player made: tag number n made <target> "it", <t> seconds into the
# round (by the tagger's clock). The starter's tag 0 is the first "it". The highest number is "it" now.

const VERSION = "1.3.0"
const SYNC_KEY = "playground"
const SKELETON_PATH = "body/player_body/Armature/Skeleton"
const POPUP_ID = "PLAYGROUND"
const MENU_KEY = KEY_J
const JOIN_KEY = KEY_Y

const JOIN_TIME = 10.0       # seconds to say yes
const COUNTDOWN = 5.0        # after everyone is sent to spawn
const ROUND_TIME = 180.0     # how long a round of tag lasts
const RESULTS_TIME = 12.0    # how long the scoreboard stays up
const IT_SPEED = 1.30        # "it" runs this much faster
const TAG_RANGE = 1.1        # how close "it" has to get (times their size), flat distance
const TAG_HEIGHT = 1.6       # and no further apart than this up and down
const NO_TAG_BACK = 3.0      # seconds the one who tagged you is safe from you
const GONE_GRACE = 3.0       # "it" left: after this long someone else is picked
const HIDE_TIME = 45.0       # hide and seek: how long the hiders get to hide
const SEEK_TIME = 300.0      # and how long the search lasts
const FIND_RANGE = 2.2       # how close a seeker has to be to find someone (times their size)
const FIND_HEIGHT = 2.5
const FIND_KEY = KEY_F
const GAME_NAMES = {"tag": "Tag", "hide": "Hide and Seek"}
const SPEED_VARS = ["walk_speed", "sprint_speed", "sneak_speed", "slow_walk_speed"]
const CONFIG_PATH = "user://playground.json"
const DEFAULT_BUTTON_POS = Vector2(16, 184)   # just under the EtherPets paw

var steam = null
var clock = 0.0
var read_timer = 0.0
var next_announce = 0.0
var states = {}              # steam id -> what they say (parsed), me included
var rounds = {}              # round -> {"host", "kind", "open_at", "go_at", "ids", "duration", "events"}
var answered = {}            # rounds I said yes or no to

# my side
var my_count = 0             # rounds I've started
var my_round = ""            # the round I'm in ("" when none)
var my_kind = "tag"          # "tag" or "hide" (hide and seek)
var my_infect = true         # hide and seek: found hiders join the seekers (or else they're out)
var infect_choice = true     # what the menu's checkbox says, remembered
var my_role = ""             # "open", "join", "go", "play"
var my_ids = []              # as starter: who is playing
var my_duration = ROUND_TIME
var my_n = -1                # my last tag
var my_target = 0
var my_t = 0.0
var my_since = 0.0           # when I started collecting players
var sync_dirty = false
var started = false          # sent to spawn and playing
var it_gone_since = -1.0
var it_since_t = 0.0         # round time I became "it"
var tagged_by = 0            # who made me "it"
var last_it = 0
var last_picked = 0          # who was picked as "it" / first seeker in the last round I saw start, not picked twice in a row
var base_speeds = {}         # my player's own speeds, put back when the round is over
var speed_owner = null
var results_until = -1.0

# the screen
var layer
var menu
var menu_status
var menu_tag
var menu_hide
var menu_infect
var blackout                 # the seeker's closed eyes
var find_prompt              # "F  Found!" over a hider near a seeker
var find_target = 0
var hidden_tags = {}         # steam id -> name tag I've hidden (hiders' names, from a seeker)
var last_found = {}          # round -> how many finds I've already announced
var menu_leave
var invite_panel
var invite_label
var invite_yes
var invite_round = ""
var wait_panel
var wait_label
var bar
var bar_label
var big
var hint
var results
var results_list
var results_title
var toast
var toast_until = 0.0
var locked_hud = null
var star_texture = null
var glow_texture = null
var icons = {}               # steam id -> the star over their head
var star_button              # the small button on screen, like the EtherPets paw
var star_hover = false
var star_pressed = false
var star_dragging = false
var press_pos = Vector2()
var drag_offset = Vector2()
var theme_applied = false
var themed = []              # more of my windows (the swing's) that get the game's font
var swing                    # the swing set (swing.gd)
var menu_swing


func _ready():
	randomize()
	if Engine.has_singleton("Steam"):
		steam = Engine.get_singleton("Steam")
	_make_textures()
	_build_ui()
	_load_config()
	swing = load("res://mods/Playground/swing.gd").new()
	swing.name = "Swing"
	swing.main = self
	add_child(swing)


func _exit_tree():
	_close_menu()
	_restore_speeds()
	_clear_mine()
	_flush_state()


# --- every frame ---

func _process(delta):
	clock += delta
	var net = get_node_or_null("/root/Network")
	var lobby = 0
	if net != null and not net.PLAYING_OFFLINE and net.STEAM_LOBBY_ID > 0:
		lobby = net.STEAM_LOBBY_ID
	var me = int(net.STEAM_ID) if net != null else 0

	# tell the lobby I have the mod; a write made while still joining is lost, so check it stuck
	if lobby > 0 and steam != null and steam.has_method("setLobbyMemberData") and clock >= next_announce:
		next_announce = clock + 3.0
		if str(steam.getLobbyMemberData(lobby, me, SYNC_KEY + "_v")) != VERSION:
			steam.setLobbyMemberData(lobby, SYNC_KEY + "_v", VERSION)
		if str(steam.getLobbyMemberData(lobby, me, SYNC_KEY)) != _state_text():
			sync_dirty = true

	read_timer += delta
	if read_timer >= 0.2:
		read_timer = 0.0
		_read_states(lobby, me)
		_update_rounds(me)
		if sync_dirty:
			_flush_state()

	var players = _players()
	_update_my_round(players, me)
	_update_icons(players)
	_update_invite(me)
	_update_menu()
	_refresh_button()
	toast.visible = clock < toast_until


func _players():
	var out = {}
	for player in get_tree().get_nodes_in_group("player"):
		if not is_instance_valid(player) or player.get("dead_actor") == true or player.get("NPC_body") == true:
			continue
		var id = player.get("owner_id")
		if id != null and int(id) > 0:
			out[int(id)] = player
	return out


# --- talking through the lobby ---

func _state_text():
	if my_round == "" or my_role == "":
		return ""
	# hide and seek says its roles with "hs" in front, so older versions of the mod (which only know tag)
	# leave those rounds alone
	var hide = my_kind == "hide"
	var t = "1;" + my_round + ";" + ("hs" if hide else "") + my_role
	var infect = "1" if my_infect else "0"
	if my_role == "open":
		return t + (";hide;" + infect if hide else ";tag")
	if my_role == "join":
		return t
	var tag = ";" + str(my_n) + ";" + str(my_target) + ";" + str(stepify(my_t, 0.1))
	if my_role == "go":
		var ids = []
		for id in my_ids:
			ids.append(str(id))
		return t + ";" + PoolStringArray(ids).join(",") + ";" + str(int(my_duration)) + tag + (";" + infect if hide else "")
	return t + tag


func _flush_state():
	sync_dirty = false
	var net = get_node_or_null("/root/Network")
	if steam == null or net == null or net.PLAYING_OFFLINE or net.STEAM_LOBBY_ID <= 0:
		return
	if steam.has_method("setLobbyMemberData"):
		steam.setLobbyMemberData(net.STEAM_LOBBY_ID, SYNC_KEY, _state_text())


func _say(role):
	my_role = role
	sync_dirty = true


func _parse(text):
	var b = str(text).split(";")
	if b.size() < 3 or b[0] != "1" or b[1] == "":
		return null
	var s = {"round": b[1], "role": b[2], "n": -1, "target": 0, "t": 0.0, "kind": "tag", "infect": true}
	if s["role"].begins_with("hs"):
		s["kind"] = "hide"
		s["role"] = s["role"].substr(2)
	if s["role"] == "open":
		s["infect"] = not (b.size() > 4 and b[4] == "0")
	elif s["role"] == "go":
		if b.size() < 8:
			return null
		s["ids"] = []
		for id in b[3].split(","):
			if id.is_valid_integer() and int(id) > 0:
				s["ids"].append(int(id))
		s["duration"] = clamp(float(b[4]), 30.0, 900.0)
		s["n"] = int(b[5])
		s["target"] = int(b[6])
		s["t"] = float(b[7])
		s["infect"] = not (b.size() > 8 and b[8] == "0")
	elif s["role"] == "play":
		if b.size() < 6:
			return null
		s["n"] = int(b[3])
		s["target"] = int(b[4])
		s["t"] = float(b[5])
	elif s["role"] != "join":
		return null
	return s


func _read_states(lobby, me):
	states = {}
	if me > 0:
		var mine = _parse(_state_text())
		if mine != null:
			states[me] = mine
	if lobby <= 0 or steam == null or not steam.has_method("getLobbyMemberData"):
		return
	for player in get_tree().get_nodes_in_group("player"):
		var id = player.get("owner_id")
		if id == null or int(id) <= 0 or int(id) == me:
			continue
		var s = _parse(steam.getLobbyMemberData(lobby, int(id), SYNC_KEY))
		if s != null:
			states[int(id)] = s


func _round_host(round_id):
	var bits = round_id.split("x")
	return int(bits[0]) if bits.size() > 0 and bits[0].is_valid_integer() else 0


# what everyone says, gathered into rounds: who plays, and every tag seen so far
func _update_rounds(me):
	for id in states.keys():
		var s = states[id]
		var r = s["round"]
		if _round_host(r) <= 0:
			continue
		if not rounds.has(r):
			rounds[r] = {"host": _round_host(r), "kind": s["kind"], "open_at": -1.0, "go_at": -1.0, "ids": [],
				"duration": ROUND_TIME, "events": {}, "ended": false, "infect": true,
				"count": HIDE_TIME if s["kind"] == "hide" else COUNTDOWN}
		var round_ = rounds[r]
		if id == round_["host"] and s["role"] in ["open", "go"]:
			round_["infect"] = s["infect"]
		if s["role"] == "open" and id == round_["host"] and round_["open_at"] < 0:
			round_["open_at"] = clock
			round_["kind"] = s.get("kind", "tag")
		if s["role"] == "go" and id == round_["host"]:
			if round_["go_at"] < 0:
				round_["go_at"] = clock
			round_["ids"] = s["ids"]
			round_["duration"] = s["duration"]
		if s["role"] in ["go", "play"] and s["n"] >= 0 and not round_["events"].has(s["n"]):
			round_["events"][s["n"]] = {"target": s["target"], "t": s["t"], "by": id}
			if s["n"] == 0 and round_["go_at"] >= 0:
				last_picked = int(s["target"])
			if round_["go_at"] >= 0 and r == my_round and s["n"] > 0 and id != me:
				if round_["kind"] == "hide":
					if s["target"] != me:
						_show_toast(_name_of(id) + " found " + _name_of(s["target"]) + "!")
				else:
					_show_toast(_name_of(id) + " tagged " + _name_of(s["target"]) + "!")
	# forget rounds long over, or that never got going
	for r in rounds.keys():
		var round_ = rounds[r]
		var since = round_["go_at"] if round_["go_at"] >= 0 else round_["open_at"]
		var life = round_["count"] + round_["duration"] + RESULTS_TIME + 30.0 if round_["go_at"] >= 0 else JOIN_TIME + 20.0
		if r != my_round and (since < 0 or clock - since > life):
			rounds.erase(r)


# round time: below 0 during the countdown
func _round_time(round_):
	if round_["go_at"] < 0:
		return -999.0
	return clock - round_["go_at"] - round_.get("count", COUNTDOWN)


func _current_it(round_):
	var best = -1
	for n in round_["events"].keys():
		if n > best:
			best = n
	return round_["events"][best]["target"] if best >= 0 else 0


func _top_n(round_):
	var best = -1
	for n in round_["events"].keys():
		best = max(best, n)
	return best


# still playing: anyone whose own word says they are in this round (or me)
func _active(round_id, round_, me):
	var out = []
	for id in round_["ids"]:
		if id == me and my_round == round_id:
			out.append(id)
		elif states.has(id) and states[id]["round"] == round_id:
			out.append(id)
	return out


# --- my round ---

func start_tag():
	_start_game("tag")


func start_hide():
	_start_game("hide")


func _start_game(kind):
	var net = get_node_or_null("/root/Network")
	var me = int(net.STEAM_ID) if net != null else 0
	if me <= 0 or my_round != "":
		return
	my_count += 1
	my_kind = kind
	my_infect = infect_choice
	my_round = str(me) + "x" + str(OS.get_unix_time() % 100000) + str(my_count)
	my_ids = []
	my_n = -1
	my_since = clock
	started = false
	answered[my_round] = true
	_say("open")
	_flush_state()
	_close_menu()
	_show_toast(GAME_NAMES[kind] + "! Waiting for players to join...")


func leave_round():
	if my_round == "":
		return
	_restore_speeds()
	_clear_mine()
	_show_toast("You left the round.")


func _clear_mine():
	_show_tags()
	find_target = 0
	_set_find_flag(false)
	my_round = ""
	my_role = ""
	my_ids = []
	my_n = -1
	started = false
	it_gone_since = -1.0
	tagged_by = 0
	sync_dirty = true


func _update_my_round(players, me):
	wait_panel.visible = false
	bar.visible = false
	big.visible = false
	hint.visible = false
	blackout.visible = false
	find_prompt.visible = false
	big.rect_scale = Vector2(3.5, 3.5)
	results.visible = results_until > clock
	if my_round == "":
		return
	var round_ = rounds.get(my_round)

	# starting it: collecting players
	if my_role == "open":
		var left = JOIN_TIME - (clock - my_since)
		var joined = []
		for id in states.keys():
			if id != me and states[id]["round"] == my_round and states[id]["role"] == "join":
				joined.append(id)
		wait_panel.visible = _hud_free()
		wait_label.text = GAME_NAMES[my_kind] + " starts in " + str(int(ceil(max(left, 0.0)))) + "s   " + str(joined.size()) + (" player joined" if joined.size() == 1 else " players joined")
		_place_top(wait_panel, 0.18)
		if left <= 0.0:
			if joined.empty():
				_show_toast("Nobody joined the round of " + GAME_NAMES[my_kind] + ".")
				_clear_mine()
				return
			my_ids = [me] + joined
			my_duration = SEEK_TIME if my_kind == "hide" else ROUND_TIME
			my_n = 0
			# random, but not whoever was picked last round (when there is anyone else to pick)
			var pool = []
			for id in my_ids:
				if int(id) != last_picked:
					pool.append(id)
			if pool.empty():
				pool = my_ids
			my_target = pool[randi() % pool.size()]
			last_picked = int(my_target)
			my_t = 0.0
			_say("go")
			_flush_state()
		return

	if round_ == null:
		# joined, still waiting to hear it's on
		if my_role == "join" and clock - my_since > JOIN_TIME + 15.0:
			_clear_mine()
		return

	if round_["go_at"] < 0:
		if my_role == "join" and clock - my_since > JOIN_TIME + 15.0:
			_show_toast("The round of " + GAME_NAMES[my_kind] + " didn't start.")
			_clear_mine()
		return
	if not me in round_["ids"]:
		_show_toast("Too late, that round of " + GAME_NAMES[my_kind] + " already started.")
		_clear_mine()
		return

	if my_role == "join":
		_say("play")
	if not started:
		started = true
		_go_to_spawn()

	if round_["kind"] == "hide":
		_run_hide(round_, players, me)
		return

	var t = _round_time(round_)
	var duration = round_["duration"]
	var active = _active(my_round, round_, me)
	var it = _current_it(round_)
	if it != last_it:
		if it == me:
			it_since_t = max(t, 0.0)
			tagged_by = _tagger_of(round_, it)
			if t >= 0.0:
				_notify("You're it!")
		last_it = it

	# everyone else left: the round is over early
	if t >= 0.0 and active.size() < 2 and not round_["ended"]:
		round_["ended"] = true
		round_["end_t"] = t
		_finish(round_, me)
		return
	if t >= duration and not round_["ended"]:
		round_["ended"] = true
		round_["end_t"] = duration
		_finish(round_, me)
		return

	_apply_speed(players.get(me), (0.0 if t < 0.0 else IT_SPEED) if it == me else 1.0)

	# the countdown, then the clock and who is "it" up top
	if t < 0.0:
		big.visible = true
		big.text = str(int(ceil(-t)))
		_place_top(big, 0.32)
		# and what to do about it, a little smaller underneath
		hint.visible = true
		if it == me:
			hint.text = "You're it! Wait for the count, then chase them down"
		else:
			hint.text = "RUN! " + _name_of(it) + " is it and starts chasing in " + str(int(ceil(-t))) + "..."
		hint.add_color_override("font_color", Color(1.0, 0.85, 0.5) if it == me else Color(1, 1, 1))
		_place_top(hint, 0.42)
		if it == me:
			_place_bar("Tag  -  You're it! Count to five...", true)
		else:
			_place_bar("Tag  -  " + _name_of(it) + " is it. Run!", false)
		return
	if t < 1.0:
		big.visible = true
		big.text = "GO!"
		_place_top(big, 0.32)
		hint.visible = true
		hint.text = "Go get them!" if it == me else _name_of(it) + " is coming!"
		_place_top(hint, 0.42)
	var left = max(duration - t, 0.0)
	var time_text = "%d:%02d" % [int(left) / 60, int(left) % 60]
	if it == me:
		_place_bar("Tag  " + time_text + "   You're it!", true)
	else:
		_place_bar("Tag  " + time_text + "   " + _name_of(it) + " is it", false)

	# "it" is gone: the lowest id still playing picks someone new
	if not it in active:
		if it_gone_since < 0.0:
			it_gone_since = clock
		elif clock - it_gone_since > GONE_GRACE and not active.empty() and active.min() == me:
			var pick = active[randi() % active.size()]
			_publish_tag(round_, pick, t)
			it_gone_since = -1.0
		return
	it_gone_since = -1.0

	# I'm "it": touch someone
	if it == me and players.has(me):
		var here = players[me].global_transform.origin
		var s_me = _player_size(players[me])
		for id in active:
			if id == me or not players.has(id):
				continue
			if id == tagged_by and t - it_since_t < NO_TAG_BACK:
				continue
			var there = players[id].global_transform.origin
			var reach = TAG_RANGE * (s_me + _player_size(players[id])) / 2.0
			if _flat(there - here).length() <= reach and abs(there.y - here.y) <= TAG_HEIGHT:
				_publish_tag(round_, id, t)
				_show_toast("You tagged " + _name_of(id) + "!")
				break


func _tagger_of(round_, target):
	var best = -1
	for n in round_["events"].keys():
		if round_["events"][n]["target"] == target and n > best:
			best = n
	return round_["events"][best]["by"] if best > 0 else 0


func _publish_tag(round_, target, t):
	var net = get_node_or_null("/root/Network")
	var me = int(net.STEAM_ID) if net != null else 0
	my_n = _top_n(round_) + 1
	my_target = target
	my_t = t
	round_["events"][my_n] = {"target": target, "t": t, "by": me}
	sync_dirty = true
	_flush_state()


func _go_to_spawn():
	var pd = get_node_or_null("/root/PlayerData")
	if pd != null and pd.has_signal("_return_to_spawn"):
		pd.emit_signal("_return_to_spawn")


# how long each player was "it", least first
func _scores(round_, end_t):
	var times = {}
	for id in round_["ids"]:
		times[id] = 0.0
	var ns = round_["events"].keys()
	ns.sort()
	for i in range(ns.size()):
		var e = round_["events"][ns[i]]
		var from = clamp(e["t"], 0.0, end_t)
		var to = end_t
		if i + 1 < ns.size():
			to = clamp(round_["events"][ns[i + 1]]["t"], from, end_t)
		times[e["target"]] = times.get(e["target"], 0.0) + max(to - from, 0.0)
	var list = []
	for id in times.keys():
		list.append([times[id], id])
	list.sort_custom(self, "_by_time")
	return list


func _duration_text(seconds):
	if seconds < 60.0:
		return "%.1fs" % seconds
	return "%d:%02d" % [int(seconds) / 60, int(seconds) % 60]


func _by_time(a, b):
	return a[0] < b[0]


func _finish(round_, me):
	_restore_speeds()
	results_title.text = "Tag is over! Least time as it wins"
	var list = _scores(round_, round_.get("end_t", round_["duration"]))
	for child in results_list.get_children():
		results_list.remove_child(child)
		child.queue_free()
	var place = 1
	for entry in list:
		var line = Label.new()
		var name = _name_of(entry[1])
		if entry[1] == me:
			name += " (you)"
		line.text = str(place) + ".  " + name + "  -  " + _duration_text(entry[0]) + " as it"
		line.add_color_override("font_color", Color(1.0, 0.92, 0.55) if place == 1 else Color(1, 1, 1))
		results_list.add_child(line)
		place += 1
	results_until = clock + RESULTS_TIME
	results.visible = true
	results.rect_size = Vector2()
	_place_top(results, 0.2)
	if not list.empty():
		_notify(_name_of(list[0][1]) + " wins the round of tag!")
	_clear_mine()


# --- hide and seek ---
# Same rounds as tag: the starter's tag 0 picks the first seeker, and every later "tag" is a find
# (n, the hider found, when, and by whom). The seekers are the first one plus, when found hiders join the
# seekers, everyone found so far. Otherwise found hiders are out and watch.

func _game_phrase(round_):
	if round_["kind"] == "hide":
		return "Hide and Seek" + (" (found hiders become seekers)" if round_["infect"] else " (found hiders are out)")
	return "a round of Tag"


func _hide_info(round_):
	var ns = round_["events"].keys()
	ns.sort()
	var first = 0
	var found = {}               # hider -> [round time found, by whom]
	for n in ns:
		var e = round_["events"][n]
		if n == 0:
			first = e["target"]
		elif not found.has(e["target"]) and e["target"] != first:
			found[e["target"]] = [e["t"], e["by"]]
	var seekers = [first] if first != 0 else []
	if round_["infect"]:
		for id in found.keys():
			seekers.append(id)
	return {"first": first, "found": found, "seekers": seekers}


func _run_hide(round_, players, me):
	var t = _round_time(round_)
	var duration = round_["duration"]
	var active = _active(my_round, round_, me)
	var info = _hide_info(round_)
	var seekers = info["seekers"]
	var found = info["found"]
	var first = info["first"]
	var i_seek = me in seekers
	var i_out = found.has(me) and not round_["infect"]
	var hiders_left = []
	var seekers_on = []
	for id in active:
		if id in seekers:
			seekers_on.append(id)
		elif not found.has(id):
			hiders_left.append(id)

	# over: everyone found, every seeker gone, or time's up
	if t >= 0.0 and not round_["ended"]:
		var winner = ""
		if hiders_left.empty():
			winner = "seekers"
		elif seekers_on.empty() or t >= duration:
			winner = "hiders"
		if winner != "":
			round_["ended"] = true
			round_["end_t"] = min(t, duration)
			_finish_hide(round_, me, info, winner)
			return

	# I just got found
	var told = last_found.get(my_round, {})
	if found.has(me) and not told.has(me):
		told[me] = true
		last_found[my_round] = told
		var by = _name_of(found[me][1])
		_notify("You were found by " + by + "! " + ("Now help find the others." if round_["infect"] else "You're out, watch the rest."))

	# the first seeker keeps their eyes shut and stays put while the others hide
	var counting = t < 0.0 and me == first
	_apply_speed(players.get(me), 0.0 if counting else 1.0)
	blackout.visible = counting
	if counting:
		blackout.rect_size = blackout.get_viewport_rect().size

	if t < 0.0:
		big.visible = true
		big.text = str(int(ceil(-t)))
		_place_top(big, 0.32)
		hint.visible = true
		if counting:
			hint.text = "You're the seeker! Eyes closed... count to " + str(int(round_["count"]))
			_place_bar("Hide and Seek  -  You're seeking. Counting...", true)
		else:
			hint.text = "HIDE! " + _name_of(first) + " starts looking in " + str(int(ceil(-t))) + "..."
			_place_bar("Hide and Seek  -  " + _name_of(first) + " is seeking. Hide!", false)
		hint.add_color_override("font_color", Color(1.0, 0.85, 0.5) if counting else Color(1, 1, 1))
		_place_top(hint, 0.42)
		_show_tags()
		return
	if t < 1.5:
		big.visible = true
		big.text = "Ready or not!"
		big.rect_scale = Vector2(2.2, 2.2)
		_place_top(big, 0.32)
		hint.visible = true
		hint.text = "Go find them!" if i_seek else _name_of(first) + " is coming..."
		_place_top(hint, 0.42)
	else:
		big.rect_scale = Vector2(3.5, 3.5)
	var left = max(duration - t, 0.0)
	var time_text = "%d:%02d" % [int(left) / 60, int(left) % 60]
	var n_left = str(hiders_left.size()) + (" hider left" if hiders_left.size() == 1 else " hiders left")
	if i_seek:
		_place_bar("Hide and Seek  " + time_text + "   You're seeking  -  " + n_left, true)
	elif i_out:
		_place_bar("Hide and Seek  " + time_text + "   You're out  -  " + n_left, false)
	else:
		_place_bar("Hide and Seek  " + time_text + "   Stay hidden!  -  " + n_left, false)

	# a seeker doesn't get to read the hiders' names
	if i_seek:
		_hide_tags(hiders_left, players)
	else:
		_show_tags()

	# a seeker near a hider: "F  Found!"
	find_target = 0
	if i_seek and players.has(me) and _hud_free():
		var here = players[me].global_transform.origin
		var s_me = _player_size(players[me])
		var best = 999.0
		for id in hiders_left:
			if id == me or not players.has(id):
				continue
			var there = players[id].global_transform.origin
			var d = _flat(there - here).length()
			var reach = FIND_RANGE * (s_me + _player_size(players[id])) / 2.0
			if d <= reach and abs(there.y - here.y) <= FIND_HEIGHT and d < best:
				best = d
				find_target = id
		if find_target != 0:
			_place_at_world(find_prompt, _over_head(players[find_target]))
	_set_find_flag(find_target != 0)


func _found_pressed():
	var round_ = rounds.get(my_round)
	if round_ == null or find_target == 0:
		return
	var who = find_target
	_publish_tag(round_, who, _round_time(round_))
	find_target = 0
	find_prompt.visible = false
	_show_toast("You found " + _name_of(who) + "!")


func _finish_hide(round_, me, info, winner):
	_restore_speeds()
	_show_tags()
	blackout.visible = false
	for child in results_list.get_children():
		results_list.remove_child(child)
		child.queue_free()
	results_title.text = "The seekers found everyone!" if winner == "seekers" else "The hiders win!"
	var found = info["found"]
	var never = []
	var caught = []
	for id in round_["ids"]:
		if id == info["first"]:
			continue
		if found.has(id):
			caught.append([found[id][0], id])
		else:
			never.append(id)
	caught.sort_custom(self, "_by_time")
	caught.invert()                # found last first: they hid best
	for id in never:
		_result_line(id, "never found!", true, me)
	for entry in caught:
		_result_line(entry[1], "found after " + _duration_text(entry[0]) + " by " + _name_of(found[entry[1]][1]), false, me)
	if info["first"] != 0:
		_result_line(info["first"], "seeker", false, me)
	results_until = clock + RESULTS_TIME
	results.visible = true
	results.rect_size = Vector2()
	_place_top(results, 0.2)
	_notify(results_title.text)
	_clear_mine()


func _result_line(id, what, gold, me):
	var line = Label.new()
	var name = _name_of(id) + (" (you)" if id == me else "")
	line.text = name + "  -  " + what
	line.add_color_override("font_color", Color(1.0, 0.92, 0.55) if gold else Color(1, 1, 1))
	results_list.add_child(line)


# hiders' names (and titles) over their heads are hidden from a seeker, and put back afterwards.
# The name tag mesh ("title") is moved out of the player into the world when it spawns and the game sets its
# visibility every frame, so the text itself is hidden instead: it is drawn by the player's own Viewport
# (Viewport/player_label, name and title in its VBoxContainer). Speech bubbles stay, talking gives you away.
func _hide_tags(ids, players):
	for id in hidden_tags.keys():
		if not id in ids:
			_show_tag(id)
	for id in ids:
		if hidden_tags.has(id) or not players.has(id):
			continue
		var tag = _name_tag(players[id])
		if tag != null:
			tag.visible = false
			hidden_tags[id] = tag


func _name_tag(player):
	var tag = player.get_node_or_null("Viewport/player_label/VBoxContainer")
	if tag == null:
		var label = player.get("title")
		if label is CanvasItem:
			tag = label
	return tag if tag is CanvasItem else null


func _show_tag(id):
	var tag = hidden_tags.get(id)
	if tag != null and is_instance_valid(tag):
		tag.visible = true
	hidden_tags.erase(id)


func _show_tags():
	for id in hidden_tags.keys():
		_show_tag(id)


# lets Hugs and More know F is taken right now (it doesn't offer its own F prompt then)
func _set_find_flag(on):
	var root = get_tree().root if get_tree() != null else null
	if root != null:
		root.set_meta("playground_f", on)


func _on_infect_toggled(on):
	infect_choice = on
	_save_config()


func _over_head(player):
	var size = _player_size(player)
	var top = player.global_transform.origin + Vector3.UP * 2.2 * size
	var sk = player.get_node_or_null(SKELETON_PATH)
	if sk != null and sk.find_bone("head") >= 0:
		top = sk.global_transform.xform(sk.get_bone_global_pose(sk.find_bone("head")).origin) + Vector3.UP * 1.7 * size
	return top


# a box on screen just above a point in the world
func _place_at_world(control, world_pos):
	var players = get_tree().get_nodes_in_group("controlled_player")
	var view = players[0].get_viewport() if not players.empty() else null
	var camera = view.get_camera() if view != null else null
	if camera == null or camera.is_position_behind(world_pos):
		control.visible = false
		return
	var at = camera.unproject_position(world_pos)
	var holder = view.get_parent()
	if holder is ViewportContainer and view.size.x > 0 and view.size.y > 0:
		var box = holder.get_global_rect()
		at = box.position + at * (box.size / view.size)
	control.visible = true
	control.rect_size = Vector2()
	var size = control.get_combined_minimum_size() * control.rect_scale
	control.rect_position = Vector2(at.x - size.x / 2.0, at.y - size.y)


# --- running faster, and standing still for the countdown ---

func _apply_speed(player, mult):
	if player == null or not is_instance_valid(player):
		return
	if speed_owner != player:
		_restore_speeds()
		speed_owner = player
		base_speeds = {}
		for v in SPEED_VARS + ["jump_height"]:
			if player.get(v) != null:
				base_speeds[v] = player.get(v)
	for v in base_speeds.keys():
		var want = base_speeds[v] * mult if v != "jump_height" else (0.0 if mult == 0.0 else base_speeds[v])
		if player.get(v) != want:
			player.set(v, want)


func _restore_speeds():
	if speed_owner != null and is_instance_valid(speed_owner):
		for v in base_speeds.keys():
			speed_owner.set(v, base_speeds[v])
	speed_owner = null
	base_speeds = {}


# --- the star over "it" ---

func _update_icons(players):
	var want = {}
	var net = get_node_or_null("/root/Network")
	var me = int(net.STEAM_ID) if net != null else 0
	for r in rounds.keys():
		var round_ = rounds[r]
		if round_["go_at"] < 0 or round_["ended"] or round_["kind"] != "tag":
			continue
		var t = _round_time(round_)
		if t >= round_["duration"]:
			continue
		# only while the round is really still on: "it" is still playing, and so is someone to chase
		var active = _active(r, round_, me)
		if active.size() < 2:
			if t >= 0.0 and r != my_round:
				round_["ended"] = true   # everyone left: it's over, for those watching too
			continue
		var it = _current_it(round_)
		if it > 0 and it in active and players.has(it):
			want[it] = players[it]
	for id in icons.keys():
		if not want.has(id) or not is_instance_valid(icons[id]) or icons[id].get_parent() != want[id]:
			if is_instance_valid(icons[id]):
				icons[id].queue_free()
			icons.erase(id)
	for id in want.keys():
		if not icons.has(id):
			icons[id] = _make_icon()
			want[id].add_child(icons[id])
		var icon = icons[id]
		var player = want[id]
		var size = _player_size(player)
		var top = player.global_transform.origin + Vector3.UP * 2.6 * size
		var sk = player.get_node_or_null(SKELETON_PATH)
		if sk != null and sk.find_bone("head") >= 0:
			top = sk.global_transform.xform(sk.get_bone_global_pose(sk.find_bone("head")).origin) + Vector3.UP * 1.9 * size
		icon.global_transform = Transform(Basis().scaled(Vector3.ONE * size * (1.0 + 0.08 * sin(clock * 5.0))), top)


func _make_icon():
	var holder = Spatial.new()
	holder.name = "PlaygroundIt"
	var glow = Sprite3D.new()
	glow.texture = glow_texture
	glow.pixel_size = 0.016
	glow.billboard = SpatialMaterial.BILLBOARD_ENABLED
	glow.shaded = false
	glow.double_sided = true
	glow.modulate = Color(1, 1, 1, 0.75)
	glow.material_override = _sprite_material(glow_texture, true)
	holder.add_child(glow)
	var star = Sprite3D.new()
	star.texture = star_texture
	star.pixel_size = 0.0085
	star.billboard = SpatialMaterial.BILLBOARD_ENABLED
	star.shaded = false
	star.double_sided = true
	holder.add_child(star)
	return holder


func _sprite_material(tex, add):
	var m = SpatialMaterial.new()
	m.flags_unshaded = true
	m.flags_transparent = true
	m.params_billboard_mode = SpatialMaterial.BILLBOARD_ENABLED
	m.albedo_texture = tex
	m.albedo_color = Color(1, 1, 1, 1)
	m.vertex_color_use_as_albedo = true
	if add:
		m.params_blend_mode = SpatialMaterial.BLEND_MODE_ADD
	return m


# a white five-pointed star and a soft round glow, drawn here so the mod needs no image files
func _make_textures():
	var n = 128
	var star = Image.new()
	star.create(n, n, false, Image.FORMAT_RGBA8)
	var glow = Image.new()
	glow.create(n, n, false, Image.FORMAT_RGBA8)
	star.lock()
	glow.lock()
	var c = Vector2(n / 2.0, n / 2.0)
	var pts = []
	for i in range(10):
		var r = n * (0.46 if i % 2 == 0 else 0.2)
		var a = -PI / 2.0 + i * PI / 5.0
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	for y in range(n):
		for x in range(n):
			var p = Vector2(x + 0.5, y + 0.5)
			var inside = Geometry.is_point_in_polygon(p, PoolVector2Array(pts))
			var edge = 1.0
			if not inside:
				# soften the outline a little
				var d = 99.0
				for i in range(10):
					d = min(d, _seg_dist(p, pts[i], pts[(i + 1) % 10]))
				edge = clamp(1.0 - d / 1.5, 0.0, 1.0)
			star.set_pixel(x, y, Color(1, 1, 1, edge))
			var g = clamp(1.0 - p.distance_to(c) / (n * 0.5), 0.0, 1.0)
			glow.set_pixel(x, y, Color(1, 1, 1, g * g))
	star.unlock()
	glow.unlock()
	star_texture = ImageTexture.new()
	star_texture.create_from_image(star)
	glow_texture = ImageTexture.new()
	glow_texture.create_from_image(glow)


func _seg_dist(p, a, b):
	var ab = b - a
	var t = clamp((p - a).dot(ab) / max(ab.length_squared(), 0.0001), 0.0, 1.0)
	return p.distance_to(a + ab * t)


# --- the invitation ---

func _update_invite(me):
	var show = ""
	if my_round == "":
		for r in rounds.keys():
			var round_ = rounds[r]
			if round_["host"] == me or answered.has(r) or round_["go_at"] >= 0 or round_["open_at"] < 0:
				continue
			if clock - round_["open_at"] < JOIN_TIME and states.has(round_["host"]) and states[round_["host"]]["role"] == "open":
				show = r
				break
	if show != invite_round:
		invite_round = show
		if show != "":
			_notify(_name_of(rounds[show]["host"]) + " is starting " + _game_phrase(rounds[show]) + "! Press Y to join.")
	if invite_round == "":
		invite_panel.visible = false
		return
	var left = JOIN_TIME - (clock - rounds[invite_round]["open_at"])
	invite_label.text = _name_of(rounds[invite_round]["host"]) + " is starting " + _game_phrase(rounds[invite_round]) + "!"
	invite_yes.text = "Join (Y)  " + str(int(ceil(max(left, 0.0)))) + "s"
	invite_panel.visible = _hud_free()
	_place_top(invite_panel, 0.18)


func _on_join():
	if invite_round == "" or my_round != "":
		return
	answered[invite_round] = true
	my_round = invite_round
	my_kind = rounds[invite_round]["kind"]
	my_infect = rounds[invite_round]["infect"]
	my_since = rounds[invite_round]["open_at"]
	my_n = -1
	started = false
	_say("join")
	_flush_state()
	invite_round = ""
	invite_panel.visible = false
	_show_toast("You joined! Get ready...")


func _on_decline():
	if invite_round != "":
		answered[invite_round] = true
		invite_round = ""
		invite_panel.visible = false


# --- keys ---

func _input(event):
	# dragging the button is followed here, so it keeps going when the mouse leaves it
	if star_pressed:
		if event is InputEventMouseMotion:
			var mouse = event.position
			if not star_dragging and mouse.distance_to(press_pos) > 4.0:
				star_dragging = true
			if star_dragging:
				var area = get_viewport().get_visible_rect().size
				var pos = mouse + drag_offset
				pos.x = clamp(pos.x, 0, max(0, area.x - star_button.rect_size.x))
				pos.y = clamp(pos.y, 0, max(0, area.y - star_button.rect_size.y))
				star_button.rect_position = pos
				_place_menu()
		elif event is InputEventMouseButton and event.button_index == BUTTON_LEFT and not event.pressed:
			star_pressed = false
			if star_dragging:
				star_dragging = false
				_save_config()
			elif menu.visible:
				_close_menu()
			else:
				_open_menu()
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if _typing():
		return
	if event.scancode == JOIN_KEY and invite_round != "" and invite_panel.visible:
		_on_join()
		get_tree().set_input_as_handled()
	elif event.scancode == FIND_KEY and find_target != 0 and find_prompt.visible:
		_found_pressed()
		get_tree().set_input_as_handled()
	elif event.scancode == MENU_KEY:
		if menu.visible:
			_close_menu()
			get_tree().set_input_as_handled()
		elif _hud_free() and star_button.visible:
			_open_menu()
			get_tree().set_input_as_handled()
	elif event.scancode == KEY_ESCAPE and menu.visible:
		_close_menu()
		get_tree().set_input_as_handled()


func _open_menu():
	menu.visible = true
	_lock_hud()
	_update_menu()
	if star_button != null:
		star_button.update()


func _close_menu():
	if menu != null:
		menu.visible = false
	_unlock_hud()
	if star_button != null:
		star_button.update()


func _update_menu():
	if not menu.visible:
		return
	var busy = my_round != ""
	menu_tag.disabled = busy
	menu_hide.disabled = busy
	menu_infect.disabled = busy
	menu_leave.visible = busy
	menu_swing.text = "Pick up your swing set" if swing != null and swing.has_set() else "Place a swing set"
	if not busy:
		menu_status.text = "Play with everyone who has Playground."
	elif my_role == "open":
		menu_status.text = "Waiting for players to join..."
	else:
		menu_status.text = "You're in a round of " + GAME_NAMES[my_kind] + "."
	_place_menu()


# the menu opens beside the button, on whichever side has room
func _place_menu():
	if not menu.visible:
		return
	var area = get_viewport().get_visible_rect().size
	var size = menu.get_combined_minimum_size()
	menu.rect_size = size
	var pos = star_button.rect_position + Vector2(star_button.rect_size.x + 6, 0)
	if pos.x + size.x > area.x:
		pos.x = star_button.rect_position.x - size.x - 6
	pos.x = clamp(pos.x, 0, max(0, area.x - size.x))
	pos.y = clamp(pos.y, 0, max(0, area.y - size.y))
	menu.rect_position = pos


# --- the star button ---

func _draw_button():
	var box = star_button.rect_size
	var fill = Color(0.3, 1.0, 1.0, 0.30 if star_hover else 0.16)
	if menu.visible:
		fill = Color(0.3, 1.0, 1.0, 0.45)
	star_button.draw_style_box(_glass(fill, Color(0.55, 1.0, 1.0, 0.8 if star_hover else 0.5), 8, 0), Rect2(Vector2(), box))
	var mid = box / 2.0 + Vector2(0, 1)
	var pts = PoolVector2Array()
	for i in range(10):
		var r = 11.0 if i % 2 == 0 else 4.6
		var a = -PI / 2.0 + i * PI / 5.0
		pts.append(mid + Vector2(cos(a), sin(a)) * r)
	star_button.draw_colored_polygon(pts, Color(1, 1, 1, 0.95))


func _on_button_hover(inside):
	star_hover = inside
	star_button.update()


func _on_button_input(event):
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT and event.pressed:
		star_pressed = true
		star_dragging = false
		press_pos = event.global_position
		drag_offset = star_button.rect_position - press_pos
		star_button.accept_event()


# like the game's own hotbar: only there while none of the game's menus are open
func _refresh_button():
	var hud = _get_hud()
	var show = hud != null
	if show:
		if hud.get("menu") != 0 or hud.get("hud_hidden") == true:
			show = false
		var popups = hud.get("popups")
		if typeof(popups) == TYPE_ARRAY:
			for entry in popups:
				if entry != POPUP_ID:
					show = false
		var options = get_node_or_null("/root/OptionsMenu")
		if options != null and options.get("open") == true:
			show = false
	# everything in the game's own font, the same as the other mods
	if show and not theme_applied:
		theme_applied = true
		var main = hud.get_node_or_null("main")
		if main != null and main.theme != null:
			for control in [star_button, menu, invite_panel, wait_panel, bar, big, hint, results, toast, find_prompt] + themed:
				control.theme = main.theme
	if not show and menu.visible:
		_close_menu()
	if not show:
		star_pressed = false
		star_dragging = false
	star_button.visible = show


func _typing():
	var hud = _get_hud()
	if hud != null and hud.get("using_chat") == true:
		return true
	var focus = star_button.get_focus_owner() if star_button != null else null
	return focus != null and focus is LineEdit


func _load_config():
	var file = File.new()
	if not file.file_exists(CONFIG_PATH) or file.open(CONFIG_PATH, File.READ) != OK:
		return
	var data = parse_json(file.get_as_text())
	file.close()
	if typeof(data) == TYPE_DICTIONARY and data.has("x") and data.has("y"):
		star_button.rect_position = Vector2(float(data["x"]), float(data["y"]))
	if typeof(data) == TYPE_DICTIONARY and data.has("infect"):
		infect_choice = bool(data["infect"])
		menu_infect.pressed = infect_choice


func _save_config():
	var file = File.new()
	if file.open(CONFIG_PATH, File.WRITE) != OK:
		return
	file.store_string(to_json({"x": star_button.rect_position.x, "y": star_button.rect_position.y, "infect": infect_choice}))
	file.close()


func _add_tooltip(control, header, body):
	var scene = load("res://Scenes/Singletons/Tooltips/tooltip_node.tscn") if ResourceLoader.exists("res://Scenes/Singletons/Tooltips/tooltip_node.tscn") else null
	if scene == null or get_node_or_null("/root/Tooltip") == null:
		control.hint_tooltip = header
		return
	var tip = scene.instance()
	tip.header = "[color=#6a4420]" + header + "[/color]"
	tip.body = body
	tip.mouse_filter = Control.MOUSE_FILTER_PASS
	control.add_child(tip)


# --- the screen ---

func _build_ui():
	layer = CanvasLayer.new()
	layer.layer = 3
	add_child(layer)

	# the star button: click for the menu, drag to move it (J works too)
	star_button = Control.new()
	star_button.rect_size = Vector2(34, 34)
	star_button.rect_min_size = Vector2(34, 34)
	star_button.rect_position = DEFAULT_BUTTON_POS
	star_button.mouse_filter = Control.MOUSE_FILTER_STOP
	star_button.visible = false
	star_button.connect("draw", self, "_draw_button")
	star_button.connect("gui_input", self, "_on_button_input")
	star_button.connect("mouse_entered", self, "_on_button_hover", [true])
	star_button.connect("mouse_exited", self, "_on_button_hover", [false])
	layer.add_child(star_button)
	_add_tooltip(star_button, "Playground", "Click for games (or press J), drag to move this button")

	# the Playground menu
	menu = _panel(0.75)
	menu.visible = false
	menu.mouse_filter = Control.MOUSE_FILTER_STOP
	var column = _column(menu)
	var head = HBoxContainer.new()
	head.add_constant_override("separation", 8)
	column.add_child(head)
	var title = Label.new()
	title.text = "Playground"
	title.add_color_override("font_color", Color(0.75, 0.95, 1.0))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close = _button("x", "_close_menu")
	head.add_child(close)
	menu_status = Label.new()
	menu_status.add_color_override("font_color", Color(1, 1, 1, 0.8))
	column.add_child(menu_status)
	menu_tag = _button("Start a round of Tag", "start_tag")
	column.add_child(menu_tag)
	menu_hide = _button("Start Hide and Seek", "start_hide")
	column.add_child(menu_hide)
	menu_infect = CheckBox.new()
	menu_infect.text = "Found hiders join the seekers"
	menu_infect.pressed = infect_choice
	menu_infect.focus_mode = Control.FOCUS_NONE
	menu_infect.add_color_override("font_color", Color(1, 1, 1, 0.9))
	menu_infect.add_color_override("font_color_hover", Color(1, 1, 1))
	menu_infect.add_color_override("font_color_pressed", Color(1, 1, 1))
	menu_infect.connect("toggled", self, "_on_infect_toggled")
	_add_tooltip(menu_infect, "Hide and Seek", "On: found hiders become seekers and help find the rest. Off: found hiders are out and watch.")
	column.add_child(menu_infect)
	menu_leave = _button("Leave the round", "_on_leave_pressed")
	column.add_child(menu_leave)
	menu_swing = _button("Place a swing set", "_on_swing_pressed")
	column.add_child(menu_swing)

	# "<name> is starting a round of Tag!  [Join (Y) 9s]  [No thanks]"
	invite_panel = _panel(0.75)
	invite_panel.visible = false
	var row = HBoxContainer.new()
	row.add_constant_override("separation", 8)
	_margin(invite_panel).add_child(row)
	invite_label = Label.new()
	invite_label.add_color_override("font_color", Color(1, 1, 1))
	invite_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(invite_label)
	invite_yes = _button("Join (Y)", "_on_join")
	row.add_child(invite_yes)
	row.add_child(_button("No thanks", "_on_decline"))

	# the starter's "Tag starts in 7s, 2 players joined"
	wait_panel = _panel(0.7)
	wait_panel.visible = false
	wait_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wait_label = Label.new()
	wait_label.add_color_override("font_color", Color(1, 1, 1))
	_margin(wait_panel).add_child(wait_label)

	# the clock and who is "it", along the top
	bar = _panel(0.6)
	bar.visible = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar_label = Label.new()
	bar_label.add_color_override("font_color", Color(1, 1, 1))
	_margin(bar).add_child(bar_label)

	# the seeker's eyes, closed while the others hide (under the countdown numbers)
	blackout = ColorRect.new()
	blackout.color = Color(0.02, 0.03, 0.05, 1.0)
	blackout.visible = false
	blackout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(blackout)

	# "F  Found!" over a hider, for a seeker who is close enough
	find_prompt = _panel(0.55)
	find_prompt.visible = false
	find_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var frow = HBoxContainer.new()
	frow.add_constant_override("separation", 6)
	frow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	find_prompt.add_child(frow)
	var fkey = Label.new()
	fkey.text = "F"
	fkey.add_color_override("font_color", Color(0.55, 1.0, 1.0))
	frow.add_child(fkey)
	var fword = Label.new()
	fword.text = "Found!"
	fword.add_color_override("font_color", Color(1, 1, 1, 0.95))
	frow.add_child(fword)

	# the big countdown numbers
	big = Label.new()
	big.visible = false
	big.mouse_filter = Control.MOUSE_FILTER_IGNORE
	big.add_color_override("font_color", Color(1, 1, 1))
	big.add_color_override("font_color_shadow", Color(0, 0, 0, 0.8))
	big.add_constant_override("shadow_offset_x", 2)
	big.add_constant_override("shadow_offset_y", 2)
	big.rect_scale = Vector2(3.5, 3.5)
	big.align = Label.ALIGN_CENTER
	layer.add_child(big)

	# what to do during the countdown ("RUN! ... starts chasing in 4..."), under the numbers
	hint = Label.new()
	hint.visible = false
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.add_color_override("font_color", Color(1, 1, 1))
	hint.add_color_override("font_color_shadow", Color(0, 0, 0, 0.85))
	hint.add_constant_override("shadow_offset_x", 2)
	hint.add_constant_override("shadow_offset_y", 2)
	hint.rect_scale = Vector2(1.6, 1.6)
	hint.align = Label.ALIGN_CENTER
	layer.add_child(hint)

	# the scoreboard
	results = _panel(0.8)
	results.visible = false
	var rcol = _column(results)
	results_title = Label.new()
	results_title.text = "Tag is over! Least time as it wins"
	results_title.add_color_override("font_color", Color(0.75, 0.95, 1.0))
	rcol.add_child(results_title)
	results_list = VBoxContainer.new()
	results_list.add_constant_override("separation", 2)
	rcol.add_child(results_list)
	rcol.add_child(_button("Close", "_close_results"))

	toast = Label.new()
	toast.visible = false
	toast.add_color_override("font_color", Color(1, 1, 1))
	toast.add_color_override("font_color_shadow", Color(0, 0, 0, 0.8))
	toast.add_constant_override("shadow_offset_x", 1)
	toast.add_constant_override("shadow_offset_y", 1)
	toast.anchor_left = 0.5
	toast.anchor_right = 0.5
	toast.anchor_top = 0.26
	toast.anchor_bottom = 0.26
	toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	toast.align = Label.ALIGN_CENTER
	layer.add_child(toast)


func _on_swing_pressed():
	if swing.has_set():
		swing.remove_set()
	else:
		swing.place_set()
	_close_menu()


func _on_leave_pressed():
	leave_round()
	_close_menu()


func _close_results():
	results_until = -1.0
	results.visible = false


func _panel(alpha):
	var p = PanelContainer.new()
	p.add_stylebox_override("panel", _glass(Color(0.06, 0.12, 0.18, alpha), Color(0.55, 1.0, 1.0, 0.45), 10, 6))
	layer.add_child(p)
	return p


func _margin(panel):
	var m = MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_constant_override("margin_" + side, 8)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(m)
	return m


func _column(panel):
	var c = VBoxContainer.new()
	c.add_constant_override("separation", 6)
	_margin(panel).add_child(c)
	return c


func _button(text, method):
	var b = Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.connect("pressed", self, method)
	_glass_button(b)
	return b


# centred across the screen, this far down
func _place_top(control, down):
	control.rect_size = Vector2()
	var size = control.get_viewport_rect().size
	var own = control.get_combined_minimum_size() * control.rect_scale
	control.rect_position = Vector2((size.x - own.x) / 2.0, size.y * down - own.y / 2.0)


func _place_bar(text, is_it):
	bar.visible = _hud_free(true) or menu.visible
	bar_label.text = text
	bar_label.add_color_override("font_color", Color(1.0, 0.85, 0.5) if is_it else Color(1, 1, 1))
	_place_top(bar, 0.07)


func _show_toast(text):
	toast.text = text
	toast_until = clock + 3.0


# the game's own notification in the corner, and my line on screen
func _notify(text):
	_show_toast(text)
	var pd = get_node_or_null("/root/PlayerData")
	if pd != null and pd.has_method("_send_notification"):
		pd._send_notification(text)


func _flat(v):
	return Vector3(v.x, 0, v.z)


# --- helpers (shared with Hugs and More) ---


func _player_size(player):
	var sk = player.get_node_or_null(SKELETON_PATH)
	if sk != null:
		return sk.global_transform.basis.get_scale().y
	return player.global_transform.basis.get_scale().y


func _name_of(id):
	var net = get_node_or_null("/root/Network")
	if net != null:
		for member in net.get("LOBBY_MEMBERS") if net.get("LOBBY_MEMBERS") != null else []:
			if int(member.get("steam_id", 0)) == int(id):
				return str(member.get("steam_name", "someone"))
	if steam != null and steam.has_method("getFriendPersonaName"):
		return str(steam.getFriendPersonaName(int(id)))
	return "someone"


func _get_hud():
	var players = get_tree().get_nodes_in_group("controlled_player")
	if players.empty():
		return null
	var hud = players[0].get("hud")
	if hud == null or not is_instance_valid(hud):
		return null
	return hud


# nothing of the game's is open (my own picker window can be, when asked)
func _hud_free(allow_mine = false):
	var hud = _get_hud()
	if hud == null:
		return false
	if hud.get("menu") != 0 or hud.get("hud_hidden") == true or hud.get("using_chat") == true:
		return false
	var popups = hud.get("popups")
	if typeof(popups) == TYPE_ARRAY:
		for entry in popups:
			if not (allow_mine and entry == POPUP_ID):
				return false
	return true


# while the picker is open the game ignores its keys
func _lock_hud():
	var hud = _get_hud()
	if hud == null:
		return
	var popups = hud.get("popups")
	if typeof(popups) == TYPE_ARRAY and not popups.has(POPUP_ID):
		popups.append(POPUP_ID)
	locked_hud = hud


func _unlock_hud():
	if locked_hud != null and is_instance_valid(locked_hud):
		var popups = locked_hud.get("popups")
		if typeof(popups) == TYPE_ARRAY:
			popups.erase(POPUP_ID)
	locked_hud = null


# --- the invitation box ---


# the Wolfpark HUD's look: a see-through, softly outlined box, and its glassy buttons
func _glass(fill, edge, radius, shadow):
	var box = StyleBoxFlat.new()
	box.bg_color = fill
	box.border_color = edge
	box.set_border_width_all(1)
	box.set_corner_radius_all(radius)
	box.shadow_color = Color(0, 0, 0, 0.3)
	box.shadow_size = shadow
	box.content_margin_left = 8
	box.content_margin_right = 8
	box.content_margin_top = 3
	box.content_margin_bottom = 3
	return box


func _glass_button(button):
	var edge = Color(0.55, 1.0, 1.0, 0.5)
	button.add_stylebox_override("normal", _glass(Color(0.2, 0.9, 0.95, 0.16), edge, 8, 0))
	button.add_stylebox_override("hover", _glass(Color(0.3, 1.0, 1.0, 0.30), Color(0.8, 1.0, 1.0, 0.8), 8, 0))
	button.add_stylebox_override("pressed", _glass(Color(0.3, 1.0, 1.0, 0.45), Color(0.8, 1.0, 1.0, 0.9), 8, 0))
	button.add_stylebox_override("disabled", _glass(Color(0.5, 0.5, 0.5, 0.12), Color(0.7, 0.7, 0.7, 0.25), 8, 0))
	button.add_stylebox_override("focus", StyleBoxEmpty.new())
	button.add_color_override("font_color", Color(1, 1, 1))
	button.add_color_override("font_color_hover", Color(1, 1, 1))
	button.add_color_override("font_color_pressed", Color(1, 1, 1))
	button.add_color_override("font_color_disabled", Color(1, 1, 1, 0.4))

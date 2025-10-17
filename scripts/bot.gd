extends CharacterBody2D
# Agent loop: see -> next -> action -> act

enum Act {
	MOVE_TO_ING, TAKE_FROM_ING,
	MOVE_TO_CHOP, PLACE_ON_CHOP, CHOP,
	MOVE_TO_COOK, PLACE_ON_COOK, COOK,
	MOVE_TO_SERVE, PLACE_ON_SERVE, SERVE,
	NONE
}

@export var speed := 70.0
@export var accel := 800.0
@export var stop_distance := 50.0

var st_ing: Node
var st_chop: Node
var st_cook: Node
var st_serve: Node

# Visual component: the actual Ingredient node the bot carries (or null)
var carried_node: Node = null

var I := {
	"target": Vector2.ZERO,
	"carrying": "",    # human-friendly type/name for recipe logic (kept in sync when picking up)
	"phase": "to_ing"  # to_ing -> to_chop -> to_cook -> to_serve -> done
}

@onready var sprite = $Sprite2D
@onready var navigation_agent = $NavigationAgent2D

func _ready() -> void:
	find_stations_by_type()
	if not st_ing or not st_chop or not st_cook or not st_serve:
		push_error("Bot: could not find all 4 station types (ingredients/chop/cook/serve).")
		set_physics_process(false)
		return
	I.target = st_ing.global_position
	velocity = Vector2.ZERO
	print("[BOT] ready. phase=", I.phase)
	navigation_agent.target_desired_distance = stop_distance
	navigation_agent.path_desired_distance = stop_distance

func find_stations_by_type() -> void:
	var stations = get_tree().get_nodes_in_group("stations")
	for station in stations:
		match station.station_type:
			"Ingredient":
				st_ing = station
			"Chopping":
				st_chop = station
			"Cooking":
				st_cook = station
			"Serving":
				st_serve = station
	print("[BOT] Found stations - Ing:", st_ing != null, "Chop:", st_chop != null, "Cook:", st_cook != null, "Serve:", st_serve != null)

func _physics_process(delta: float) -> void:
	var per := see()
	next(I, per)
	var a: Act = action(I, per)
	act(a, delta)
	if sprite and velocity.x != 0:
		sprite.flip_h = velocity.x < 0
	move_and_slide()

# ---------- perception / planning ----------
func see() -> Dictionary:
	return {
		"bot_pos": global_position,
		"ing_pos": st_ing.global_position,
		"chop_pos": st_chop.global_position,
		"cook_pos": st_cook.global_position,
		"serve_pos": st_serve.global_position,
		"near_ing": global_position.distance_to(st_ing.global_position) <= stop_distance,
		"near_chop": global_position.distance_to(st_chop.global_position) <= stop_distance,
		"near_cook": global_position.distance_to(st_cook.global_position) <= stop_distance,
		"near_serve": global_position.distance_to(st_serve.global_position) <= stop_distance,
		"ing_has":  _station_has_item(st_ing),
		"chop_has": _station_has_item(st_chop),
		"cook_has": _station_has_item(st_cook),
		"serve_has":_station_has_item(st_serve),
	}

func next(state: Dictionary, per: Dictionary) -> void:
	match state.phase:
		"to_ing":   state.target = per.ing_pos
		"to_chop":  state.target = per.chop_pos
		"to_cook":  state.target = per.cook_pos
		"to_serve": state.target = per.serve_pos
		_:
			pass

func action(state: Dictionary, per: Dictionary) -> Act:
	# decisions now use carried_node (visual presence) instead of strings where appropriate
	match state.phase:
		"to_ing":
			if per.near_ing and carried_node == null: return Act.TAKE_FROM_ING
			return Act.MOVE_TO_ING

		"to_chop":
			if per.near_chop and carried_node != null and not per.chop_has: return Act.PLACE_ON_CHOP
			if per.near_chop and per.chop_has: return Act.CHOP
			return Act.MOVE_TO_CHOP

		"to_cook":
			if per.near_cook and carried_node != null and not per.cook_has: return Act.PLACE_ON_COOK
			if per.near_cook and per.cook_has: return Act.COOK
			return Act.MOVE_TO_COOK

		"to_serve":
			if per.near_serve and carried_node != null and not per.serve_has: return Act.PLACE_ON_SERVE
			if per.near_serve and per.serve_has: return Act.SERVE
			return Act.MOVE_TO_SERVE

		_:
			return Act.NONE

# ---------- actions ----------
func act(a: Act, delta: float) -> void:
	match a:
		# MOVE / TAKE INGREDIENT
		Act.MOVE_TO_ING:
			_seek(I.target, delta)

		Act.TAKE_FROM_ING:
			_call_interact(st_ing) # station spawns or prepares output
			var got := _take_item_from(st_ing)
			if got != null and typeof(got) == TYPE_OBJECT and got is Node:
				carried_node = got
				if carried_node.has_method("pick_up"):
					carried_node.pick_up(self, Vector2(0, -16))
				# update carrying type for recipe logic
				I.carrying = carried_node.get("type") if carried_node.has_method("get_type") else carried_node.name
				print("[BOT] took node:", carried_node.name)
				I.phase = "to_chop"
			else:
				print("[BOT ERROR] Failed to take item from ingredient station!")

		# PLACE ON CHOP / CHOP
		Act.MOVE_TO_CHOP:
			_seek(I.target, delta)

		Act.PLACE_ON_CHOP:
			if carried_node != null:
				if _place_item_on(st_chop, carried_node):
					print("[BOT] placed node on chop:", carried_node.name)
					# once placed, bot no longer carries node
					carried_node = null
					I.carrying = ""

		Act.CHOP:
			_call_interact(st_chop)  # station transforms item (may replace node)
			# pick up result node (station may have created a new node)
			var taken := _take_item_from(st_chop)
			if taken != null and typeof(taken) == TYPE_OBJECT and taken is Node:
				carried_node = taken
				if carried_node.has_method("pick_up"):
					carried_node.pick_up(self, Vector2(0, -16))
				I.carrying = carried_node.get("type") if carried_node.has_method("get_type") else carried_node.name
				I.phase = "to_cook"

		# PLACE ON COOK / COOK
		Act.MOVE_TO_COOK:
			_seek(I.target, delta)

		Act.PLACE_ON_COOK:
			if carried_node != null:
				if _place_item_on(st_cook, carried_node):
					print("[BOT] placed node on cook:", carried_node.name)
					carried_node = null
					I.carrying = ""

		Act.COOK:
			_call_interact(st_cook)
			var cooked := _take_item_from(st_cook)
			if cooked != null and typeof(cooked) == TYPE_OBJECT and cooked is Node:
				carried_node = cooked
				if carried_node.has_method("pick_up"):
					carried_node.pick_up(self, Vector2(0, -16))
				I.carrying = carried_node.get("type") if carried_node.has_method("get_type") else carried_node.name
				I.phase = "to_serve"

		# PLACE ON SERVE / SERVE
		Act.MOVE_TO_SERVE:
			_seek(I.target, delta)

		Act.PLACE_ON_SERVE:
			if carried_node != null:
				if _place_item_on(st_serve, carried_node):
					print("[BOT] placed node on serve:", carried_node.name)
					carried_node = null
					I.carrying = ""

		Act.SERVE:
			_call_interact(st_serve)
			# served: station will usually consume or spawn something
			# ensure we don't carry stale visuals
			if carried_node != null and is_instance_valid(carried_node):
				carried_node.queue_free()
			carried_node = null
			I.carrying = ""
			I.phase = "done"

		Act.NONE:
			velocity = velocity.move_toward(Vector2.ZERO, accel * delta)

# ---------- movement ----------
func _seek(target: Vector2, delta: float) -> void:
	var to_target: Vector2 = target - global_position
	var desired: Vector2 = (to_target.normalized() * speed) if to_target.length() > 0.001 else Vector2.ZERO
	if to_target.length() <= stop_distance:
		velocity = velocity.move_toward(Vector2.ZERO, accel * delta)
	else:
		velocity = velocity.move_toward(desired, accel * delta)

# ---------- station helpers ----------
func _call_interact(s: Node) -> void:
	if s and s.has_method("interact"):
		s.interact()

func _station_has_item(s: Node) -> bool:
	if s == null:
		return false
	# prefer node-based check
	if "current_ingredient" in s:
		return s.current_ingredient != null
	# fallback to legacy string
	if "current_item" in s:
		return s.current_item != ""
	return false

func _get_current_item(s: Node) -> String:
	if s == null:
		return ""
	if "current_ingredient" in s and s.current_ingredient != null:
		var n = s.current_ingredient
		if n.has_method("get_type"):
			return String(n.get("type"))
		return String(n.name)
	if "current_item" in s:
		return String(s.current_item)
	return ""

func _set_current_item(s: Node, v: String) -> void:
	if s and "current_item" in s:
		s.current_item = v
		if s.has_method("update_appearance"):
			s.update_appearance()

# Return Node if station provides it. If station returns a string, attempt to spawn a visual via GameManager.
func _take_item_from(s: Node) -> Node:
	if s == null:
		return null
	if s.has_method("take_item"):
		var ret = s.take_item()
		# station returned a node
		if typeof(ret) == TYPE_OBJECT and ret is Node:
			return ret
		# station returned a string type -> try to ask gm to spawn a visual node of that type
		if typeof(ret) == TYPE_STRING:
			var gm = get_tree().get_first_node_in_group("game_manager")
			if gm and gm.has_method("spawn_ingredient"):
				var node = gm.spawn_ingredient(String(ret), null)
				# immediately return the new node (caller will pick it up)
				return node
			# otherwise, nothing we can carry
			return null

	# fallback to direct field
	if "current_ingredient" in s and s.current_ingredient != null:
		var n = s.current_ingredient
		s.current_ingredient = null
		if s.has_method("update_appearance"):
			s.update_appearance()
		return n

	# legacy string-only station
	if "current_item" in s and s.current_item != "":
		# try spawn visual
		var gm2 = get_tree().get_first_node_in_group("game_manager")
		if gm2 and gm2.has_method("spawn_ingredient"):
			var node2 = gm2.spawn_ingredient(String(s.current_item), null)
			# clear legacy field
			s.current_item = ""
			if s.has_method("update_appearance"):
				s.update_appearance()
			return node2
		# can't return a node
		return null

	return null

func _place_item_on(s: Node, it) -> bool:
	if s == null or it == null:
		return false

	# prefer station API if implemented (let station decide how to accept Node or string)
	if s.has_method("place_item"):
		var ok = s.place_item(it)
		# If station accepted a node and stored it internally, good. If not, fallthrough to reparent.
		if ok:
			return true

	# if `it` is Node -> reparent it under station and set current_ingredient
	if typeof(it) == TYPE_OBJECT and it is Node:
		if it.get_parent():
			it.get_parent().remove_child(it)
		s.add_child(it)
		it.position = Vector2.ZERO
		if it.has_method("drop_at"):
			it.drop_at(s)
		if "current_ingredient" in s:
			s.current_ingredient = it
		if "current_item" in s and it.has_method("get_type"):
			s.current_item = it.get("type")
		if s.has_method("update_appearance"):
			s.update_appearance()
		return true

	# fallback for legacy strings
	if typeof(it) == TYPE_STRING:
		if "current_item" in s and s.current_item == "":
			s.current_item = it
			if s.has_method("update_appearance"):
				s.update_appearance()
			return true

	return false

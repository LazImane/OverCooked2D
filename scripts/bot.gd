extends CharacterBody2D
# Agent loop: see -> next -> action -> act
enum Act {
	MOVE_TO_ING, TAKE_FROM_ING,
	MOVE_TO_CHOP, PLACE_ON_CHOP, CHOP,
	MOVE_TO_COOK, PLACE_ON_COOK, COOK,
	MOVE_TO_SERVE, PLACE_ON_SERVE, SERVE,
	NONE
}

@export var speed := 140.0
@export var accel := 800.0
@export var stop_distance := 20.0

@export var ingredients_path: NodePath
@export var chop_path: NodePath
@export var cook_path: NodePath
@export var serve_path: NodePath

var st_ing: Node
var st_chop: Node
var st_cook: Node
var st_serve: Node

# ---------- STATE ----------
var I := {
	"target": Vector2.ZERO,
	"carrying": "",   # e.g., "soup_ingredient", "chopped_soup_ingredient", "cooked_soup_ingredient"
	"phase": "to_ing" # to_ing -> to_chop -> to_cook -> to_serve -> done
}

func _ready() -> void:
	# Automatically find stations by type
	for s in get_tree().get_nodes_in_group("stations"):
		match s.station_type:
			"Ingredient":
				st_ing = s
			"Chopping":
				st_chop = s
			"Cooking":
				st_cook = s
			"Serving":
				st_serve = s
	print("Found stations:", st_ing, st_chop, st_cook, st_serve)

	if not st_ing or not st_chop or not st_cook or not st_serve:
		push_error("Bot: Could not find all 4 station types in scene tree.")
		set_physics_process(false)
		return

	# Set initial target and velocity
	I.target = st_ing.global_position + Vector2(55, 18)  
	print("I.target is now: ", I.target)
	#velocity = Vector2.ZERO
	#print("[BOT] ready. phase=", I.phase)

func _physics_process(delta: float) -> void:
	var per := see()
	next(I, per)
	var a: Act = action(I, per)
	act(a, delta)
	
	_move_toward_target(delta)
	move_and_slide()

# ---------- AGENT PARTS ----------
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
	match state.phase:
		"to_ing":
			if per.near_ing and state.carrying == "": return Act.TAKE_FROM_ING
			return Act.MOVE_TO_ING

		"to_chop":
			if per.near_chop and state.carrying != "" and not per.chop_has: return Act.PLACE_ON_CHOP
			if per.near_chop and per.chop_has: return Act.CHOP
			return Act.MOVE_TO_CHOP

		"to_cook":
			if per.near_cook and state.carrying != "" and not per.cook_has: return Act.PLACE_ON_COOK
			if per.near_cook and per.cook_has: return Act.COOK
			return Act.MOVE_TO_COOK

		"to_serve":
			if per.near_serve and state.carrying != "" and not per.serve_has: return Act.PLACE_ON_SERVE
			if per.near_serve and per.serve_has: return Act.SERVE
			return Act.MOVE_TO_SERVE

		_:
			return Act.NONE

func act(a: Act, delta: float) -> void:
	match a:
		# INGREDIENTS
		Act.MOVE_TO_ING:
			_seek(I.target, delta)
		Act.TAKE_FROM_ING:
			_call_interact(st_ing) # spawn item if empty
			var got := _take_item_from(st_ing)
			if got != "":
				I.carrying = got
				print("[BOT] took:", I.carrying)
				I.phase = "to_chop"

		# CHOP
		Act.MOVE_TO_CHOP:
			_seek(I.target, delta)
		Act.PLACE_ON_CHOP:
			if I.carrying != "":
				if _place_item_on(st_chop, I.carrying):
					print("[BOT] placed on chop:", I.carrying)
					I.carrying = ""
		Act.CHOP:
			_call_interact(st_chop)
			var chopped := _get_current_item(st_chop)
			if chopped != "":
				I.carrying = chopped
				I.phase = "to_cook"
				print("[BOT] chopped ->", I.carrying)

		# COOK
		Act.MOVE_TO_COOK:
			_seek(I.target, delta)
		Act.PLACE_ON_COOK:
			if I.carrying != "":
				if _place_item_on(st_cook, I.carrying):
					print("[BOT] placed on cook:", I.carrying)
					I.carrying = ""
		Act.COOK:
			_call_interact(st_cook)
			var cooked := _get_current_item(st_cook)
			if cooked != "":
				I.carrying = cooked
				I.phase = "to_serve"
				print("[BOT] cooked ->", I.carrying)

		# SERVE
		Act.MOVE_TO_SERVE:
			_seek(I.target, delta)
		Act.PLACE_ON_SERVE:
			if I.carrying != "":
				if _place_item_on(st_serve, I.carrying):
					print("[BOT] placed on serve:", I.carrying)
					I.carrying = ""
		Act.SERVE:
			_call_interact(st_serve)
			print("[BOT] served. done ✅")
			I.phase = "done"

		Act.NONE:
			velocity = velocity.move_toward(Vector2.ZERO, accel * delta)


func _move_toward_target(delta: float) -> void:
	var to_target = I.target  - global_position # I.target is your current goal (station)
	if to_target.length() <= stop_distance:
		# Close enough: slow down
		velocity = velocity.move_toward(Vector2.ZERO, accel * delta)
	else:
		# Move toward target
		var desired = to_target.normalized() * speed
		velocity = velocity.move_toward(desired, accel * delta)

	# DEBUG
	#print("[BOT] pos=", position, " vel=", velocity, " dist_to_target=", to_target.length(), "target is ",I.target)

# ---------- movement ----------
func _seek(target: Vector2, delta: float) -> void:
	var to_target = target - global_position
	if to_target.length() <= stop_distance:
		velocity = velocity.move_toward(Vector2.ZERO, accel * delta)
	else:
		var desired = to_target.normalized() * speed
		velocity = velocity.move_toward(desired, accel * delta)

	print("[BOT] pos=", position, " vel=", velocity, " dist_to_target=", to_target.length())

# ---------- station helpers ----------
func _call_interact(s: Node) -> void:
	if s and s.has_method("interact"): s.interact()

func _station_has_item(s: Node) -> bool:
	if "current_item" in s: return s.current_item != ""
	return false

func _get_current_item(s: Node) -> String:
	if "current_item" in s: return String(s.current_item)
	return ""

func _take_item_from(s: Node) -> String:
	if s and s.has_method("take_item"): return String(s.take_item())
	var cur := _get_current_item(s)
	if cur != "": _set_current_item(s, "")
	return cur

func _place_item_on(s: Node, it: String) -> bool:
	if s and s.has_method("place_item"): return bool(s.place_item(it))
	if _get_current_item(s) == "":
		_set_current_item(s, it)
		return true
	return false

func _set_current_item(s: Node, v: String) -> void:
	if "current_item" in s:
		s.current_item = v
		if s.has_method("update_appearance"): s.update_appearance()

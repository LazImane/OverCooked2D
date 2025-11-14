extends CharacterBody2D
# Agent loop: see -> next -> action -> act

enum Act {
	MOVE_TO_ING, TAKE_FROM_ING,
	MOVE_TO_CHOP, PLACE_ON_CHOP, CHOP,
	MOVE_TO_COOK, PLACE_ON_COOK, COOK,
	MOVE_TO_SERVE, PLACE_ON_SERVE, SERVE,
	NONE
}
@export var bot_id := 1
@export var speed := 70.0
@export var accel := 800.0
@export var stop_distance := 50.0
@export var recipe_name: String = "demo_salad"

var _need_chop := false
var _need_cook := false


# Remove the NodePath exports and replace with group-based station finding
var st_ing: Node
var st_chop: Node
var st_cook: Node
var st_serve: Node


var _gm: Node = null
  


var current_base: String = ""   # which ingredient this bot is currently working on


var I := {
	"target": Vector2.ZERO,
	"carrying": "",     # "", "soup_ingredient", "chopped_soup_ingredient", "cooked_soup_ingredient"
	"phase": "to_ing"   # to_ing -> to_chop -> to_cook -> to_serve -> done
}

@onready var sprite = $Sprite2D  # Add this for sprite flipping
@onready var navigation_agent = $NavigationAgent2D

func _ready() -> void:
	# Find stations by type instead of by path
	find_stations_by_type()
	
	if not st_ing or not st_chop or not st_cook or not st_serve:
		push_error("Bot: could not find all 4 station types (ingredients/chop/cook/serve).")
		set_physics_process(false)
		return
	_gm = get_tree().get_first_node_in_group("game_manager")
	print("[BOT", bot_id, "] ready. phase=", I.phase)

	
	

	I.target = st_ing.global_position
	velocity = Vector2.ZERO
	

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
	
	print("[BOT", bot_id, "] Found stations - Ing: ", st_ing != null, ", Chop: ", st_chop != null, ", Cook: ", st_cook != null, ", Serve: ", st_serve != null)

func _physics_process(delta: float) -> void:
	var per := see()
	#print("[QUICK DEBUG] Distance to ing: ", global_position.distance_to(st_ing.global_position), " | Stop dist: ", stop_distance)
	next(I, per)
	var a: Act = action(I, per)
	act(a, delta)
	
	# Add sprite flipping based on movement direction
	if sprite and velocity.x != 0:
		sprite.flip_h = velocity.x < 0
	
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
			if per.near_ing and state.carrying == "":
				return Act.TAKE_FROM_ING
			return Act.MOVE_TO_ING

		"to_chop":
			# Skip chopping entirely if not needed
			if not _need_chop:
				I.phase = "to_cook" if _need_cook else "to_serve"
				return Act.MOVE_TO_COOK if _need_cook else Act.MOVE_TO_SERVE
			# Chopping required → normal logic
			if per.near_chop and state.carrying != "" and not per.chop_has:
				return Act.PLACE_ON_CHOP
			if per.near_chop and per.chop_has:
				return Act.CHOP
			return Act.MOVE_TO_CHOP

		"to_cook":
			# Skip cooking entirely if not needed
			if not _need_cook:
				I.phase = "to_serve"
				return Act.MOVE_TO_SERVE
			# Cooking required → normal logic
			if per.near_cook and state.carrying != "" and not per.cook_has:
				return Act.PLACE_ON_COOK
			if per.near_cook and per.cook_has:
				return Act.COOK
			return Act.MOVE_TO_COOK

		"to_serve":
			if per.near_serve:
				return Act.SERVE   # robust SERVE will clear leftovers, then place+serve ours
			return Act.MOVE_TO_SERVE

		_:
			return Act.NONE


func act(a: Act, delta: float) -> void:
	match a:
		# INGREDIENTS
		Act.MOVE_TO_ING:
			_seek(I.target, delta)

		Act.TAKE_FROM_ING:
			# If we don't yet have an assigned ingredient, ask GameManager
			if current_base == "":
				if _gm == null:
					_gm = get_tree().get_first_node_in_group("game_manager")
				if _gm and _gm.has_method("request_next_ingredient"):
					current_base = String(_gm.request_next_ingredient(bot_id))

				# GM has no more ingredients → this bot is done
				if current_base == "":
					print("[BOT", bot_id, "] no more ingredients from GM; done.")
					I.phase = "done"
					return

			var want := current_base

			# Ensure Ingredient holds the wanted base (force if empty or wrong)
			var cur := _get_current_item(st_ing)
			if cur == "" or cur != want:
				_set_current_item(st_ing, want)
				print("[STATION] Ingredient spawned:", want, "on IngredientStation")

			# Take it
			_call_interact(st_ing)
			var got := _take_item_from(st_ing)
			if got != "":
				I.carrying = got
				print("[BOT", bot_id, "] took:", I.carrying)

				# --- read flow for THIS ingredient and set flags
				var steps: Array = []
				if _gm and _gm.has_method("get_flow_for_item"):
					steps = _gm.get_flow_for_item(recipe_name, current_base)
				elif _gm and _gm.has_method("get_recipe_flow"):
					steps = _gm.get_recipe_flow(recipe_name)  # fallback to recipe-level flow
				else:
					steps = ["Chopping","Serving"]  # safe default

				_need_chop = "Chopping" in steps
				_need_cook = "Cooking" in steps

				# Jump to the *first* required step
				if _need_chop:
					I.phase = "to_chop"
				elif _need_cook:
					I.phase = "to_cook"
				else:
					I.phase = "to_serve"
			else:
				print("[BOT ERROR] Failed to take item from ingredient station!")

		# CHOP
		Act.MOVE_TO_CHOP:
			_seek(I.target, delta)

		Act.PLACE_ON_CHOP:
			if I.carrying != "":
				if _place_item_on(st_chop, I.carrying):
					print("[BOT", bot_id, "] placed on chop:", I.carrying)
					I.carrying = ""

		Act.CHOP:
			_call_interact(st_chop)
			print("[BOT", bot_id, "] chopped ->", _get_current_item(st_chop))
			var taken := _take_item_from(st_chop)
			if taken != "":
				I.carrying = taken
				I.phase = "to_cook" if _need_cook else "to_serve"

		# COOK
		Act.MOVE_TO_COOK:
			_seek(I.target, delta)

		Act.PLACE_ON_COOK:
			if I.carrying != "":
				if _place_item_on(st_cook, I.carrying):
					print("[BOT", bot_id, "] placed on cook:", I.carrying)
					I.carrying = ""

		Act.COOK:
			_call_interact(st_cook)
			print("[BOT", bot_id, "] cooked ->", _get_current_item(st_cook))
			var taken2 := _take_item_from(st_cook)
			if taken2 != "":
				I.carrying = taken2
				I.phase = "to_serve"

		# SERVE
		Act.MOVE_TO_SERVE:
			_seek(I.target, delta)

		Act.PLACE_ON_SERVE:
			# (you can leave this unused or remove it; SERVE below already does place+serve)
			if I.carrying != "":
				if _place_item_on(st_serve, I.carrying):
					print("[BOT", bot_id, "] placed on serve:", I.carrying)
					I.carrying = ""

		Act.SERVE:
			# If we are carrying something, drop it on Serving and let the station serve it.
			if I.carrying != "":
				if _place_item_on(st_serve, I.carrying):
					print("[BOT", bot_id, "] placed on serve:", I.carrying)
					I.carrying = ""
					_call_interact(st_serve)  # ServingStation will serve from its queue

			# This ingredient is finished
			current_base = ""
			_need_chop = false
			_need_cook = false

			# Ask GM for next ingredient
			if _gm == null:
				_gm = get_tree().get_first_node_in_group("game_manager")
			if _gm and _gm.has_method("request_next_ingredient"):
				current_base = String(_gm.request_next_ingredient(bot_id))

			if current_base == "":
				print("[BOT", bot_id, "] no more tasks from GM; idling.")

				I.phase = "done"
			else:
				print("[BOT", bot_id, "] new ingredient from GM:", current_base)
				I.phase = "to_ing"

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
	if s and s.has_method("interact"): s.interact()

func _station_has_item(s: Node) -> bool:
	if "current_item" in s: return s.current_item != ""
	return false

func _get_current_item(s: Node) -> String:
	if "current_item" in s: return String(s.current_item)
	return ""

func _set_current_item(s: Node, v: String) -> void:
	if "current_item" in s:
		s.current_item = v
		if s.has_method("update_appearance"): s.update_appearance()

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

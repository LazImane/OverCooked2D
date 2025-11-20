extends CharacterBody2D
# Agent loop: see -> next -> action -> act
# Clean version ready for multi-agent coordination

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
@export var recipe_name: String = "demo_salad"

# Multi-agent coordination will use these
var bot_id: String = ""  # Set by GameManager when spawned
var assigned_ingredient: String = ""  # For task allocation

# Station references
var st_ing: Node
var st_chop: Node
var st_cook: Node
var st_serve: Node

# Recipe tracking
var _gm: Node = null
var _pending: Array = []          # Queue of ingredients to process
var _plan_i: int = 0              # Current ingredient index
var recipe_flow: Array = []       # Current flow steps for active ingredient
var current_flow_step: int = 0    # Position in recipe_flow

# Visual tracking
var carried_node: Node = null

# Internal state
var I := {
	"target": Vector2.ZERO,
	"phase": "to_ing"
}

@onready var sprite = $Sprite2D
@onready var navigation_agent = $NavigationAgent2D

func _ready() -> void:
	bot_id = name  # Use node name as ID
	
	find_stations_by_type()
	if not st_ing or not st_chop or not st_cook or not st_serve:
		push_error("[BOT %s] Could not find all 4 station types" % bot_id)
		set_physics_process(false)
		return
	
	_gm = get_tree().get_first_node_in_group("game_manager")
	if not _gm:
		push_error("[BOT %s] GameManager not found!" % bot_id)
		set_physics_process(false)
		return
	
	# Load recipe ingredients
	if _gm.has_method("get_recipe_ingredients"):
		_pending = _gm.get_recipe_ingredients(recipe_name).duplicate()
	
	if _pending.is_empty():
		push_warning("[BOT %s] Recipe '%s' has no ingredients, using fallback" % [bot_id, recipe_name])
		_pending = ["lettuce", "tomato", "cucumber"]
	
	# Load initial flow (will be updated per-ingredient)
	if _gm.has_method("get_recipe_flow"):
		recipe_flow = _gm.get_recipe_flow(recipe_name)
	
	if recipe_flow.is_empty():
		push_error("[BOT %s] Recipe flow empty!" % bot_id)
		set_physics_process(false)
		return
	
	print("[BOT %s] Ready | Recipe: %s | Flow: %s | Ingredients: %s" % [bot_id, recipe_name, recipe_flow, _pending])
	
	I.target = st_ing.global_position
	velocity = Vector2.ZERO
	navigation_agent.target_desired_distance = stop_distance
	navigation_agent.path_desired_distance = stop_distance

func find_stations_by_type() -> void:
	var stations = get_tree().get_nodes_in_group("stations")
	for station in stations:
		match station.station_type:
			"Ingredient": st_ing = station
			"Chopping": st_chop = station
			"Cooking": st_cook = station
			"Serving": st_serve = station

func _physics_process(delta: float) -> void:
	var per := see()
	next(I, per)
	var a: Act = action(I, per)
	act(a, delta)
	if sprite and velocity.x != 0:
		sprite.flip_h = velocity.x < 0
	move_and_slide()

# ---------- PERCEPTION ----------
func see() -> Dictionary:
	return {
		"bot_pos": global_position,
		"bot_id": bot_id,
		"carrying": carried_node != null,
		"carrying_type": carried_node.type if carried_node else "",
		
		"ing_pos": st_ing.global_position,
		"chop_pos": st_chop.global_position,
		"cook_pos": st_cook.global_position,
		"serve_pos": st_serve.global_position,
		
		"near_ing": global_position.distance_to(st_ing.global_position) <= stop_distance,
		"near_chop": global_position.distance_to(st_chop.global_position) <= stop_distance,
		"near_cook": global_position.distance_to(st_cook.global_position) <= stop_distance,
		"near_serve": global_position.distance_to(st_serve.global_position) <= stop_distance,
		
		"ing_has": _station_has_item(st_ing),
		"chop_has": _station_has_item(st_chop),
		"cook_has": _station_has_item(st_cook),
		"serve_has": _station_has_item(st_serve),
	}

# ---------- PLANNING ----------
func next(state: Dictionary, per: Dictionary) -> void:
	if current_flow_step >= recipe_flow.size():
		return
	
	var step_type: String = recipe_flow[current_flow_step]
	match step_type:
		"Ingredient": state.target = per.ing_pos
		"Chopping": state.target = per.chop_pos
		"Cooking": state.target = per.cook_pos
		"Serving": state.target = per.serve_pos

# ---------- DECISION ----------
func action(state: Dictionary, per: Dictionary) -> Act:
	# Check if current ingredient flow is complete
	if current_flow_step >= recipe_flow.size():
		_plan_i += 1
		
		if _plan_i < _pending.size():
			print("[BOT %s] Next ingredient: %s" % [bot_id, _pending[_plan_i]])
			current_flow_step = 0
			I.phase = "to_ing"
			return Act.MOVE_TO_ING
		else:
			print("[BOT %s] All ingredients complete! ✅" % bot_id)
			I.phase = "done"
			return Act.NONE
	
	var step_type: String = recipe_flow[current_flow_step]
	
	match step_type:
		"Ingredient":
			if per.near_ing and carried_node == null:
				return Act.TAKE_FROM_ING
			return Act.MOVE_TO_ING
		
		"Chopping":
			if per.near_chop:
				if carried_node != null and not per.chop_has:
					return Act.PLACE_ON_CHOP
				if per.chop_has:
					return Act.CHOP
			return Act.MOVE_TO_CHOP
		
		"Cooking":
			if per.near_cook:
				if carried_node != null and not per.cook_has:
					return Act.PLACE_ON_COOK
				if per.cook_has:
					return Act.COOK
			return Act.MOVE_TO_COOK
		
		"Serving":
			if per.near_serve:
				if carried_node != null and not per.serve_has:
					return Act.PLACE_ON_SERVE
				if per.serve_has:
					return Act.SERVE
			return Act.MOVE_TO_SERVE
	
	return Act.NONE

# ---------- ACTIONS ----------
func act(a: Act, delta: float) -> void:
	match a:
		Act.MOVE_TO_ING:
			_seek(I.target, delta)

		Act.TAKE_FROM_ING:
			if _plan_i >= _pending.size():
				print("[BOT %s] No more ingredients" % bot_id)
				I.phase = "done"
				return
			
			var want_type := String(_pending[_plan_i])
			
			# Load per-ingredient flow (handles per_item_flow overrides)
			if _gm.has_method("get_flow_for_item"):
				recipe_flow = _gm.get_flow_for_item(recipe_name, want_type)
				current_flow_step = 0
				print("[BOT %s] Flow for %s: %s" % [bot_id, want_type, recipe_flow])
			
			# Spawn ingredient at station
			_call_interact(st_ing)
			var got := _take_item_from(st_ing)
			
			if got != null and typeof(got) == TYPE_OBJECT and got is Node:
				carried_node = got
				
				if carried_node.has_method("set_type"):
					carried_node.set_type(want_type)
				
				if carried_node.has_method("pick_up"):
					carried_node.pick_up(self, Vector2(0, -16))
				
				print("[BOT %s] Took: %s" % [bot_id, want_type])
				current_flow_step += 1
			else:
				push_error("[BOT %s] Failed to take ingredient!" % bot_id)

		Act.MOVE_TO_CHOP:
			_seek(I.target, delta)

		Act.PLACE_ON_CHOP:
			if carried_node != null:
				var item = carried_node
				carried_node = null
				if _place_item_on(st_chop, item):
					print("[BOT %s] Placed on chop" % bot_id)
				else:
					carried_node = item

		Act.CHOP:
			_call_interact(st_chop)
			var taken := _take_item_from(st_chop)
			if taken != null and typeof(taken) == TYPE_OBJECT and taken is Node:
				carried_node = taken
				if carried_node.has_method("pick_up"):
					carried_node.pick_up(self, Vector2(0, -16))
				print("[BOT %s] Chopped" % bot_id)
				current_flow_step += 1

		Act.MOVE_TO_COOK:
			_seek(I.target, delta)

		Act.PLACE_ON_COOK:
			if carried_node != null:
				var item = carried_node
				carried_node = null
				if _place_item_on(st_cook, item):
					print("[BOT %s] Placed on cook" % bot_id)
				else:
					carried_node = item

		Act.COOK:
			_call_interact(st_cook)
			var cooked := _take_item_from(st_cook)
			if cooked != null and typeof(cooked) == TYPE_OBJECT and cooked is Node:
				carried_node = cooked
				if carried_node.has_method("pick_up"):
					carried_node.pick_up(self, Vector2(0, -16))
				print("[BOT %s] Cooked" % bot_id)
				current_flow_step += 1

		Act.MOVE_TO_SERVE:
			_seek(I.target, delta)

		Act.PLACE_ON_SERVE:
			if carried_node != null:
				var item = carried_node
				carried_node = null
				if _place_item_on(st_serve, item):
					print("[BOT %s] Placed on serve" % bot_id)
				else:
					carried_node = item

		Act.SERVE:
			_call_interact(st_serve)
			if carried_node != null and is_instance_valid(carried_node):
				carried_node.queue_free()
			carried_node = null
			print("[BOT %s] Served! ✅" % bot_id)
			current_flow_step += 1

		Act.NONE:
			velocity = velocity.move_toward(Vector2.ZERO, accel * delta)

# ---------- MOVEMENT ----------
func _seek(target: Vector2, delta: float) -> void:
	var to_target := target - global_position
	var desired := to_target.normalized() * speed if to_target.length() > 0.001 else Vector2.ZERO
	if to_target.length() <= stop_distance:
		velocity = velocity.move_toward(Vector2.ZERO, accel * delta)
	else:
		velocity = velocity.move_toward(desired, accel * delta)

# ---------- HELPERS ----------
func _call_interact(s: Node) -> void:
	if s and s.has_method("interact"):
		s.interact()

func _station_has_item(s: Node) -> bool:
	if s == null: return false
	if "current_ingredient" in s:
		return s.current_ingredient != null
	if "current_item" in s:
		return s.current_item != ""
	return false

func _take_item_from(s: Node) -> Node:
	if s == null: return null
	if s.has_method("take_item"):
		var ret = s.take_item()
		if typeof(ret) == TYPE_OBJECT and ret is Node:
			return ret
		if typeof(ret) == TYPE_STRING:
			if _gm and _gm.has_method("spawn_ingredient"):
				return _gm.spawn_ingredient(String(ret), null)
	
	if "current_ingredient" in s and s.current_ingredient != null:
		var n = s.current_ingredient
		s.current_ingredient = null
		if s.has_method("update_appearance"):
			s.update_appearance()
		return n
	
	return null

func _place_item_on(s: Node, it) -> bool:
	if s == null or it == null: return false
	
	if s.has_method("place_item"):
		if s.place_item(it):
			return true
	
	if typeof(it) == TYPE_OBJECT and it is Node:
		if it.get_parent():
			it.get_parent().remove_child(it)
		s.add_child(it)
		it.position = Vector2.ZERO
		if it.has_method("drop_at"):
			it.drop_at(s)
		if "current_ingredient" in s:
			s.current_ingredient = it
		if s.has_method("update_appearance"):
			s.update_appearance()
		return true
	
	return false

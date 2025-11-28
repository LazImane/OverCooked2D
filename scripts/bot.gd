extends CharacterBody2D
# Multi-Agent Bot: Requests tasks from GameManager and processes ingredients

enum Action {
	IDLE,
	MOVE,
	TAKE_INGREDIENT,
	PLACE_ITEM,
	PROCESS_ITEM
}

@export var bot_id: int = 1
@export var speed := 70.0
@export var accel := 800.0
@export var stop_distance := 50.0
@export var recipe_name: String = "demo_salad"
@export var animPlayer:AnimationPlayer 

# References
var _gm: Node = null
var stations: Dictionary = {}

# Current task
var current_ingredient: String = ""
var current_recipe_id: String = ""   # recipe for THIS task
var flow_steps: Array = []
var current_step: int = 0
var carried_item: Node = null
var carried_item_type: String = ""

# Action state
var current_action: Action = Action.IDLE
var target_position: Vector2 = Vector2.ZERO
var target_station: Node = null

@onready var sprite = $Sprite2D

func _ready() -> void:
	playAnim(true)
	_gm = get_tree().get_first_node_in_group("game_manager")
	if not _gm:
		push_error("[BOT %d] GameManager not found!" % bot_id)
		set_physics_process(false)
		return
	
	_find_stations()
	_request_next_task()
	
	print("[BOT %d] Ready | Default recipe: %s" % [bot_id, recipe_name])

func _physics_process(delta: float) -> void:
	match current_action:
		Action.IDLE:
			_stop(delta)
		
		Action.MOVE:
			_move_toward_target(delta)
			if _at_target():
				_on_arrived_at_station()
		
		Action.TAKE_INGREDIENT:
			_take_from_station()
		
		Action.PLACE_ITEM:
			_place_on_station()
		
		Action.PROCESS_ITEM:
			_process_at_station()
	
	if sprite and velocity.x != 0:
		sprite.flip_h = velocity.x < 0
	
	move_and_slide()

# ==================== TASK MANAGEMENT ====================
func _request_next_task() -> void:
	if not _gm or not _gm.has_method("request_next_ingredient"):
		print("[BOT %d] Cannot request task - GameManager missing method" % bot_id)
		current_action = Action.IDLE
		return
	
	var result = _gm.request_next_ingredient(bot_id)
	current_recipe_id = ""
	current_ingredient = ""
	
	# New protocol: GameManager returns a Dictionary { recipe_id, ingredient_id }
	if typeof(result) == TYPE_DICTIONARY:
		current_recipe_id = str(result.get("recipe_id", ""))
		current_ingredient = str(result.get("ingredient_id", ""))
	else:
		# Fallback: treat result as the ingredient id, use exported recipe_name
		current_recipe_id = recipe_name
		current_ingredient = str(result) if result != null else ""
	
	if current_ingredient == "":
		print("[BOT %d] ✅ No more tasks - all done!" % bot_id)
		current_action = Action.IDLE
		return
	
	current_step = 0
	
	# Use per-task recipe if available, else fallback to exported recipe_name
	var flow_recipe_id := current_recipe_id if current_recipe_id != "" else recipe_name
	
	if _gm.has_method("get_flow_for_item"):
		flow_steps = _gm.get_flow_for_item(flow_recipe_id, current_ingredient)
	else:
		flow_steps = ["Ingredient", "Chopping", "Serving"]
	
	print("[BOT %d] 📋 Task: %s | Recipe: %s | Flow: %s" %
		[bot_id, current_ingredient, flow_recipe_id, flow_steps])
	
	_go_to_next_step()


func _go_to_next_step() -> void:
	if current_step >= flow_steps.size():
		# Task finished for this ingredient
		if _gm and _gm.has_method("notify_served"):
			_gm.notify_served(current_ingredient)
		_request_next_task()
		return
	
	var station_type: String = flow_steps[current_step]
	target_station = stations.get(station_type)
	
	if not target_station:
		push_error("[BOT %d] Station not found: %s" % [bot_id, station_type])
		current_action = Action.IDLE
		return
	
	target_position = target_station.global_position
	current_action = Action.MOVE
	
	print("[BOT %d] → Moving to %s" % [bot_id, station_type])

# ==================== STATION INTERACTIONS ====================
func _on_arrived_at_station() -> void:
	var station_type: String = flow_steps[current_step]
	
	match station_type:
		"Ingredient":
			current_action = Action.TAKE_INGREDIENT
		
		"Chopping", "Cooking":
			if carried_item != null:
				current_action = Action.PLACE_ITEM
			else:
				current_action = Action.TAKE_INGREDIENT
		
		"Serving":
			# If we have something, we place it; Serving station visuals handle the rest
			if carried_item != null:
				current_action = Action.PLACE_ITEM
			else:
				current_action = Action.PROCESS_ITEM

func _take_from_station() -> void:
	if not target_station:
		_go_to_next_step()
		return
	
	var station_type: String = flow_steps[current_step]
	
	# Ingredient station: spawn from GameManager and immediately take it
	if station_type == "Ingredient":
		print("[BOT %d] 🏭 Spawning %s at Ingredient station" % [bot_id, current_ingredient])
		
		if _gm and _gm.has_method("spawn_ingredient"):
			var item_node = _gm.spawn_ingredient(current_ingredient, target_station.get_parent())
			
			if item_node:
				if target_station.has_method("place_item"):
					if target_station.place_item(item_node):
						print("[BOT %d] 📦 Ingredient spawned and placed on station" % bot_id)
						
						# Now take it immediately (small delay for visuals)
						await get_tree().create_timer(0.1).timeout
						var taken_item = _take_item_node_from(target_station)
						if taken_item:
							carried_item = taken_item
							carried_item_type = current_ingredient
							_pickup_item_visual(taken_item)
							print("[BOT %d] 📦 Took: %s" % [bot_id, current_ingredient])
							current_step += 1
							_go_to_next_step()
						else:
							push_error("[BOT %d] Failed to take spawned ingredient" % bot_id)
							current_action = Action.IDLE
					else:
						push_error("[BOT %d] Failed to place spawned ingredient" % bot_id)
						item_node.queue_free()
						current_action = Action.IDLE
				else:
					push_error("[BOT %d] Station missing place_item method" % bot_id)
					item_node.queue_free()
					current_action = Action.IDLE
			else:
				push_error("[BOT %d] Failed to spawn ingredient" % bot_id)
				current_action = Action.IDLE
		else:
			push_error("[BOT %d] GameManager missing spawn_ingredient method" % bot_id)
			current_action = Action.IDLE
		return
	
	# Chopping / Cooking: take processed item
	var item_node = _take_item_node_from(target_station)
	if item_node:
		carried_item = item_node
		_pickup_item_visual(item_node)
		print("[BOT %d] 📦 Took processed item" % bot_id)
		current_step += 1
		_go_to_next_step()
	else:
		push_error("[BOT %d] Failed to take from %s" % [bot_id, station_type])
		current_action = Action.IDLE


func _place_on_station() -> void:
	if not carried_item or not target_station:
		_go_to_next_step()
		return
	
	# Pass recipe_id to serving station
	var station_type: String = flow_steps[current_step]
	var success := false
	
	if station_type == "Serving" and target_station.has_method("place_item"):
		# Call place_item with recipe_id parameter for serving stations
		success = target_station.place_item(carried_item, current_recipe_id)
	else:
		# Other stations use the normal helper function
		success = _place_item_node_on(target_station, carried_item)
	
	if success:
		print("[BOT %d] 📥 Placed on %s (recipe: %s)" % [bot_id, station_type, current_recipe_id])
		carried_item = null
		carried_item_type = ""
		
		current_action = Action.PROCESS_ITEM
	else:
		push_error("[BOT %d] Failed to place item" % bot_id)
		current_action = Action.IDLE

func _process_at_station() -> void:
	if not target_station:
		_go_to_next_step()
		return
	
	var station_type: String = flow_steps[current_step]
	
	# Serving station: item already placed in _place_on_station()
	# Station visuals (Station.gd) handle accumulating ingredients and final dish.
	if station_type == "Serving":
		if _gm and _gm.has_method("notify_served"):
			_gm.notify_served(current_ingredient)
		
		print("[BOT %d] ✅ Placed on serving station: %s" % [bot_id, current_ingredient])
		carried_item = null
		carried_item_type = ""
		current_step += 1
		_go_to_next_step()
		return
	
	# Other stations (Chopping, Cooking): process then take
	_call_interact(target_station)
	
	var item_node = _take_item_node_from(target_station)
	if item_node:
		carried_item = item_node
		_pickup_item_visual(item_node)
		print("[BOT %d] ⚙️ Processed at %s" % [bot_id, station_type])
		current_step += 1
		_go_to_next_step()
	else:
		push_error("[BOT %d] Failed to take processed item" % bot_id)
		current_action = Action.IDLE

# ==================== MOVEMENT ====================
func _move_toward_target(delta: float) -> void:
	var direction = (target_position - global_position).normalized()
	var distance = global_position.distance_to(target_position)
	
	if distance > stop_distance:
		velocity = velocity.move_toward(direction * speed, accel * delta)
	else:
		velocity = velocity.move_toward(Vector2.ZERO, accel * delta)

func _stop(delta: float) -> void:
	velocity = velocity.move_toward(Vector2.ZERO, accel * delta)

func _at_target() -> bool:
	return global_position.distance_to(target_position) <= stop_distance

# ==================== STATION HELPERS ====================
func _find_stations() -> void:
	stations.clear()
	for station in get_tree().get_nodes_in_group("stations"):
		if "station_type" in station:
			stations[station.station_type] = station
	print("[BOT %d] Found stations: %s" % [bot_id, stations.keys()])

func playAnim(b:bool):
	if b:
		animPlayer.play("hop")
	else:
		animPlayer.stop()

func _call_interact(station: Node) -> void:
	if station and station.has_method("interact"):
		station.interact()

func _take_item_node_from(station: Node) -> Node:
	if station and station.has_method("take_item"):
		var result = station.take_item()
		return result if result is Node else null
	return null

func _place_item_node_on(station: Node, item: Node) -> bool:
	if station and station.has_method("place_item"):
		return bool(station.place_item(item))
	return false

func _pickup_item_visual(item: Node) -> void:
	if item and item.has_method("pick_up"):
		item.pick_up(self, Vector2(0, -16))
	elif item:
		if item.get_parent():
			item.get_parent().remove_child(item)
		add_child(item)
		item.position = Vector2(0, -16)

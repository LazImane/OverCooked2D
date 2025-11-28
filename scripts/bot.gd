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

# References
var _gm: Node = null
var stations: Dictionary = {}

# Current task
var current_ingredient: String = ""
var flow_steps: Array = []
var current_step: int = 0
var carried_item: Node = null  # Visual ingredient node we're carrying
var carried_item_type: String = ""  # Type tracking for logic

# Action state
var current_action: Action = Action.IDLE
var target_position: Vector2 = Vector2.ZERO
var target_station: Node = null

# Flags for skipping steps
var _need_chop: bool = true
var _need_cook: bool = true

@onready var sprite = $Sprite2D

func _ready() -> void:
	# Find GameManager
	_gm = get_tree().get_first_node_in_group("game_manager")
	if not _gm:
		push_error("[BOT %d] GameManager not found!" % bot_id)
		set_physics_process(false)
		return
	
	# Find all stations
	_find_stations()
	
	# Request first ingredient from GameManager
	_request_next_task()
	
	print("[BOT %d] Ready | Recipe: %s" % [bot_id, recipe_name])

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
	
	# Sprite flipping
	if sprite and velocity.x != 0:
		sprite.flip_h = velocity.x < 0
	
	move_and_slide()

# ==================== TASK MANAGEMENT ====================
func _request_next_task() -> void:
	"""Ask GameManager for next ingredient to process"""
	if not _gm or not _gm.has_method("request_next_ingredient"):
		print("[BOT %d] Cannot request task - GameManager missing method" % bot_id)
		current_action = Action.IDLE
		return
	
	var result = _gm.request_next_ingredient(bot_id)
	current_ingredient = str(result) if result != null else ""
	
	if current_ingredient == "":
		print("[BOT %d] ✅ No more tasks - all done!" % bot_id)
		current_action = Action.IDLE
		return
	
	# Get processing flow for this specific ingredient
	current_step = 0
	if _gm.has_method("get_flow_for_item"):
		flow_steps = _gm.get_flow_for_item(recipe_name, current_ingredient)
	else:
		flow_steps = ["Ingredient", "Chopping", "Serving"]
	
	# Set flags based on flow
	_need_chop = "Chopping" in flow_steps
	_need_cook = "Cooking" in flow_steps
	
	print("[BOT %d] 📋 Task: %s | Flow: %s" % [bot_id, current_ingredient, flow_steps])
	
	_go_to_next_step()

func _go_to_next_step() -> void:
	"""Move to the next station in the flow"""
	if current_step >= flow_steps.size():
		# Ingredient complete - request next task
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
	"""Decide what to do when we reach a station"""
	var station_type: String = flow_steps[current_step]
	
	match station_type:
		"Ingredient":
			current_action = Action.TAKE_INGREDIENT
		
		"Chopping", "Cooking":
			if carried_item != null:
				current_action = Action.PLACE_ITEM
			else:
				# Already processed, just take it
				current_action = Action.TAKE_INGREDIENT
		
		"Serving":
			if carried_item != null:
				current_action = Action.PLACE_ITEM
			else:
				current_action = Action.PROCESS_ITEM

func _take_from_station() -> void:
	"""Take an item from the current station"""
	if not target_station:
		_go_to_next_step()
		return
	
	var station_type: String = flow_steps[current_step]
	
	# Special handling for Ingredient station
	if station_type == "Ingredient":
		# Ensure station knows what to spawn
		if "current_item" in target_station:
			target_station.current_item = current_ingredient
		
		# Spawn the ingredient node
		_call_interact(target_station)
		
		# Take the spawned node
		var item_node = _take_item_node_from(target_station)
		if item_node:
			carried_item = item_node
			carried_item_type = current_ingredient
			_pickup_item_visual(item_node)
			print("[BOT %d] 📦 Took: %s" % [bot_id, current_ingredient])
			current_step += 1
			_go_to_next_step()
		else:
			push_error("[BOT %d] Failed to take from Ingredient station" % bot_id)
			current_action = Action.IDLE
		return
	
	# Take from processing stations
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
	"""Place our carried item on the current station"""
	if not carried_item or not target_station:
		_go_to_next_step()
		return
	
	if _place_item_node_on(target_station, carried_item):
		print("[BOT %d] 📥 Placed on %s" % [bot_id, flow_steps[current_step]])
		carried_item = null
		carried_item_type = ""
		
		# Now process it
		current_action = Action.PROCESS_ITEM
	else:
		push_error("[BOT %d] Failed to place item" % bot_id)
		current_action = Action.IDLE

func _process_at_station() -> void:
	"""Process/interact with the current station"""
	if not target_station:
		_go_to_next_step()
		return
	
	var station_type: String = flow_steps[current_step]
	
	# Trigger processing
	_call_interact(target_station)
	
	# Serving station finishes the ingredient
	if station_type == "Serving":
		if carried_item:
			carried_item.queue_free()
			carried_item = null
			carried_item_type = ""
		print("[BOT %d] ✅ Served: %s" % [bot_id, current_ingredient])
		current_step += 1
		_go_to_next_step()
		return
	
	# Other stations: take the processed result
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
	"""Find all stations in the scene by their group"""
	stations.clear()
	for station in get_tree().get_nodes_in_group("stations"):
		if "station_type" in station:
			stations[station.station_type] = station
	print("[BOT %d] Found stations: %s" % [bot_id, stations.keys()])

func _call_interact(station: Node) -> void:
	if station and station.has_method("interact"):
		station.interact()

func _take_item_node_from(station: Node) -> Node:
	"""Take an ingredient Node from a station"""
	if station and station.has_method("take_item"):
		var result = station.take_item()
		return result if result is Node else null
	return null

func _place_item_node_on(station: Node, item: Node) -> bool:
	"""Place an ingredient Node on a station"""
	if station and station.has_method("place_item"):
		return bool(station.place_item(item))
	return false

func _pickup_item_visual(item: Node) -> void:
	"""Attach item visually to bot"""
	if item and item.has_method("pick_up"):
		item.pick_up(self, Vector2(0, -16))
	elif item:
		# Fallback: manual parent change
		if item.get_parent():
			item.get_parent().remove_child(item)
		add_child(item)
		item.position = Vector2(0, -16)

func _take_item_from(station: Node) -> String:
	# Legacy method - kept for compatibility
	if station and station.has_method("take_item"):
		var result = station.take_item()
		return str(result) if result != null else ""
	if "current_item" in station:
		var item = str(station.current_item)
		if item != "":
			station.current_item = ""
			if station.has_method("update_appearance"):
				station.update_appearance()
		return item
	return ""

func _place_item_on(station: Node, item: String) -> bool:
	# Legacy method - kept for compatibility
	if station and station.has_method("place_item"):
		return bool(station.place_item(item))
	if "current_item" in station:
		if station.current_item == "":
			station.current_item = item
			if station.has_method("update_appearance"):
				station.update_appearance()
			return true
	return false

func _set_current_item(station: Node, item: String) -> void:
	if "current_item" in station:
		station.current_item = item
		if station.has_method("update_appearance"):
			station.update_appearance()

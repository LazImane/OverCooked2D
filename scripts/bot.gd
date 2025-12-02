extends CharacterBody2D
# Multi-Agent Bot: Requests tasks from GameManager and processes ingredients
enum Action {
	IDLE,
	MOVE,
	TAKE_INGREDIENT,
	PLACE_ITEM,
	PROCESS_ITEM,
	WAIT_FOR_STATION
}

@export var bot_id: int = 1
@export var speed := 70.0
@export var accel := 800.0
@export var stop_distance := 50.0
@export var recipe_name: String = "demo_salad"
@export var animPlayer: AnimationPlayer

# References
var _gm: Node = null

# Current task
var current_ingredient: String = ""
var current_recipe_id: String = ""
var flow_steps: Array = []
var current_step: int = 0
var carried_item: Node = null
var carried_item_type: String = ""

# Action state
var current_action: Action = Action.IDLE
var target_position: Vector2 = Vector2.ZERO
var target_station: Node = null
var wait_timer: float = 0.0
var max_wait_time: float = 2.0
var retry_count: int = 0
var max_retries: int = 3

@onready var sprite = $Sprite2D


# ==================== INITIALIZATION ====================
func _ready() -> void:
	playAnim(true)
	_gm = get_tree().get_first_node_in_group("game_manager")
	if not _gm:
		push_error("[BOT %d] GameManager not found!" % bot_id)
		set_physics_process(false)
		return
	
	# Connect to new orders signal
	if _gm.has_signal("new_orders_available"):
		_gm.connect("new_orders_available", _on_new_orders_available)
	
	_request_next_task()
	print("[BOT %d] Ready | Default recipe: %s" % [bot_id, recipe_name])


func _on_new_orders_available() -> void:
	"""Callback when new orders are available"""
	if current_action == Action.IDLE:
		print("[BOT %d] New orders available! Requesting task..." % bot_id)
		_request_next_task()


# ==================== PHYSICS LOOP ====================
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
		
		Action.WAIT_FOR_STATION:
			_wait_for_station(delta)
	
	if sprite and velocity.x != 0:
		sprite.flip_h = velocity.x < 0
	
	move_and_slide()


# ==================== TASK MANAGEMENT ====================
func _request_next_task() -> void:
	"""Request a new ingredient task from GameManager"""
	if not _gm or not _gm.has_method("request_next_ingredient"):
		print("[BOT %d] Cannot request task - GameManager missing method" % bot_id)
		current_action = Action.IDLE
		return
	
	var result = _gm.request_next_ingredient(bot_id)
	current_recipe_id = ""
	current_ingredient = ""
	retry_count = 0
	
	# Parse result dictionary
	if typeof(result) == TYPE_DICTIONARY:
		current_recipe_id = str(result.get("recipe_id", ""))
		current_ingredient = str(result.get("ingredient_id", ""))
	else:
		# Fallback: treat result as ingredient id
		current_recipe_id = recipe_name
		current_ingredient = str(result) if result != null else ""
	
	if current_ingredient == "":
		print("[BOT %d] No more tasks - all done!" % bot_id)
		current_action = Action.IDLE
		return
	
	current_step = 0
	
	# Get flow for this task
	var flow_recipe_id := current_recipe_id if current_recipe_id != "" else recipe_name
	
	if _gm.has_method("get_flow_for_item"):
		flow_steps = _gm.get_flow_for_item(flow_recipe_id, current_ingredient)
	else:
		flow_steps = ["Ingredient", "Chopping", "Serving"]
	
	print("[BOT %d] Task: %s | Recipe: %s | Flow: %s" %
		[bot_id, current_ingredient, flow_recipe_id, flow_steps])
	
	_go_to_next_step()


func _go_to_next_step() -> void:
	"""Advance to the next workflow step"""
	if current_step >= flow_steps.size():
		# Task finished
		if _gm and _gm.has_method("notify_served"):
			_gm.notify_served(current_ingredient)
		_request_next_task()
		return
	
	var station_type: String = flow_steps[current_step]
	
	# NEW: Find best available station dynamically
	target_station = _find_best_station(station_type)
	if not target_station:
		push_error("[BOT %d] No station found: %s" % [bot_id, station_type])
		current_action = Action.IDLE
		return
	
	target_position = target_station.global_position
	current_action = Action.MOVE
	
	print("[BOT %d] → Moving to %s (station: %s)" % [bot_id, station_type, target_station.name])


# ==================== SMART STATION SELECTION ====================
func _find_best_station(station_type: String) -> Node:
	"""Find the least busy station of the given type"""
	if not _gm or not _gm.stations_by_type.has(station_type):
		push_error("[BOT %d] Cannot find stations of type: %s" % [bot_id, station_type])
		return null
	
	var available_stations: Array = _gm.stations_by_type[station_type]
	
	if available_stations.is_empty():
		return null
	
	if available_stations.size() == 1:
		return available_stations[0]
	
	# Strategy 1: Find first FREE station (not occupied)
	for station in available_stations:
		if station.has_method("has_ingredient") and not station.has_ingredient():
			print("IS THE STATION TAKEN???",station.get("reserved_by"))
			if station.get("reserved_by")== -1:
				print("[BOT %d] Reserving free station: %s" % [bot_id, station.station_id])
				station.reserved_by = bot_id  # Réserve-la !
				return station

	
	# Strategy 2: All busy - pick random to distribute load
	var random_station = available_stations[randi() % available_stations.size()]
	print("[BOT %d] All busy, picking random: %s" % [bot_id, random_station.name])
	return random_station

func _release_station_reservation() -> void:
	"""Release reservation on current target station"""
	if target_station and "reserved_by" in target_station:
		if target_station.reserved_by == bot_id:
			target_station.reserved_by = -1
			print("[BOT %d] Released reservation on %s" % [bot_id, target_station.name])
# ==================== STATION INTERACTIONS ====================
func _on_arrived_at_station() -> void:
	"""Handle arrival at target station"""
	
	var station_type: String = flow_steps[current_step]
	#liberer la station: 
	_release_station_reservation()

	match station_type:
		"Ingredient":
			current_action = Action.TAKE_INGREDIENT
		
		"Chopping", "Cooking":
			if carried_item != null:
				current_action = Action.PLACE_ITEM
			else:
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
	
	# === INGREDIENT STATION: Spawn and take ===
	if station_type == "Ingredient":
		# Check if station is occupied
		if target_station.has_method("has_ingredient") and target_station.has_ingredient():
			print("[BOT %d] Station occupied, waiting..." % bot_id)
			wait_timer = 0.0
			current_action = Action.WAIT_FOR_STATION
			return
		
		print("[BOT %d] Spawning %s at Ingredient station" % [bot_id, current_ingredient])
		
		if _gm and _gm.has_method("spawn_ingredient"):
			var item_node = _gm.spawn_ingredient(current_ingredient, target_station.get_parent())
			
			if item_node:
				if target_station.has_method("place_item"):
					if target_station.place_item(item_node):
						print("[BOT %d] Ingredient spawned and placed on station" % bot_id)
						
						# Small delay for visuals
						await get_tree().create_timer(0.1).timeout
						
						# Check if item still exists
						if not target_station.has_ingredient():
							print("[BOT %d] Item disappeared, waiting for next chance..." % bot_id)
							wait_timer = 0.0
							current_action = Action.WAIT_FOR_STATION
							return
						
						var taken_item = _take_item_node_from(target_station)
						if taken_item:
							carried_item = taken_item
							carried_item_type = current_ingredient
							_pickup_item_visual(taken_item)
							print("[BOT %d] Took: %s" % [bot_id, current_ingredient])
							retry_count = 0
							current_step += 1
							_go_to_next_step()
						else:
							print("[BOT %d] Failed to take, retrying..." % bot_id)
							_handle_station_failure()
					else:
						# Station occupied - clean up and wait
						print("[BOT %d] Failed to place - station busy, cleaning up..." % bot_id)
						item_node.queue_free()
						wait_timer = 0.0
						current_action = Action.WAIT_FOR_STATION
				else:
					push_error("[BOT %d] Station missing place_item method" % bot_id)
					item_node.queue_free()
					_handle_station_failure()
			else:
				push_error("[BOT %d] Failed to spawn ingredient" % bot_id)
				_handle_station_failure()
		else:
			push_error("[BOT %d] GameManager missing spawn_ingredient method" % bot_id)
			_handle_station_failure()
		return
	
	# === CHOPPING / COOKING: Take processed item ===
	if target_station.has_method("has_ingredient") and not target_station.has_ingredient():
		print("[BOT %d] No item ready at station, waiting..." % bot_id)
		wait_timer = 0.0
		current_action = Action.WAIT_FOR_STATION
		return
	
	var item_node = _take_item_node_from(target_station)
	if item_node:
		carried_item = item_node
		_pickup_item_visual(item_node)
		print("[BOT %d] Took processed item" % bot_id)
		retry_count = 0
		current_step += 1
		_go_to_next_step()
	else:
		print("[BOT %d] Failed to take from %s, retrying..." % [bot_id, station_type])
		_handle_station_failure()


func _wait_for_station(delta: float) -> void:
	"""Wait for a station to become available"""
	_stop(delta)
	wait_timer += delta
	
	if wait_timer >= max_wait_time:
		retry_count += 1
		if retry_count >= max_retries:
			push_error("[BOT %d] Station timeout after %d retries, skipping task" % [bot_id, max_retries])
			_request_next_task()
		else:
			print("[BOT %d] Retry %d/%d - attempting station again" % [bot_id, retry_count, max_retries])
			wait_timer = 0.0
			current_action = Action.TAKE_INGREDIENT
	else:
		# Periodically retry (every 0.5 seconds)
		if fmod(wait_timer, 0.5) < delta:
			var station_type: String = flow_steps[current_step]
			if station_type == "Ingredient":
				if not target_station.has_ingredient():
					print("[BOT %d] Station free, retrying..." % bot_id)
					current_action = Action.TAKE_INGREDIENT
			else:
				if target_station.has_ingredient():
					print("[BOT %d] Item ready, retrying..." % bot_id)
					current_action = Action.TAKE_INGREDIENT


func _handle_station_failure() -> void:
	"""Handle failure to interact with station"""
	retry_count += 1
	if retry_count >= max_retries:
		push_error("[BOT %d] Failed after %d retries, requesting new task" % [bot_id, max_retries])
		_request_next_task()
	else:
		print("[BOT %d] Retry %d/%d after failure" % [bot_id, retry_count, max_retries])
		wait_timer = 0.0
		current_action = Action.WAIT_FOR_STATION


func _place_on_station() -> void:
	"""Place carried item on the current station"""
	if not carried_item or not target_station:
		_go_to_next_step()
		return
	
	# Check if station is available (for non-serving stations)
	var station_type: String = flow_steps[current_step]
	if station_type != "Serving":
		if target_station.has_method("has_ingredient") and target_station.has_ingredient():
			print("[BOT %d] Station occupied, waiting to place..." % bot_id)
			wait_timer = 0.0
			current_action = Action.WAIT_FOR_STATION
			return
	
	# Place item
	var success := false
	
	if station_type == "Serving" and target_station.has_method("place_item"):
		# Serving stations need recipe_id parameter
		success = target_station.place_item(carried_item, current_recipe_id)
	else:
		# Other stations use normal helper
		success = _place_item_node_on(target_station, carried_item)
	
	if success:
		print("[BOT %d] Placed on %s (recipe: %s)" % [bot_id, station_type, current_recipe_id])
		carried_item = null
		carried_item_type = ""
		retry_count = 0
		current_action = Action.PROCESS_ITEM
	else:
		push_error("[BOT %d] Failed to place item" % bot_id)
		_handle_station_failure()


func _process_at_station() -> void:
	"""Process item at the current station"""
	if not target_station:
		_go_to_next_step()
		return
	
	var station_type: String = flow_steps[current_step]
	
	# Serving station: item already placed
	if station_type == "Serving":
		if _gm and _gm.has_method("notify_served"):
			_gm.notify_served(current_ingredient)
		
		print("[BOT %d] Placed on serving station: %s" % [bot_id, current_ingredient])
		carried_item = null
		carried_item_type = ""
		current_step += 1
		_go_to_next_step()
		return
	
	# Other stations: process then take
	_call_interact(target_station)
	
	var item_node = _take_item_node_from(target_station)
	if item_node:
		carried_item = item_node
		_pickup_item_visual(item_node)
		print("[BOT %d] Processed at %s" % [bot_id, station_type])
		retry_count = 0
		current_step += 1
		_go_to_next_step()
	else:
		push_error("[BOT %d] Failed to take processed item" % bot_id)
		_handle_station_failure()


# ==================== MOVEMENT ====================
func _move_toward_target(delta: float) -> void:
	"""Move bot towards target position"""
	var direction = (target_position - global_position).normalized()
	var distance = global_position.distance_to(target_position)
	
	if distance > stop_distance:
		velocity = velocity.move_toward(direction * speed, accel * delta)
	else:
		velocity = velocity.move_toward(Vector2.ZERO, accel * delta)


func _stop(delta: float) -> void:
	"""Gradually stop the bot"""
	velocity = velocity.move_toward(Vector2.ZERO, accel * delta)


func _at_target() -> bool:
	"""Check if bot has reached target position"""
	return global_position.distance_to(target_position) <= stop_distance


# ==================== HELPERS ====================
func playAnim(b: bool):
	"""Play or stop hop animation"""
	if b:
		animPlayer.play("hop")
	else:
		animPlayer.stop()


func _call_interact(station: Node) -> void:
	"""Call interact method on station"""
	if station and station.has_method("interact"):
		station.interact()


func _take_item_node_from(station: Node) -> Node:
	"""Take item from station"""
	if station and station.has_method("take_item"):
		var result = station.take_item()
		return result if result is Node else null
	return null


func _place_item_node_on(station: Node, item: Node) -> bool:
	"""Place item on station"""
	if station and station.has_method("place_item"):
		return bool(station.place_item(item))
	return false


func _pickup_item_visual(item: Node) -> void:
	"""Visual handling for picking up an item"""
	if item and item.has_method("pick_up"):
		item.pick_up(self, Vector2(0, -16))
	elif item:
		if item.get_parent():
			item.get_parent().remove_child(item)
		add_child(item)
		item.position = Vector2(0, -16)

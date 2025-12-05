extends CharacterBody2D

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

var _gm: Node = null
var stations: Dictionary = {}

var current_ingredient: String = ""
var current_recipe_id: String = ""
var flow_steps: Array = []
var current_step: int = 0
var carried_item: Node = null
var carried_item_type: String = ""

var current_action: Action = Action.IDLE
var target_position: Vector2 = Vector2.ZERO
var target_station: Node = null
var wait_timer: float = 0.0
var max_wait_time: float = 2.0
var retry_count: int = 0
var max_retries: int = 3

@onready var sprite = $Sprite2D

func _ready() -> void:
	add_to_group("bots")  # NEW: Add to bots group for counting
	playAnim(true)
	_gm = get_tree().get_first_node_in_group("game_manager")
	if not _gm:
		push_error("[BOT %d] GameManager not found!" % bot_id)
		set_physics_process(false)
		return
	
	if _gm.has_signal("new_orders_available"):
		_gm.connect("new_orders_available", _on_new_orders_available)
	
	_find_stations()
	_request_next_task()
	
	print("[BOT %d] Ready | Default recipe: %s" % [bot_id, recipe_name])

func _on_new_orders_available() -> void:
	if current_action == Action.IDLE:
		print("[BOT %d] 📢 New orders available! Requesting task..." % bot_id)
		_request_next_task()

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

func _request_next_task() -> void:
	# Clean up any carried items
	if carried_item and is_instance_valid(carried_item):
		print("[BOT %d] ⚠️ Cleaning up carried item before new task" % bot_id)
		carried_item.queue_free()
		carried_item = null
		carried_item_type = ""
	
	# Release any reserved station
	if target_station and target_station.has_method("unreserve"):
		target_station.unreserve(bot_id)
	target_station = null
	
	if not _gm or not _gm.has_method("request_next_ingredient"):
		print("[BOT %d] Cannot request task - GameManager missing method" % bot_id)
		current_action = Action.IDLE
		return
	
	var result = _gm.request_next_ingredient(bot_id)
	current_recipe_id = ""
	current_ingredient = ""
	retry_count = 0
	
	if typeof(result) == TYPE_DICTIONARY:
		current_recipe_id = str(result.get("recipe_id", ""))
		current_ingredient = str(result.get("ingredient_id", ""))
	else:
		current_recipe_id = recipe_name
		current_ingredient = str(result) if result != null else ""
	
	if current_ingredient == "":
		print("[BOT %d] ✅ No more tasks - all done!" % bot_id)
		current_action = Action.IDLE
		return
	
	current_step = 0
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
		if _gm and _gm.has_method("notify_served"):
			_gm.notify_served(current_ingredient)
		_request_next_task()
		return
	
	var station_type: String = flow_steps[current_step]
	
	# Find appropriate station
	if station_type == "Serving":
		target_station = _find_serving_station_for_recipe(current_recipe_id)
		if not target_station:
			push_error("[BOT %d] ❌ No serving station for recipe '%s' - abandoning task" % [bot_id, current_recipe_id])
			if carried_item and is_instance_valid(carried_item):
				carried_item.queue_free()
				carried_item = null
				carried_item_type = ""
			_request_next_task()
			return
	else:
		target_station = _find_best_station(station_type)
	
	if not target_station:
		push_error("[BOT %d] Station not found: %s" % [bot_id, station_type])
		current_action = Action.IDLE
		return
	
	# Try to reserve the station
	if target_station.has_method("reserve"):
		if not target_station.reserve(bot_id):
			print("[BOT %d] ⏳ Station %s reserved by another bot, waiting..." % [bot_id, station_type])
			wait_timer = 0.0
			current_action = Action.WAIT_FOR_STATION
			return
	
	target_position = target_station.global_position
	current_action = Action.MOVE
	
	print("[BOT %d] → Moving to %s (%s)" % [bot_id, station_type, target_station.name])

func _find_serving_station_for_recipe(recipe_id: String) -> Node:
	"""Find the serving station that accepts this recipe"""
	if _gm and _gm.has_method("find_serving_station_for_recipe"):
		var station = _gm.find_serving_station_for_recipe(recipe_id)
		if station:
			print("[BOT %d] 🎯 Found serving station '%s' for recipe '%s'" % [bot_id, station.name, recipe_id])
			return station
	
	# No dedicated station found - this is a critical error
	return null

func _find_best_station(station_type: String) -> Node:
	"""Find the best available station using load balancing"""
	if not _gm or not _gm.has_method("_register_stations"):
		return stations.get(station_type)
	
	if not _gm.stations_by_type.has(station_type):
		push_error("[BOT %d] No stations of type: %s" % [bot_id, station_type])
		return null
	
	var available: Array = _gm.stations_by_type[station_type]
	if available.is_empty():
		return null
	
	# Find best station by availability AND distance
	var best_station = null
	var best_score = INF
	
	for station in available:
		# Check if station is available
		if station.has_method("is_available") and not station.is_available():
			continue
		
		# Calculate score (distance + penalty for occupied)
		var distance = global_position.distance_to(station.global_position)
		var score = distance
		
		# Add penalty if station has ingredient (prefer empty stations)
		if station.has_method("has_ingredient") and station.has_ingredient():
			score += 200.0  # penalty
		
		if score < best_score:
			best_score = score
			best_station = station
	
	# If no available station, use closest one anyway
	if not best_station:
		var closest_distance = INF
		for station in available:
			var distance = global_position.distance_to(station.global_position)
			if distance < closest_distance:
				closest_distance = distance
				best_station = station
	
	return best_station

func _on_arrived_at_station() -> void:
	if current_step >= flow_steps.size():
		_request_next_task()
		return
	
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
			if carried_item != null:
				current_action = Action.PLACE_ITEM
			else:
				current_action = Action.PROCESS_ITEM

func _take_from_station() -> void:
	if not target_station:
		_go_to_next_step()
		return
	
	if current_step >= flow_steps.size():
		_request_next_task()
		return
	
	var station_type: String = flow_steps[current_step]
	
	if station_type == "Ingredient":
		if target_station.has_method("has_ingredient") and target_station.has_ingredient():
			print("[BOT %d] ⏳ Station occupied, waiting..." % bot_id)
			wait_timer = 0.0
			current_action = Action.WAIT_FOR_STATION
			return
		
		print("[BOT %d] 🏭 Spawning %s at Ingredient station" % [bot_id, current_ingredient])
		
		if _gm and _gm.has_method("spawn_ingredient"):
			var item_node = _gm.spawn_ingredient(current_ingredient, target_station.get_parent())
			
			if item_node:
				if target_station.has_method("place_item"):
					if target_station.place_item(item_node):
						print("[BOT %d] 📦 Ingredient spawned and placed on station" % bot_id)
						
						await get_tree().create_timer(0.1).timeout
						
						if not target_station.has_ingredient():
							print("[BOT %d] ⚠️ Item disappeared (taken by another bot)" % bot_id)
							wait_timer = 0.0
							current_action = Action.WAIT_FOR_STATION
							return
						
						var taken_item = _take_item_node_from(target_station)
						if taken_item:
							carried_item = taken_item
							carried_item_type = current_ingredient
							_pickup_item_visual(taken_item)
							print("[BOT %d] 📦 Took: %s" % [bot_id, current_ingredient])
							
							# Release station reservation
							if target_station.has_method("unreserve"):
								target_station.unreserve(bot_id)
							
							retry_count = 0
							current_step += 1
							_go_to_next_step()
						else:
							print("[BOT %d] ⚠️ Failed to take spawned ingredient" % bot_id)
							_handle_station_failure()
					else:
						print("[BOT %d] ⚠️ Failed to place - station busy, cleaning up..." % bot_id)
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
	
	if target_station.has_method("has_ingredient") and not target_station.has_ingredient():
		print("[BOT %d] ⏳ No item ready at station, waiting..." % bot_id)
		wait_timer = 0.0
		current_action = Action.WAIT_FOR_STATION
		return
	
	var item_node = _take_item_node_from(target_station)
	if item_node:
		carried_item = item_node
		_pickup_item_visual(item_node)
		print("[BOT %d] 📦 Took processed item" % bot_id)
		
		# Release station
		if target_station.has_method("unreserve"):
			target_station.unreserve(bot_id)
		
		retry_count = 0
		current_step += 1
		_go_to_next_step()
	else:
		print("[BOT %d] ⚠️ Failed to take from %s, waiting..." % [bot_id, station_type])
		wait_timer = 0.0
		current_action = Action.WAIT_FOR_STATION

# Replace the _wait_for_station function in bot.gd:

func _wait_for_station(delta: float) -> void:
	_stop(delta)
	wait_timer += delta
	
	if current_step >= flow_steps.size():
		_request_next_task()
		return
	
	if wait_timer >= max_wait_time:
		retry_count += 1
		
		# SPECIAL CASE: If we're carrying an ingredient, we MUST place it
		if carried_item and is_instance_valid(carried_item):
			if retry_count >= max_retries:
				# Even after max retries, if carrying item, keep trying but wait longer
				print("[BOT %d] ⚠️ Still carrying item after %d retries, extending wait..." % [bot_id, max_retries])
				wait_timer = 0.0
				max_wait_time = 4.0  # Wait longer
				retry_count = max_retries - 1  # Keep just below max
				
				# Try to find ANY valid station for this step
				var station_type: String = flow_steps[current_step]
				if target_station and target_station.has_method("unreserve"):
					target_station.unreserve(bot_id)
				
				target_station = _find_best_station(station_type)
				if target_station:
					target_position = target_station.global_position
					current_action = Action.MOVE
				return
		
		# Normal retry logic for when NOT carrying an ingredient
		if retry_count >= max_retries:
			push_error("[BOT %d] ❌ Station timeout after %d retries, abandoning task" % [bot_id, max_retries])
			
			if target_station and target_station.has_method("unreserve"):
				target_station.unreserve(bot_id)
			
			if carried_item and is_instance_valid(carried_item):
				print("[BOT %d] 🗑️ Dropping carried item due to timeout" % bot_id)
				carried_item.queue_free()
				carried_item = null
				carried_item_type = ""
			_request_next_task()
		else:
			print("[BOT %d] 🔄 Retry %d/%d - finding new station" % [bot_id, retry_count, max_retries])
			wait_timer = 0.0
			
			if target_station and target_station.has_method("unreserve"):
				target_station.unreserve(bot_id)
			
			var station_type: String = flow_steps[current_step]
			target_station = _find_best_station(station_type)
			
			if target_station:
				target_position = target_station.global_position
				current_action = Action.MOVE
			else:
				_request_next_task()
				
func _handle_station_failure() -> void:
	retry_count += 1
	if retry_count >= max_retries:
		# CRITICAL FIX: Don't abandon the ingredient if we're carrying it!
		if carried_item and is_instance_valid(carried_item):
			# We have an ingredient but can't place it - wait and retry with same ingredient
			print("[BOT %d] ⚠️ Failed to place item after %d retries, waiting before retry..." % [bot_id, max_retries])
			
			# Release reservation on current station
			if target_station and target_station.has_method("unreserve"):
				target_station.unreserve(bot_id)
			
			# Reset retry count and try to find station again after a brief wait
			retry_count = 0
			wait_timer = 0.0
			current_action = Action.WAIT_FOR_STATION
			return
		
		# If we don't have an ingredient, we can safely abandon and get new task
		push_error("[BOT %d] ❌ Failed after %d retries - abandoning task" % [bot_id, max_retries])
		
		if target_station and target_station.has_method("unreserve"):
			target_station.unreserve(bot_id)
		
		_request_next_task()
	else:
		print("[BOT %d] ⚠️ Retry %d/%d after failure" % [bot_id, retry_count, max_retries])
		wait_timer = 0.0
		current_action = Action.WAIT_FOR_STATION
		
func _place_on_station() -> void:
	if not carried_item or not target_station:
		_go_to_next_step()
		return
	
	if current_step >= flow_steps.size():
		_request_next_task()
		return
	
	var station_type: String = flow_steps[current_step]
	
	# For serving stations, verify it's the correct one
	if station_type == "Serving":
		if "recipe_id" in target_station and target_station.recipe_id != "" and target_station.recipe_id != current_recipe_id:
			push_error("[BOT %d] ❌ Wrong serving station! Expected '%s' but at '%s' - finding correct one" % 
				[bot_id, current_recipe_id, target_station.recipe_id])
			
			# DON'T enter infinite loop - abandon task if we can't find right station
			var correct_station = _find_serving_station_for_recipe(current_recipe_id)
			if correct_station and correct_station != target_station:
				target_station = correct_station
				target_position = target_station.global_position
				current_action = Action.MOVE
				print("[BOT %d] 🔄 Moving to correct serving station '%s'" % [bot_id, target_station.name])
				return
			else:
				# Can't find right station - abandon
				push_error("[BOT %d] ❌ Cannot find correct serving station - abandoning" % bot_id)
				_handle_station_failure()
				return
	
	var success := false
	if station_type == "Serving":
		if target_station.has_method("place_item"):
			success = target_station.place_item(carried_item, current_recipe_id)
		else:
			success = _place_item_node_on(target_station, carried_item)
	else:
		if station_type != "Cooking":
			if target_station.has_method("has_ingredient") and target_station.has_ingredient():
				print("[BOT %d] ⏳ Station occupied, waiting to place..." % bot_id)
				wait_timer = 0.0
				current_action = Action.WAIT_FOR_STATION
				return
		success = _place_item_node_on(target_station, carried_item)
	
	if success:
		print("[BOT %d] 🍽️ Placed on %s (recipe: %s)" % [bot_id, station_type, current_recipe_id])
		carried_item = null
		carried_item_type = ""
		retry_count = 0
		
		current_action = Action.PROCESS_ITEM
	else:
		push_error("[BOT %d] Failed to place item" % bot_id)
		_handle_station_failure()

func _process_at_station() -> void:
	if not target_station:
		_go_to_next_step()
		return
	
	if current_step >= flow_steps.size():
		_request_next_task()
		return
	
	var station_type: String = flow_steps[current_step]
	
	if station_type == "Serving":
		if _gm and _gm.has_method("notify_served"):
			_gm.notify_served(current_ingredient)
		
		print("[BOT %d] ✅ Placed on serving station: %s" % [bot_id, current_ingredient])
		
		# Release station
		if target_station.has_method("unreserve"):
			target_station.unreserve(bot_id)
		
		carried_item = null
		carried_item_type = ""
		current_step += 1
		_go_to_next_step()
		return
	
	# For Chopping and Cooking: process then take
	_call_interact(target_station)
	
	var item_node = _take_item_node_from(target_station)
	if item_node:
		# NEW: Pass recipe context to the ingredient
		if item_node.has_method("apply_stage"):
			item_node.apply_stage(station_type, current_recipe_id)
		
		carried_item = item_node
		_pickup_item_visual(item_node)
		print("[BOT %d] ⚙️ Processed at %s" % [bot_id, station_type])
		
		# Release station
		if target_station.has_method("unreserve"):
			target_station.unreserve(bot_id)
		
		retry_count = 0
		current_step += 1
		_go_to_next_step()
	else:
		push_error("[BOT %d] Failed to take processed item" % bot_id)
		_handle_station_failure()
								
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

func _find_stations() -> void:
	stations.clear()
	for station in get_tree().get_nodes_in_group("stations"):
		if "station_type" in station:
			stations[station.station_type] = station
	print("[BOT %d] Found stations: %s" % [bot_id, stations.keys()])

func playAnim(b: bool):
	if animPlayer:
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
		return bool(station.place_item(item, current_recipe_id))
	return false

func _pickup_item_visual(item: Node) -> void:
	if item and item.has_method("pick_up"):
		item.pick_up(self, Vector2(0, -16))
	elif item:
		if item.get_parent():
			item.get_parent().remove_child(item)
		add_child(item)
		item.position = Vector2(0, -16)

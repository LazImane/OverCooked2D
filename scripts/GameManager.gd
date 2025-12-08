extends Node
# GameManager: Manages recipes, ingredients, and bot task assignment

@export var ingredient_scene: PackedScene = null
@export var time_label: Label 
@export var endless_mode: bool = true
@export var order_delay: float = 2.0
@export var min_active_orders: int = 3

signal new_orders_available

var recipes: Dictionary = {}
var ingredients: Dictionary = {}
var stations_by_type: Dictionary = {}
var orders: Array = []
var active_recipe_timers: Dictionary = {}
var _recipe_instance_counter: Dictionary = {}  # recipe_id -> counter
var completed_recipes: Array = []
var current_recipe_id: String = "demo_salad"
var _order_queue: Array = []
var _total_needed: int = 0
var _served_count: int = 0
var _spawn_idx: int = 0
var _current_time: float = 0.0
var _orders_completed: int = 0
var _pending_orders: int = 0
var _in_progress_orders: int = 0
var _bot_recipes: Dictionary = {}  # bot_id -> recipe_id
var moyennetemps: Array = []
var summoy : float = 0.0


func _ready() -> void:
	add_to_group("game_manager")
	_register_stations()
	_setup_recipes()
	_setup_orders()
	# DON'T build queue yet - let bots request tasks on demand
	print("[GM] Ready | Orders: %d" % orders.size())


# ==================== TIMER MANAGEMENT ====================
func _start_recipe_timer(recipe_id: String) -> String:
	if not _recipe_instance_counter.has(recipe_id):
		_recipe_instance_counter[recipe_id] = 0
	
	_recipe_instance_counter[recipe_id] += 1
	var timer_key = "%s_%d" % [recipe_id, _recipe_instance_counter[recipe_id]]
	
	active_recipe_timers[timer_key] = _current_time
	print("[GM] Timer started for '%s' (key: %s) at %.2fs" % [recipe_id, timer_key, _current_time])
	return timer_key

func _complete_recipe_timer(recipe_id: String) -> float:
	"""Complete the oldest timer for this recipe_id"""
	var oldest_key = ""
	var oldest_time = INF
	
	for key in active_recipe_timers.keys():
		if key.begins_with(recipe_id + "_"):
			var start_time = active_recipe_timers[key]
			if start_time < oldest_time:
				oldest_time = start_time
				oldest_key = key
	
	if oldest_key == "":
		push_warning("[GM] No timer found for recipe '%s'" % recipe_id)
		return 0.0

	var start_time = active_recipe_timers[oldest_key]
	var completion_time = _current_time - start_time

	
	completed_recipes.append({
		"recipe_id": recipe_id,
		"score": completion_time,
		"completed_at": _current_time
	})
	moyennetemps.append(completion_time)

	
	active_recipe_timers.erase(oldest_key)
	_orders_completed += 1
	_in_progress_orders -= 1
	
	print("[GM] Recipe '%s' completed in %.2f seconds! (Total completed: %d)" % 
		[recipe_id, completion_time, _orders_completed])
	
	if endless_mode:
		_spawn_new_order()
	
	return completion_time

func _spawn_new_order() -> void:
	if not endless_mode:
		return
	
	print("[GM] 📋 Spawning new order...")
	var old_size = orders.size()
	_add_random_order()
	_rebuild_order_queue_incremental(old_size)
	_pending_orders += 1
	
	emit_signal("new_orders_available")
	
	print("[GM] 📋 New order added! Active orders: %d, Queue size: %d" % [orders.size(), _order_queue.size()])


# ==================== STATION REGISTRATION ====================
func _register_stations() -> void:
	stations_by_type.clear()
	for station in get_tree().get_nodes_in_group("stations"):
		if not "station_type" in station:
			continue
		var t: String = station.station_type
		if t == "":
			continue
		if not stations_by_type.has(t):
			stations_by_type[t] = []
		stations_by_type[t].append(station)
	print("[GM] Registered stations:", stations_by_type.keys())


# ==================== SERVING STATION LOOKUP ====================
func find_serving_station_for_recipe(recipe_id: String) -> Node:
	"""Find the correct serving station for a specific recipe"""
	if not stations_by_type.has("Serving"):
		push_error("[GM] No serving stations registered!")
		return null
	
	var serving_stations: Array = stations_by_type["Serving"]
	
	# First, try to find a dedicated station for this recipe
	for station in serving_stations:
		if "recipe_id" in station and station.recipe_id == recipe_id:
			# CRITICAL FIX: Check if station is available (not animating or completed)
			if station.has_method("is_available") and not station.is_available():
				continue  # Skip stations that are busy animating or already full
			
			# Extra check for the _is_animating flag specifically
			if "_is_animating" in station and station._is_animating:
				continue  # Station is animating completion
			
			# Check if recipe is already completed
			if "_recipe_completed" in station and station._recipe_completed:
				continue  # Skip this one, it's busy
				
			print("[GM] 🎯 Found dedicated serving station '%s' for recipe '%s'" % [station.name, recipe_id])
			return station
	
	# Fallback: find a station that accepts all recipes (empty recipe_id)
	for station in serving_stations:
		if "recipe_id" in station and station.recipe_id == "":
			# Same availability checks
			if station.has_method("is_available") and not station.is_available():
				continue
			
			if "_is_animating" in station and station._is_animating:
				continue
				
			if "_recipe_completed" in station and station._recipe_completed:
				continue
				
			print("[GM] 🎯 Using universal serving station '%s' for recipe '%s'" % [station.name, recipe_id])
			return station
	
	# IMPORTANT: If no station found, it might be temporarily busy animating
	# Check if there's at least one station for this recipe that exists
	var has_station_for_recipe = false
	for station in serving_stations:
		if ("recipe_id" in station and station.recipe_id == recipe_id) or \
		   ("recipe_id" in station and station.recipe_id == ""):
			has_station_for_recipe = true
			break
	
	if has_station_for_recipe:
		# Station exists but is temporarily busy - this is NOT an error
		print("[GM] ⏳ Serving station for recipe '%s' temporarily busy (animating)" % recipe_id)
		return null
	else:
		# No station exists for this recipe at all - this IS an error
		push_error("[GM] ❌ No serving station found for recipe '%s'! Please add one." % recipe_id)
		return null
		

# ==================== RECIPE SETUP ====================
func _setup_recipes() -> void:
	ingredients = {
		"lettuce": {"id": "lettuce", "name": "Lettuce", "status": "raw"},
		"tomato": {"id": "tomato", "name": "Tomato", "status": "raw"},
		"cucumber": {"id": "cucumber", "name": "Cucumber", "status": "raw"},
		"olive": {"id": "olive", "name": "Olive", "status": "raw"},
		"carrot": {"id": "carrot", "name": "Carrot", "status": "raw"},
		"potato": {"id": "potato", "name": "Potato", "status": "raw"},
		"onion": {"id": "onion", "name": "Onion", "status": "raw"},
		"cheese": {"id": "cheese", "name": "Cheese", "status": "raw"},
		"broccoli": {"id": "broccoli", "name": "Broccoli", "status": "raw"}
	}
	
	recipes = {
		"demo_salad": {
			"name": "Greek Salad",
			"base_items": ["lettuce", "tomato", "cucumber", "olive"],
			"flow": ["Ingredient", "Chopping", "Serving"],
			"per_item_flow": {
				"olive": ["Ingredient", "Chopping", "Cooking", "Serving"]
			}
		},
		"tomato_soup": {
			"name": "Tomato Soup",
			"base_items": ["tomato", "tomato"],
			"flow": ["Ingredient", "Chopping", "Cooking", "Serving"]
		},
		"veggie_stir_fry": {
			"name": "Veggie Stir Fry",
			"base_items": ["carrot", "onion", "broccoli"],
			"flow": ["Ingredient", "Chopping", "Cooking", "Serving"]
		},
		"caesar_salad": {
			"name": "Caesar Salad",
			"base_items": ["lettuce", "cheese"],
			"flow": ["Ingredient", "Chopping", "Serving"]
		},
		"potato_soup": {
			"name": "Potato Soup",
			"base_items": ["potato", "potato", "onion"],
			"flow": ["Ingredient", "Chopping", "Cooking", "Serving"]
		},
		"garden_salad": {
			"name": "Garden Salad",
			"base_items": ["lettuce", "tomato", "carrot"],
			"flow": ["Ingredient", "Chopping", "Serving"]
		}
	}


# ==================== ORDER LIST SETUP ====================
func _setup_orders() -> void:
	orders.clear()
	_pending_orders = 0
	_in_progress_orders = 0

	if endless_mode:
		for i in range(min_active_orders):
			_add_random_order()
			_pending_orders += 1
	else:
		_add_order("demo_salad")
		_add_order("tomato_soup")
		_add_order("veggie_stir_fry")
		_add_order("caesar_salad")
		_add_order("potato_soup")
		_pending_orders = orders.size()

	if orders.size() > 0:
		current_recipe_id = orders[0]["recipe_id"]


func _add_random_order() -> void:
	var recipe_keys = recipes.keys()
	var random_recipe = recipe_keys[randi() % recipe_keys.size()]
	_add_order(random_recipe)


func _add_order(recipe_id: String) -> void:
	if not recipes.has(recipe_id):
		push_error("[GM] Cannot add order: unknown recipe_id '%s'" % recipe_id)
		return

	var base_items: Array = recipes[recipe_id].get("base_items", [])
	var order := {
		"recipe_id": recipe_id,
		"base_items": base_items.duplicate(),
		"status": "pending",
		"start_time": 0.0,
		"completion_time": 0.0
	}
	orders.append(order)
	print("[GM] Added order for recipe '%s' with %d items" % [recipe_id, base_items.size()])


func _rebuild_order_queue() -> void:
	_order_queue.clear()
	_served_count = 0
	_total_needed = 0

	for order_idx in orders.size():
		var order = orders[order_idx]
		var recipe_id: String = order.get("recipe_id", "")
		var base_items: Array = order.get("base_items", [])
		for base in base_items:
			var item_id := str(base)
			_order_queue.append({
				"recipe_id": recipe_id,
				"ingredient_id": item_id,
				"order_index": order_idx
			})
			_total_needed += 1

	print("[GM] Queue built: %d orders, %d ingredients queued" %
		[orders.size(), _total_needed])


func _rebuild_order_queue_incremental(start_idx: int) -> void:
	for order_idx in range(start_idx, orders.size()):
		var order = orders[order_idx]
		var recipe_id: String = order.get("recipe_id", "")
		var base_items: Array = order.get("base_items", [])
		for base in base_items:
			var item_id := str(base)
			_order_queue.append({
				"recipe_id": recipe_id,
				"ingredient_id": item_id,
				"order_index": order_idx
			})
			_total_needed += 1


func _prepare_recipe_order(recipe_id: String) -> void:
	orders.clear()
	_add_order(recipe_id)
	_rebuild_order_queue()
	current_recipe_id = recipe_id


# ==================== BOT TASK ASSIGNMENT ====================
func request_next_ingredient(bot_id: int) -> Dictionary:
	# FIRST TIME: Build the queue if it's empty and we have orders
	if _order_queue.is_empty() and orders.size() > 0:
		_rebuild_order_queue()
		print("[GM] 📋 Building initial task queue: %d tasks from %d orders" % [_order_queue.size(), orders.size()])
	
	# Check if this bot is already committed to a recipe
	var bot_current_recipe = _bot_recipes.get(bot_id, "")
	
	# If bot has a recipe in progress, ONLY give tasks from that recipe
	if bot_current_recipe != "":
		var task = _find_task_for_recipe(bot_current_recipe)
		if task.size() > 0:
			# Found a task for the current recipe, continue with it
			_remove_task_from_queue(task)
			_mark_recipe_in_progress(task)
			print("[GM] 🔒 Bot %d continuing recipe '%s' - %s (%d remaining)" % 
				[bot_id, bot_current_recipe, task.get("ingredient_id", ""), _order_queue.size()])
			return task
		else:
			# Recipe complete! Bot is now free for a new recipe
			print("[GM] ✅ Bot %d completed recipe '%s', now available for new tasks" % [bot_id, bot_current_recipe])
			_bot_recipes.erase(bot_id)
			bot_current_recipe = ""
	
	# Bot is free - spawn new orders if needed (only when bots need work)
	if endless_mode:
		var available_tasks = _order_queue.size()
		var free_bots = _count_free_bots()
		
		# Only spawn if we don't have enough tasks for free bots
		if available_tasks < free_bots:
			var orders_to_spawn = free_bots - available_tasks
			print("[GM] 📋 %d free bots need work, spawning %d new orders" % [free_bots, orders_to_spawn])
			for i in range(orders_to_spawn):
				_spawn_new_order()
	
	if _order_queue.is_empty():
		print("[GM] No more ingredients available for bot %d" % bot_id)
		return {}
	
	# Find the best task (prioritize recipes closest to completion)
	var best_task_idx = _find_best_task_index()
	
	if best_task_idx == -1:
		print("[GM] No valid tasks found for bot %d" % bot_id)
		return {}
	
	var task: Dictionary = _order_queue[best_task_idx]
	_order_queue.remove_at(best_task_idx)
	
	var recipe_id: String = task.get("recipe_id", "")
	var ingredient_id: String = task.get("ingredient_id", "")
	
	# COMMIT this bot to this recipe
	_bot_recipes[bot_id] = recipe_id
	
	# Mark recipe as in progress if needed
	_mark_recipe_in_progress(task)
	
	print("[GM] 🆕 Bot %d starting NEW recipe '%s' - %s (%d remaining | %d pending | %d in progress)" %
		[bot_id, recipe_id, ingredient_id, _order_queue.size(), _pending_orders, _in_progress_orders])
	return task


func _count_free_bots() -> int:
	"""Count how many bots are NOT currently committed to a recipe"""
	var total_bots = get_tree().get_nodes_in_group("bots").size()
	var busy_bots = _bot_recipes.size()
	return max(0, total_bots - busy_bots)


func _find_task_for_recipe(recipe_id: String) -> Dictionary:
	"""Find any task for a specific recipe"""
	for task in _order_queue:
		if task.get("recipe_id", "") == recipe_id:
			return task
	return {}


func _remove_task_from_queue(task: Dictionary) -> void:
	"""Remove a specific task from the queue"""
	for i in range(_order_queue.size()):
		if _order_queue[i] == task:
			_order_queue.remove_at(i)
			return


func _mark_recipe_in_progress(task: Dictionary) -> void:
	"""Mark a recipe as in progress and start timer"""
	var recipe_id: String = task.get("recipe_id", "")
	var order_index: int = task.get("order_index", -1)
	
	if order_index >= 0 and order_index < orders.size():
		if orders[order_index]["status"] == "pending":
			orders[order_index]["status"] = "in_progress"
			orders[order_index]["start_time"] = _current_time
			_start_recipe_timer(recipe_id)
			_pending_orders -= 1
			_in_progress_orders += 1
			print("[GM] 🚀 Recipe '%s' now IN PROGRESS (order #%d)" % [recipe_id, order_index])


func _find_best_task_index() -> int:
	"""
	Find the best task to assign next, prioritizing:
	1. Recipes that other bots are already working on (helps finish recipes faster)
	2. Recipes with fewer ingredients remaining
	3. Older recipes (lower order_index)
	"""
	if _order_queue.is_empty():
		return -1
	
	# Count remaining ingredients per recipe
	var recipe_remaining: Dictionary = {}
	for task in _order_queue:
		var recipe_id = task["recipe_id"]
		if not recipe_remaining.has(recipe_id):
			recipe_remaining[recipe_id] = 0
		recipe_remaining[recipe_id] += 1
	
	# Count how many bots are working on each recipe
	var recipe_bot_counts: Dictionary = {}
	for recipe_id in _bot_recipes.values():
		if not recipe_bot_counts.has(recipe_id):
			recipe_bot_counts[recipe_id] = 0
		recipe_bot_counts[recipe_id] += 1
	
	# Find task with best priority score
	var best_idx = 0
	var best_score = _calculate_priority_score(_order_queue[0], recipe_remaining, recipe_bot_counts)
	
	for i in range(1, _order_queue.size()):
		var score = _calculate_priority_score(_order_queue[i], recipe_remaining, recipe_bot_counts)
		if score < best_score:  # Lower score = higher priority
			best_score = score
			best_idx = i
	
	return best_idx


func _calculate_priority_score(task: Dictionary, recipe_remaining: Dictionary, recipe_bot_counts: Dictionary) -> float:
	"""
	Calculate priority score for a task. Lower = higher priority.
	
	Scoring system:
	- HUGE bonus if other bots are already working on this recipe (teamwork!)
	- Base score: number of ingredients remaining in this recipe
	- Small penalty for newer orders
	"""
	var recipe_id = task["recipe_id"]
	var order_idx = task.get("order_index", 0)
	
	# Base priority: fewer remaining ingredients = higher priority
	var score = float(recipe_remaining.get(recipe_id, 999))
	
	# CRITICAL: If other bots are working on this recipe, give it MASSIVE priority
	# This ensures recipes get completed quickly with teamwork
	var bots_on_recipe = recipe_bot_counts.get(recipe_id, 0)
	if bots_on_recipe > 0:
		score -= 10000.0 * bots_on_recipe  # More bots = even higher priority
		print("[GM] 🔥 Recipe '%s' has %d bots working - HIGH PRIORITY!" % [recipe_id, bots_on_recipe])
	
	# Small penalty for newer orders (favor completing older ones first)
	score += order_idx * 0.1
	
	return score


# ==================== RECIPE QUERIES ====================
func get_recipe_ingredients(recipe_id: String) -> Array:
	if recipes.has(recipe_id):
		return recipes[recipe_id].get("base_items", [])
	return []


func get_recipe_flow(recipe_id: String) -> Array:
	if recipes.has(recipe_id):
		return recipes[recipe_id].get("flow", ["Ingredient", "Chopping", "Serving"])
	return ["Ingredient", "Chopping", "Serving"]


func get_flow_for_item(recipe_id: String, item_id: String) -> Array:
	var default_flow = get_recipe_flow(recipe_id)
	
	if recipes.has(recipe_id):
		var recipe = recipes[recipe_id]
		if recipe.has("per_item_flow"):
			var overrides = recipe["per_item_flow"]
			if overrides.has(item_id):
				return overrides[item_id]
	
	return default_flow


func get_ingredient_name(item_id: String) -> String:
	if ingredients.has(item_id):
		return ingredients[item_id].get("name", item_id)
	return item_id


func get_ingredient_status(item_id: String) -> String:
	if ingredients.has(item_id):
		var status = ingredients[item_id].get("status", "raw")
		return str(status) if status != null else "raw"
	return "raw"


# ==================== RECIPE TRACKING ====================
func notify_served(ingredient_id: String) -> void:
	_served_count += 1
	print("[GM] ✅ Served: %s (%d/%d)" %
		[ingredient_id, _served_count, _total_needed])
	
	if not endless_mode and _served_count >= _total_needed and _total_needed > 0:
		print("[GM] 🎉 ALL ORDERS COMPLETED!")
		print_scores()


func print_scores() -> void:
	print("\n========== FINAL SCORES ==========")
	for completion in completed_recipes:
		var recipe_name = recipes[completion["recipe_id"]]["name"]
		print("  %s: %.2f seconds" % [recipe_name, completion["score"]])
	print("==================================\n")


func get_recipe_score(recipe_id: String) -> float:
	for completion in completed_recipes:
		if completion["recipe_id"] == recipe_id:
			return completion["score"]
	return -1.0


func get_all_scores() -> Array:
	return completed_recipes.duplicate()


# ==================== INGREDIENT SPAWNING ====================
func spawn_ingredient(type: String = "", parent_node: Node = null) -> Node:
	if not ingredient_scene:
		push_error("[GM] ingredient_scene not assigned in Inspector!")
		return null
	
	var instance = ingredient_scene.instantiate()
	
	if type != "" and instance.has_method("set_type"):
		instance.set_type(type)
	elif type != "":
		if "type" in instance:
			instance.type = type
	
	instance.name = "Ingredient_%d" % _spawn_idx
	_spawn_idx += 1
	
	var parent = parent_node if parent_node else get_parent()
	parent.add_child(instance)
	
	return instance


func _process(delta):
	_current_time += delta
	var elapsed_time = "TOTAL TIME: %.2fs\n" % _current_time
	
	if active_recipe_timers.size() > 0:
		var display_text = "Active Orders:\n"
		for timer_key in active_recipe_timers.keys():
			var elapsed = _current_time - active_recipe_timers[timer_key]
			# Extract recipe_id from timer_key (format: "recipe_id_N")
			var parts = timer_key.split("_")
			var recipe_id = "_".join(parts.slice(0, parts.size() - 1))
			var recipe_name = recipes[recipe_id]["name"] if recipes.has(recipe_id) else recipe_id
			display_text += "%s: %.1fs  " % [recipe_name, elapsed]
		
		if endless_mode:
			display_text += "\nCompleted: %d | Pending: %d | In Progress: %d" % [_orders_completed, _pending_orders, _in_progress_orders]
		
		time_label.text = elapsed_time + display_text
	else:
		if endless_mode:
			time_label.text = elapsed_time + "Waiting for orders...\nCompleted: %d" % _orders_completed
		else:
			time_label.text = elapsed_time + "Waiting for orders..."
	
	if not endless_mode and completed_recipes.size() == orders.size() and orders.size() > 0:
		var scores_text = "ALL COMPLETED!\n\nScores:\n"
		for completion in completed_recipes:
			var recipe_name = recipes[completion["recipe_id"]]["name"]
			scores_text += "%s: %.2fs\n" % [recipe_name, completion["score"]]
		time_label.text = elapsed_time + scores_text
	
	# Stats tracking
	if int(_current_time) % 30 == 0 and int(_current_time) > 0:
		_log_stats()


func _log_stats():
	var total_bots = get_tree().get_nodes_in_group("bots").size()
	var idle_bots = 0
	for bot in get_tree().get_nodes_in_group("bots"):
		if "current_action" in bot and bot.current_action == 0:
			idle_bots += 1
	
	print("[GM] 📈 STATS @ %.0fs: Completed: %d | Active: %d | Queue: %d | Bots: %d/%d active" % 
		[_current_time, _orders_completed, active_recipe_timers.size(), _order_queue.size(), total_bots - idle_bots, total_bots])
	stats()
		
func moyenne():
	summoy = 0.0
	for i in range(moyennetemps.size()): 
		summoy += moyennetemps[i]
		print(summoy)
		
func stats(): 
	moyenne()
	if(_current_time >= 120.0):
		print("MOYENNE IN 120 SECONDS (2 mins): ", float(summoy) / moyennetemps.size())
		print("IN 120 SECONDS (2mins) WE MADE THIS AMOUNT OF RECIPES :  " , _orders_completed)

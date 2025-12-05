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


func _ready() -> void:
	add_to_group("game_manager")
	_register_stations()
	_setup_recipes()
	_setup_orders()
	_rebuild_order_queue()
	print("[GM] Ready | Orders: %d | Total ingredients: %d" % [orders.size(), _total_needed])


# ==================== TIMER MANAGEMENT ====================
func _start_recipe_timer(recipe_id: String) -> void:
	if not active_recipe_timers.has(recipe_id):
		active_recipe_timers[recipe_id] = _current_time
		print("[GM] ⏱️ Timer started for recipe '%s' at %.2fs" % [recipe_id, _current_time])

func _complete_recipe_timer(recipe_id: String) -> float:
	if not active_recipe_timers.has(recipe_id):
		push_warning("[GM] No timer found for recipe '%s'" % recipe_id)
		return 0.0
	
	var start_time = active_recipe_timers[recipe_id]
	var completion_time = _current_time - start_time
	
	completed_recipes.append({
		"recipe_id": recipe_id,
		"score": completion_time,
		"completed_at": _current_time
	})
	
	active_recipe_timers.erase(recipe_id)
	_orders_completed += 1
	_in_progress_orders -= 1
	
	print("[GM] ✅ Recipe '%s' completed in %.2f seconds! (Total completed: %d)" % 
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


# ==================== NEW: SERVING STATION LOOKUP ====================
func find_serving_station_for_recipe(recipe_id: String) -> Node:
	"""Find the correct serving station for a specific recipe"""
	if not stations_by_type.has("Serving"):
		push_error("[GM] No serving stations registered!")
		return null
	
	var serving_stations: Array = stations_by_type["Serving"]
	
	# First, try to find a dedicated station for this recipe
	for station in serving_stations:
		if "recipe_id" in station and station.recipe_id == recipe_id:
			print("[GM] 🎯 Found dedicated serving station '%s' for recipe '%s'" % [station.name, recipe_id])
			return station
	
	# Fallback: find a station that accepts all recipes (empty recipe_id)
	for station in serving_stations:
		if "recipe_id" in station and station.recipe_id == "":
			print("[GM] 🎯 Using universal serving station '%s' for recipe '%s'" % [station.name, recipe_id])
			return station
	
	# If no match found, this is an error - don't use wrong station
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

	print("[GM] Orders prepared: %d orders, %d ingredients queued" %
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
	if endless_mode:
		var active_orders = _pending_orders + _in_progress_orders
		if active_orders < min_active_orders:
			print("[GM] 🔄 Queue low, spawning additional order (active: %d)" % active_orders)
			_spawn_new_order()
	
	if _order_queue.is_empty():
		print("[GM] No more ingredients available for bot %d" % bot_id)
		return {}
	
	var task: Dictionary = _order_queue.pop_front()
	var recipe_id: String = task.get("recipe_id", "")
	var ingredient_id: String = task.get("ingredient_id", "")
	var order_index: int = task.get("order_index", -1)
	
	if order_index >= 0 and orders[order_index]["status"] == "pending":
		orders[order_index]["status"] = "in_progress"
		orders[order_index]["start_time"] = _current_time
		_start_recipe_timer(recipe_id)
		_pending_orders -= 1
		_in_progress_orders += 1
	
	print("[GM] Assigned '%s' (%s) to bot %d (%d remaining | %d pending | %d in progress)" %
		[ingredient_id, recipe_id, bot_id, _order_queue.size(), _pending_orders, _in_progress_orders])
	return task


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
	
	var parent = parent_node if parent_node else get_parent()
	parent.add_child(instance)
	
	if type != "" and instance.has_method("set_type"):
		instance.set_type(type)
	
	instance.name = "Ingredient_%d" % _spawn_idx
	_spawn_idx += 1
	
	return instance


func _process(delta):
	_current_time += delta
	var elapsed_time = "TOTAL TIME: %.2fs\n" % _current_time
	
	if active_recipe_timers.size() > 0:
		var display_text = "🳠Active Orders:\n"
		for recipe_id in active_recipe_timers.keys():
			var elapsed = _current_time - active_recipe_timers[recipe_id]
			var recipe_name = recipes[recipe_id]["name"]
			display_text += "%s: %.1fs  " % [recipe_name, elapsed]
		
		if endless_mode:
			display_text += "\n📊 Completed: %d | Pending: %d" % [_orders_completed, _pending_orders]
		
		time_label.text = elapsed_time + display_text
	else:
		if endless_mode:
			time_label.text = elapsed_time + "⏳ Waiting for orders...\n📊 Completed: %d" % _orders_completed
		else:
			time_label.text = elapsed_time + "⏳ Waiting for orders..."
	
	if not endless_mode and completed_recipes.size() == orders.size() and orders.size() > 0:
		var scores_text = "🎉 ALL COMPLETED!\n\nScores:\n"
		for completion in completed_recipes:
			var recipe_name = recipes[completion["recipe_id"]]["name"]
			scores_text += "%s: %.2fs\n" % [recipe_name, completion["score"]]
		time_label.text = elapsed_time + scores_text
	
	stats()

func stats(): 
	if _current_time >= 120.0:
		print("IN 120 SECONDS (2mins) WE MADE %d recipes" % completed_recipes.size())

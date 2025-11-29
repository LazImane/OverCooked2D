extends Node
# GameManager: Manages recipes, ingredients, and bot task assignment

@export var ingredient_scene: PackedScene = null
@export var time_label: Label 
@export var endless_mode: bool = true  # Toggle endless order mode
@export var order_delay: float = 2.0  # Delay before spawning next order in endless mode

var recipes: Dictionary = {}
var ingredients: Dictionary = {}
var stations_by_type: Dictionary = {}

# List of orders. Each order:
# { "recipe_id": String, "base_items": Array[String], "start_time": float, "completion_time": float, "status": String }
var orders: Array = []

# Recipe tracking per order
var active_recipe_timers: Dictionary = {}  # { recipe_id: start_time }
var completed_recipes: Array = []  # [{ recipe_id, completion_time, score }]

# Global execution tracking (for ALL orders)
var current_recipe_id: String = "demo_salad"  # just a default label
var _order_queue: Array = []  # Each element: { "recipe_id": String, "ingredient_id": String, "order_index": int }
var _total_needed: int = 0
var _served_count: int = 0
var _spawn_idx: int = 0
var _current_time: float = 0.0
var _orders_completed: int = 0  # Track total orders completed in endless mode


func _ready() -> void:
	add_to_group("game_manager")
	_register_stations()
	_setup_recipes()
	_setup_orders()          # create initial list of orders
	_rebuild_order_queue()   # build _order_queue from orders
	print("[GM] Ready | Orders: %d | Total ingredients: %d" % [orders.size(), _total_needed])


# ==================== TIMER MANAGEMENT ====================
func _start_recipe_timer(recipe_id: String) -> void:
	"""Start timer for a specific recipe"""
	if not active_recipe_timers.has(recipe_id):
		active_recipe_timers[recipe_id] = _current_time
		print("[GM] ⏱️ Timer started for recipe '%s' at %.2fs" % [recipe_id, _current_time])

func _complete_recipe_timer(recipe_id: String) -> float:
	"""Stop timer for a recipe and return the completion time"""
	if not active_recipe_timers.has(recipe_id):
		push_warning("[GM] No timer found for recipe '%s'" % recipe_id)
		return 0.0
	
	var start_time = active_recipe_timers[recipe_id]
	var completion_time = _current_time - start_time
	
	# Record the completion
	completed_recipes.append({
		"recipe_id": recipe_id,
		"score": completion_time,
		"completed_at": _current_time
	})
	
	active_recipe_timers.erase(recipe_id)
	_orders_completed += 1
	print("[GM] ✅ Recipe '%s' completed in %.2f seconds! (Total completed: %d)" % 
		[recipe_id, completion_time, _orders_completed])
	
	# In endless mode, spawn a new order after delay
	if endless_mode:
		await get_tree().create_timer(order_delay).timeout
		_spawn_new_order()
	
	return completion_time


func _spawn_new_order() -> void:
	"""Spawn a new random order (endless mode)"""
	if not endless_mode:
		return
	
	print("[GM] 📋 Spawning new order...")
	var old_size = orders.size()
	_add_random_order()
	_rebuild_order_queue_incremental(old_size)
	print("[GM] 📋 New order added! Active orders: %d" % orders.size())


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


# ==================== RECIPE SETUP ====================
func _setup_recipes() -> void:
	# Define base ingredients
	ingredients = {
		"lettuce": {"id": "lettuce", "name": "Lettuce", "status": "raw"},
		"tomato": {"id": "tomato", "name": "Tomato", "status": "raw"},
		"cucumber": {"id": "cucumber", "name": "Cucumber", "status": "raw"},
		"olive": {"id": "olive", "name": "Olive", "status": "raw"},
		"carrot": {"id": "carrot", "name": "Carrot", "status": "raw"},
		"potato": {"id": "potato", "name": "Potato", "status": "raw"},
		"onion": {"id": "onion", "name": "Onion", "status": "raw"},
		"cheese": {"id": "cheese", "name": "Cheese", "status": "raw"}
	}
	
	# Define recipes with per-item flow overrides
	recipes = {
		"demo_salad": {
			"name": "Greek Salad",
			"base_items": ["lettuce", "tomato", "cucumber", "olive"],
			"flow": ["Ingredient", "Chopping", "Serving"],  # Default flow
			"per_item_flow": {
				# olives need cooking after chopping
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
	"""
	Initialize the orders list.
	In endless mode: starts with 2 orders, more spawn automatically
	In normal mode: fixed set of orders
	"""
	orders.clear()

	if endless_mode:
		# Start with 2 random orders in endless mode
		_add_random_order()
		_add_random_order()
	else:
		# Fixed orders for normal mode
		_add_order("demo_salad")
		_add_order("tomato_soup")
		_add_order("veggie_stir_fry")
		_add_order("caesar_salad")
		_add_order("potato_soup")

	# Optional: label for logs, first order's recipe
	if orders.size() > 0:
		current_recipe_id = orders[0]["recipe_id"]


func _add_random_order() -> void:
	"""Add a random recipe order"""
	var recipe_keys = recipes.keys()
	var random_recipe = recipe_keys[randi() % recipe_keys.size()]
	_add_order(random_recipe)


func _add_order(recipe_id: String) -> void:
	"""
	Adds a new order to the orders list.
	"""
	if not recipes.has(recipe_id):
		push_error("[GM] Cannot add order: unknown recipe_id '%s'" % recipe_id)
		return

	var base_items: Array = recipes[recipe_id].get("base_items", [])
	var order := {
		"recipe_id": recipe_id,
		"base_items": base_items.duplicate(),
		"status": "pending",  # pending, in_progress, completed
		"start_time": 0.0,
		"completion_time": 0.0
	}
	orders.append(order)
	print("[GM] Added order for recipe '%s' with %d items" % [recipe_id, base_items.size()])


func _rebuild_order_queue() -> void:
	"""
	Rebuild the global ingredient queue (_order_queue) from all orders.
	All bots will consume from this flattened list of {recipe_id, ingredient_id, order_index}.
	"""
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
	"""Add new orders to the queue without clearing existing ones"""
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


# Optional helper if you want a single recipe again
func _prepare_recipe_order(recipe_id: String) -> void:
	orders.clear()
	_add_order(recipe_id)
	_rebuild_order_queue()
	current_recipe_id = recipe_id


# ==================== BOT TASK ASSIGNMENT ====================
func request_next_ingredient(bot_id: int) -> Dictionary:
	"""
	Called by bots when they need a new ingredient to process.
	Returns:
	  { "recipe_id": String, "ingredient_id": String, "order_index": int }
	or {} if no tasks remain.
	"""
	if _order_queue.is_empty():
		print("[GM] No more ingredients available for bot %d" % bot_id)
		return {}
	
	var task: Dictionary = _order_queue.pop_front()
	var recipe_id: String = task.get("recipe_id", "")
	var ingredient_id: String = task.get("ingredient_id", "")
	var order_index: int = task.get("order_index", -1)
	
	# Start timer for this recipe if it's the first ingredient
	if order_index >= 0 and orders[order_index]["status"] == "pending":
		orders[order_index]["status"] = "in_progress"
		orders[order_index]["start_time"] = _current_time
		_start_recipe_timer(recipe_id)
	
	print("[GM] Assigned '%s' (%s) to bot %d (%d remaining in global queue)" %
		[ingredient_id, recipe_id, bot_id, _order_queue.size()])
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
	"""
	Returns processing flow for a specific ingredient (may override default).
	Uses per_item_flow if defined, else default recipe flow.
	"""
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
	"""Called when an ingredient is successfully served"""
	_served_count += 1
	print("[GM] ✅ Served: %s (%d/%d)" %
		[ingredient_id, _served_count, _total_needed])
	
	if _served_count >= _total_needed and _total_needed > 0:
		print("[GM] 🎉 ALL ORDERS COMPLETED!")
		print_scores()


func print_scores() -> void:
	"""Print all recipe completion times/scores"""
	print("\n========== FINAL SCORES ==========")
	for completion in completed_recipes:
		var recipe_name = recipes[completion["recipe_id"]]["name"]
		print("  %s: %.2f seconds" % [recipe_name, completion["score"]])
	print("==================================\n")


func get_recipe_score(recipe_id: String) -> float:
	"""Get the completion time for a specific recipe"""
	for completion in completed_recipes:
		if completion["recipe_id"] == recipe_id:
			return completion["score"]
	return -1.0  # Not completed yet


func get_all_scores() -> Array:
	"""Get all completed recipe scores"""
	return completed_recipes.duplicate()


# ==================== INGREDIENT SPAWNING ====================
func spawn_ingredient(type: String = "", parent_node: Node = null) -> Node:
	"""Spawns an ingredient node (used by stations)"""
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
	# Always update global time
	_current_time += delta
	
	# Update display with current active timers
	if active_recipe_timers.size() > 0:
		var display_text = "🍳 Active Orders:\n"
		for recipe_id in active_recipe_timers.keys():
			var elapsed = _current_time - active_recipe_timers[recipe_id]
			var recipe_name = recipes[recipe_id]["name"]
			display_text += "%s: %.1fs  " % [recipe_name, elapsed]
		
		if endless_mode:
			display_text += "\n📊 Completed: %d" % _orders_completed
		
		time_label.text = display_text
	else:
		if endless_mode:
			time_label.text = "⏳ Waiting for orders...\n📊 Completed: %d" % _orders_completed
		else:
			time_label.text = "⏳ Waiting for orders..."
	
	# Show completed scores if all done (only in non-endless mode)
	if not endless_mode and completed_recipes.size() == orders.size() and orders.size() > 0:
		var scores_text = "🎉 ALL COMPLETED!\n\nScores:\n"
		for completion in completed_recipes:
			var recipe_name = recipes[completion["recipe_id"]]["name"]
			scores_text += "%s: %.2fs\n" % [recipe_name, completion["score"]]
		time_label.text = scores_text

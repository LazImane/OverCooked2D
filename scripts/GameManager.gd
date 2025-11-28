extends Node
# GameManager: Manages recipes, ingredients, and bot task assignment

@export var ingredient_scene: PackedScene = null
@export var time_label: Label 

var recipes: Dictionary = {}
var ingredients: Dictionary = {}
var stations_by_type: Dictionary = {}
var elapsed_time = 0 

# List of orders. Each order:
# { "recipe_id": String, "base_items": Array[String] }
var orders: Array = []

# Global execution tracking (for ALL orders)
var current_recipe_id: String = "demo_salad"  # just a default label
var _order_queue: Array = []  # Each element: { "recipe_id": String, "ingredient_id": String }
var _total_needed: int = 0
var _served_count: int = 0
var _spawn_idx: int = 0


func _ready() -> void:
	add_to_group("game_manager")
	_register_stations()
	_setup_recipes()
	_setup_orders()          # create initial list of orders
	_rebuild_order_queue()   # build _order_queue from orders
	print("[GM] Ready | Orders: %d | Total ingredients: %d" % [orders.size(), _total_needed])


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
		"olive": {"id": "olive", "name": "Olive", "status": "raw"}
	}
	
	# Define recipes with per-item flow overrides
	recipes = {
		"demo_salad": {
			"name": "Greek Salad",
			"base_items": ["lettuce", "tomato", "cucumber", "olive"],
			"flow": ["Ingredient", "Chopping", "Serving"],  # Default flow
			"per_item_flow": {
				# Example: olives need cooking after chopping
				"olive": ["Ingredient", "Chopping", "Cooking", "Serving"]
			}
		},
		"tomato_soup": {
			"name": "Tomato Soup",
			"base_items": ["tomato","tomato"],
			"flow": ["Ingredient", "Chopping", "Cooking", "Serving"]
		}
	}


# ==================== ORDER LIST SETUP ====================
func _setup_orders() -> void:
	"""
	Initialize the orders list.
	For testing: start with 2 orders:
	  - 1x demo_salad
	  - 1x tomato_soup
	"""
	orders.clear()

	_add_order("demo_salad")
	_add_order("tomato_soup")

	# Optional: label for logs, first order's recipe
	if orders.size() > 0:
		current_recipe_id = orders[0]["recipe_id"]


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
		"base_items": base_items.duplicate()
	}
	orders.append(order)
	print("[GM] Added order for recipe '%s' with %d items" % [recipe_id, base_items.size()])


func _rebuild_order_queue() -> void:
	"""
	Rebuild the global ingredient queue (_order_queue) from all orders.
	All bots will consume from this flattened list of {recipe_id, ingredient_id}.
	"""
	_order_queue.clear()
	_served_count = 0
	_total_needed = 0

	for order in orders:
		var recipe_id: String = order.get("recipe_id", "")
		var base_items: Array = order.get("base_items", [])
		for base in base_items:
			var item_id := str(base)
			_order_queue.append({
				"recipe_id": recipe_id,
				"ingredient_id": item_id
			})
			_total_needed += 1

	print("[GM] Orders prepared: %d orders, %d ingredients queued" %
		[orders.size(), _total_needed])


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
	  { "recipe_id": String, "ingredient_id": String }
	or {} if no tasks remain.
	"""
	if _order_queue.is_empty():
		print("[GM] No more ingredients available for bot %d" % bot_id)
		return {}
	
	var task: Dictionary = _order_queue.pop_front()
	var recipe_id: String = task.get("recipe_id", "")
	var ingredient_id: String = task.get("ingredient_id", "")
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
		print("[GM] 🎉 ALL ORDERS COMPLETED! (total ingredients: %d)" % _total_needed)
		# trigger victory screen here if you want


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
	elapsed_time += delta
	time_label.text = " time elapsed : " + str(int(elapsed_time))

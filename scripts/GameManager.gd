extends Node
# GameManager: Manages recipes, ingredients, and bot task assignment

@export var ingredient_scene: PackedScene = null

var recipes: Dictionary = {}
var ingredients: Dictionary = {}
var stations_by_type: Dictionary = {}

# Recipe execution tracking
var current_recipe_id: String = "demo_salad"
var _order_bases: Array = []  # Queue of ingredients to assign
var _total_needed: int = 0
var _served_count: int = 0
var _spawn_idx: int = 0

func _ready() -> void:
	add_to_group("game_manager")
	_register_stations()
	_setup_recipes()
	_prepare_recipe_order(current_recipe_id)
	print("[GM] Ready | Recipe: %s | Total ingredients: %d" % [current_recipe_id, _total_needed])

# ==================== STATION REGISTRATION ====================
func _register_stations() -> void:
	stations_by_type.clear()
	for station in get_tree().get_nodes_in_group("stations"):
		if not "station_type" in station:
			continue
		var type: String = station.station_type
		if type == "":
			continue
		if not stations_by_type.has(type):
			stations_by_type[type] = []
		stations_by_type[type].append(station)
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
				"olive": ["Ingredient", "Chopping", "Cooking", "Serving"]  # Olives need cooking
			}
		},
		"tomato_soup": {
			"name": "Tomato Soup",
			"base_items": ["tomato"],
			"flow": ["Ingredient", "Chopping", "Cooking", "Serving"]
		}
	}

func _prepare_recipe_order(recipe_id: String) -> void:
	_order_bases.clear()
	_served_count = 0
	if recipes.has(recipe_id):
		_order_bases = recipes[recipe_id].get("base_items", []).duplicate()
	_total_needed = _order_bases.size()
	print("[GM] Recipe prepared: %d ingredients queued" % _total_needed)

# ==================== BOT TASK ASSIGNMENT ====================
func request_next_ingredient(bot_id: int) -> String:
	"""Called by bots when they need a new ingredient to process"""
	if _order_bases.is_empty():
		print("[GM] No more ingredients available for bot %d" % bot_id)
		return ""
	
	var ingredient_id = _order_bases.pop_front()
	var ingredient_str = str(ingredient_id) if ingredient_id != null else ""
	print("[GM] Assigned '%s' to bot %d (%d remaining)" % [ingredient_str, bot_id, _order_bases.size()])
	return ingredient_str

# ==================== RECIPE QUERIES ====================
func get_recipe_ingredients(recipe_id: String) -> Array:
	"""Returns all ingredients needed for a recipe"""
	if recipes.has(recipe_id):
		return recipes[recipe_id].get("base_items", [])
	return []

func get_recipe_flow(recipe_id: String) -> Array:
	"""Returns the default processing flow for a recipe"""
	if recipes.has(recipe_id):
		return recipes[recipe_id].get("flow", ["Ingredient", "Chopping", "Serving"])
	return ["Ingredient", "Chopping", "Serving"]

func get_flow_for_item(recipe_id: String, item_id: String) -> Array:
	"""Returns processing flow for a specific ingredient (may override default)"""
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
	print("[GM] ✅ Served: %s (%d/%d)" % [ingredient_id, _served_count, _total_needed])
	
	if _served_count >= _total_needed and _total_needed > 0:
		print("[GM] 🎉 Recipe '%s' COMPLETED!" % current_recipe_id)
		# You could trigger victory screen here

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

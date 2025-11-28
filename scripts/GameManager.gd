extends Node

var station_order: Array = ["Ingredient", "Chopping", "Cooking", "Serving"]
var ingredients: Dictionary = {}
var recipes: Dictionary = {}
var stations_by_type: Dictionary = {}
var current_recipe_id: String = "demo_salad"
var _spawn_idx: int = 0

# === TASK QUEUE SYSTEM ===
var task_queue: Array = []  # Array of task dictionaries
var active_tasks: Dictionary = {}  # bot_id -> task
var completed_items: Array = []  # Track what's been served

# Task structure:_è
# {
#   "item": "lettuce",
#   "flow": ["Chopping", "Serving"],
#   "current_step": 0,
#   "status": "pending",  # pending, assigned, in_progress, completed
#   "assigned_to": -1
# }

func _ready() -> void:
	add_to_group("game_manager")
	_register_stations()
	_setup_demo_data()
	_build_task_queue(current_recipe_id)

func _register_stations() -> void:
	stations_by_type.clear()
	for s in get_tree().get_nodes_in_group("stations"):
		var t: String = s.station_type
		if t == "":
			continue
		if not stations_by_type.has(t):
			stations_by_type[t] = []
		stations_by_type[t].append(s)
	print("Registered stations:", stations_by_type.keys())

func _setup_demo_data() -> void:
	ingredients.clear()
	recipes.clear()

	ingredients["lettuce"]  = {"id":"lettuce",  "name":"lettuce",  "status":"raw"}
	ingredients["tomato"]   = {"id":"tomato",   "name":"tomato",   "status":"raw"}
	ingredients["cucumber"] = {"id":"cucumber", "name":"cucumber", "status":"raw"}
	ingredients["olive"]    = {"id":"olive",    "name":"olive",    "status":"raw"}

	recipes = {
		"demo_salad": {
			"base_items": ["lettuce","tomato","cucumber","olive"],
			"flow": ["Chopping","Serving"],  # default flow
			"per_item_flow": {
				"olive": ["Chopping","Cooking","Serving"]  # olives need cooking
			}
		}
	}

# === BUILD TASK QUEUE ===
func _build_task_queue(recipe_name: String) -> void:
	task_queue.clear()
	
	if not recipes.has(recipe_name):
		print("Recipe not found:", recipe_name)
		return
	
	var items: Array = recipes[recipe_name].get("base_items", [])
	
	for item in items:
		var flow := get_flow_for_item(recipe_name, String(item))
		var task := {
			"item": String(item),
			"flow": flow,
			"current_step": 0,
			"status": "pending",
			"assigned_to": -1
		}
		task_queue.append(task)
	
	print("Task queue built:", task_queue.size(), "items")

# === BOT TASK ASSIGNMENT ===
func request_task(bot_id: int) -> Dictionary:
	"""Bot requests a new task from the manager"""
	
	# If bot already has an active task, return it
	if active_tasks.has(bot_id):
		return active_tasks[bot_id]
	
	# Find next pending task
	for task in task_queue:
		if task["status"] == "pending":
			task["status"] = "assigned"
			task["assigned_to"] = bot_id
			active_tasks[bot_id] = task
			print("[GM] Assigned task to bot", bot_id, ":", task["item"])
			return task
	
	# No tasks available
	return {}

func complete_task(bot_id: int) -> void:
	"""Bot reports task completion"""
	if active_tasks.has(bot_id):
		var task: Dictionary = active_tasks[bot_id]
		task["status"] = "completed"
		completed_items.append(task["item"])
		active_tasks.erase(bot_id)
		print("[GM] Bot", bot_id, "completed:", task["item"], "| Remaining:", get_pending_task_count())

func get_pending_task_count() -> int:
	var count := 0
	for task in task_queue:
		if task["status"] != "completed":
			count += 1
	return count

func get_next_step_for_task(task: Dictionary) -> String:
	"""Get the next station type needed for this task"""
	if task.is_empty():
		return ""
	
	var step_idx: int = task.get("current_step", 0)
	var flow: Array = task.get("flow", [])
	
	if step_idx < flow.size():
		return String(flow[step_idx])
	
	return ""  # Task complete

func advance_task_step(bot_id: int) -> void:
	"""Bot finished current step, move to next"""
	if active_tasks.has(bot_id):
		active_tasks[bot_id]["current_step"] += 1

func get_station_for_type(station_type: String) -> Node:
	"""Get a station of the requested type (could be enhanced for load balancing)"""
	var stations: Array = stations_by_type.get(station_type, [])
	if stations.is_empty():
		return null
	
	# Simple: return first station (could add load balancing here)
	return stations[0]

# === EXISTING FUNCTIONS (kept for compatibility) ===
func get_recipe_flow(recipe_name: String) -> Array:
	if recipes.has(recipe_name):
		return recipes[recipe_name].get("flow", ["Chopping", "Cooking", "Serving"])
	return ["Chopping", "Cooking", "Serving"]

func get_flow_for_item(recipe_name: String, item: String) -> Array:
	var base := get_recipe_flow(recipe_name)
	if recipes.has(recipe_name) and recipes[recipe_name].has("per_item_flow"):
		var m: Dictionary = recipes[recipe_name]["per_item_flow"]
		if m.has(item):
			return m[item]
	return base

func get_recipe_ingredients(recipe_name: String) -> Array:
	if recipes.has(recipe_name):
		return recipes[recipe_name].get("base_items", [])
	return []

func process_recipe(recipe_name: String) -> void:
	"""Legacy function - kept for reference but task system is preferred"""
	if not recipes.has(recipe_name):
		print("Recipe not found:", recipe_name)
		return

	var rec: Dictionary = recipes[recipe_name]
	var flow: Array = rec.get("flow", [])
	var ing_list: Array = rec.get("base_items", [])

	print("Processing recipe:", recipe_name, "flow:", flow, "base_items:", ing_list)

func get_ingredient_status(ing_id: String) -> String:
	if ingredients.has(ing_id):
		return String(ingredients[ing_id].get("status", ""))
	return ""

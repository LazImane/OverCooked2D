extends Node

var station_order: Array = ["Ingredient", "Chopping", "Cooking", "Serving"]
var ingredients: Dictionary = {}
var recipes: Dictionary = {}
var stations_by_type: Dictionary = {}
var current_recipe_id: String = "demo_salad"
var _spawn_idx: int = 0

@export var ingredient_scene: PackedScene = null

func _ready() -> void:
	add_to_group("game_manager")
	_setup_demo_data()  # Setup data BEFORE registering stations
	_register_stations()
	process_recipe("demo_salad")

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

	# FIX 1: Add all ingredients used in recipes
	ingredients["lettuce"]  = {"id":"lettuce",  "name":"lettuce",  "status":"raw"}
	ingredients["tomato"]   = {"id":"tomato",   "name":"tomato",   "status":"raw"}
	ingredients["cucumber"] = {"id":"cucumber", "name":"cucumber", "status":"raw"}
	ingredients["olives"]    = {"id":"olives",    "name":"olives",    "status":"raw"}

	# FIX 2: Add "Ingredient" as first step in flow so bot can pick up items
	recipes = {
		"demo_salad": {
			"base_items": ["lettuce","tomato","cucumber","olives"],
			"flow": ["Ingredient", "Chopping", "Serving"],  # Added "Ingredient" first
			"per_item_flow": {
				"olives": ["Ingredient", "Chopping", "Cooking", "Serving"]  # olives require cooking
			}
		}
	}

func get_recipe_flow(recipe_name: String) -> Array:
	if recipes.has(recipe_name):
		return recipes[recipe_name].get("flow", ["Ingredient", "Chopping", "Serving"])
	return ["Ingredient", "Chopping", "Serving"]

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

func next_base_item() -> String:
	var rid := current_recipe_id if current_recipe_id != "" else "demo_salad"
	if not recipes.has(rid):
		return ""
	var items: Array = recipes[rid].get("base_items", [])
	if items.is_empty():
		return ""
	var id := String(items[_spawn_idx % items.size()])
	_spawn_idx += 1
	return id

func process_recipe(recipe_name: String) -> void:
	if not recipes.has(recipe_name):
		print("Recipe not found:", recipe_name)
		return

	var rec: Dictionary = recipes[recipe_name]
	var flow: Array = rec.get("flow", [])
	var ing_list: Array = rec.get("base_items", [])

	print("Processing recipe:", recipe_name, "flow:", flow, "base_items:", ing_list)

	for ing_id in ing_list:
		if not ingredients.has(ing_id):
			print("Unknown ingredient:", ing_id)
			continue

		var item: Dictionary = ingredients[ing_id]
		print("\n=== Start item:", ing_id, "status:", item.get("status", ""))

		for stype in flow:
			if stype == "Ingredient":
				continue  # Skip ingredient station in processing (it's just for picking up)
			
			var station_list: Array = stations_by_type.get(stype, [])
			if station_list.is_empty():
				print("Warning: no station of type", stype, "found. Skipping.")
				continue

			var station: Node = station_list[0]
			print("-> Sending", ing_id, "to", stype, "station:", station.name)

			var new_status := ""
			if station.has_method("process_item"):
				new_status = station.process_item(item)
			else:
				new_status = _generic_transform(stype, item.get("status", "raw"))

			if typeof(new_status) == TYPE_STRING and new_status != "":
				item["status"] = new_status

			print("   status now:", item.get("status", ""))

		print("Final status for", ing_id, "=", item.get("status", ""))

func _generic_transform(station_type: String, status: String) -> String:
	match station_type:
		"Ingredient":
			return "raw"
		"Chopping":
			if status == "raw":
				return "chopped"
		"Cooking":
			if status == "chopped":
				return "cooked"
		"Serving":
			if status in ["chopped", "cooked", "raw"]:
				return "served"
	return status

func get_ingredient_status(ing_id: String) -> String:
	if ingredients.has(ing_id):
		return String(ingredients[ing_id].get("status", ""))
	print("Ingredient:", ing_id, "does not exist")
	return ""

var count := 0 
func spawn_ingredient(type: String = "", parent_opt: Node = null) -> Node:
	var game_root: Node = parent_opt if parent_opt != null else get_parent()
	if ingredient_scene == null:
		push_error("spawn_ingredient: ingredient_scene not assigned in the inspector.")
		return null

	var inst: Node = ingredient_scene.instantiate()
	game_root.add_child(inst)

	if type != "" and inst.has_method("set_type"):
		inst.set_type(type)
	elif inst.has_method("spawn_from_recipe"):
		inst.spawn_from_recipe()

	inst.name = "%s_%d" % [inst.name if inst.name != "" else "Ingredient", count]
	count += 1

	return inst

extends Node

var station_order: Array = ["Ingredient", "Chopping", "Cooking", "Serving"] # optional
var ingredients: Dictionary = {}
var recipes: Dictionary = {}
var stations_by_type: Dictionary = {}

func _ready() -> void:
	add_to_group("game_manager")
	_register_stations()
	_setup_demo_data()
	process_recipe("demo_salad")

func _register_stations() -> void:
	stations_by_type.clear()
	for s in get_tree().get_nodes_in_group("stations"):
		var t: String = s.station_type
		if t == "":
			continue
		if not stations_by_type.has(t):
			stations_by_type[t] = []
		# append must happen every time (outside the if)
		stations_by_type[t].append(s)
	print("Registered stations:", stations_by_type.keys())

func _setup_demo_data() -> void:
	ingredients.clear()
	recipes.clear()

	ingredients["lettuce"]  = {"id":"lettuce",  "name":"lettuce",  "status":"raw"}
	ingredients["tomato"]   = {"id":"tomato",   "name":"tomato",   "status":"raw"}
	ingredients["cucumber"] = {"id":"cucumber", "name":"cucumber", "status":"raw"}
	ingredients["mushroom"] = {"id":"mushroom", "name":"mushroom", "status":"raw"} # needed for demo_soup

	recipes = {
		"demo_salad": {
			"flow": ["Ingredient", "Chopping", "Serving"],
			"base_items": ["lettuce", "tomato", "cucumber"]
		},
		"demo_soup": {
			"flow": ["Ingredient", "Chopping", "Cooking", "Serving"],
			"base_items": ["tomato", "mushroom"]
		}
	}

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

		var item: Dictionary = ingredients[ing_id]  # reference to the stored dict
		print("\n=== Start item:", ing_id, "status:", item.get("status", ""))

		for stype in flow:
			var station_list: Array = stations_by_type.get(stype, [])
			if station_list.is_empty():
				print("Warning: no station of type", stype, "found. Skipping.")
				continue

			var station: Node = station_list[0]
			print("-> Sending", ing_id, "to", stype, "station:", station.name)

			var new_status := ""
			if station.has_method("process_item"):
				# Expect Station.process_item to mutate item["status"] and return the new status.
				new_status = station.process_item(item)
			else:
				# Fallback: do a generic transform here if station lacks process_item
				new_status = _generic_transform(stype, item.get("status", "raw"))

			# Keep item["status"] consistent if station didn't set it
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
			# Serving would normally consume; you can clear or mark as "served"
			if status == "chopped" or status == "cooked" or status == "raw":
				return "served"
		_:
			pass
	return status

func get_ingredient_status(ing_id: String) -> String:
	if ingredients.has(ing_id):
		return String(ingredients[ing_id].get("status", ""))
	print("Ingredient:", ing_id, "does not exist")
	return ""

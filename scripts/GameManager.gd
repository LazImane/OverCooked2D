extends Node

var station_order: Array = ["Ingredient", "Chopping", "Cooking", "Serving"]
var ingredients: Dictionary = {}
var recipes: Dictionary = {}
var stations_by_type: Dictionary = {}

func _ready() -> void:
	_register_stations()
	_setup_demo_data()
	process_recipe("soup")

func _register_stations() -> void:
	stations_by_type.clear()
	for s in get_tree().get_nodes_in_group("stations"):
		var t: String = s.station_type
		if not stations_by_type.has(t):
			stations_by_type[t] = []
			stations_by_type[t].append(s)
		if not stations_by_type.has(t):
			stations_by_type[t] = []
		stations_by_type[t].append(s)
	print("Registered stations:", stations_by_type.keys())

func _setup_demo_data() -> void:
	ingredients["soup_ingredient"] = {"name":"soup_ingredient", "status":"raw"}
	recipes["soup"] = ["soup_ingredient"]

func process_recipe(recipe_name: String) -> void:
	if not recipes.has(recipe_name):
		print("Recipe not found:", recipe_name)
		return

	var ing_list: Array = recipes[recipe_name]
	print("Processing recipe:", recipe_name, "ingredients:", ing_list)

	for ing_id in ing_list:
		if not ingredients.has(ing_id):
			print("Unknown ingredient:", ing_id)
			continue

		var ingredient: Dictionary = ingredients[ing_id]

		for stype in station_order:
			var station_list: Array = stations_by_type.get(stype, [])
			if station_list.is_empty():
				print("Warning: no station of type", stype, "found. skipping.")
				continue

			var station: Node = station_list[0]
			print("-> Sending", ing_id, "to", stype, "station:", station.name)

			var new_status: String = station.process(ingredient)
			print("   status now:", new_status)

		print("Final status for", ing_id, "=", ingredient["status"])

func get_ingredient_status(ing_id: String) -> String:
	if ingredients.has(ing_id):
		return ingredients[ing_id].get("status", "")
	return ""

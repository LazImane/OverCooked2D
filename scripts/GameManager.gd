
extends Node

var station_order: Array = ["Ingredient", "Chopping", "Cooking", "Serving"]
var ingredients: Dictionary = {} 
var recipes: Dictionary = {} 
var stations_by_type: Dictionary = {}

func _ready() -> void:
	_register_stations()
	_setup_demo_data()

func _register_stations() -> void:
	stations_by_type.clear()
	for s in get_tree().get_nodes_in_group("stations"):
		var t: String = s.station_type
		if not stations_by_type.has(t):
			stations_by_type[t] = []
			stations_by_type[t].append(s)
	print("Registered stations:", stations_by_type.keys())

func _setup_demo_data() -> void:
	ingredients["soup_ingredient"] = {"name":"soup_ingredient", "status":"raw"}
	recipes["soup"] = ["soup_ingredient"]
	
func get_ingredient_status(ing_id: String) -> String:
	if ingredients.has(ing_id):
		return ingredients[ing_id].get("status", "")
	print("Ingredient : ",ing_id,"does not exist")
	return ""

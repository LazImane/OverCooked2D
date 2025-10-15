extends Area2D

@export var station_type: String = "Ingredient"
signal station_processed(ingredient_name, new_status)

func _ready() -> void:
	add_to_group("stations")

func process(ingredient: Dictionary) -> String:
	var ing_name: String = ingredient.get("name", "unknown")
	var prev: String = ingredient.get("status", "raw")
	var new_status: String = prev

	match station_type:
		"Ingredient":
			new_status = "raw"
			print("grab_ingredient_", ing_name, " -> ingredient retrieved")
		"Chopping":
			if prev == "raw":
				new_status = "chopped"
				print("ingredient chopped:", ing_name)
			else:
				print("Chopping skipped for", ing_name, "(status:", prev, ")")
		"Cooking":
			if prev in ["raw", "chopped"]:
				new_status = "cooked"
				print("ingredient cooked:", ing_name)
			else:
				print("Cooking skipped for", ing_name, "(status:", prev, ")")
		"Serving":
			if prev == "cooked":
				new_status = "served"
				print("ingredient served:", ing_name)
			else:
				print("Serving skipped for", ing_name, "(status:", prev, ")")
		_:
			print("Unknown station_type:", station_type)

	ingredient["status"] = new_status
	emit_signal("station_processed", ing_name, new_status)
	return new_status

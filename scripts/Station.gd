extends Area2D

@export var station_type: String = "Ingredient"
signal station_processed(ingredient_name: String, new_status: String)

# used by the bot
var current_item: String = ""# stores what's on the station (e.g. "", "soup_ingredient", "chopped_soup_ingredient", ...)
@export var spawn_item_when_interacted: String = "tomato"

func _ready() -> void:
	add_to_group("stations")

# ------------------------
# API used by GameManager
# ------------------------
# Process an ingredient dictionary (GameManager flow). Returns the new status string.
func process(ingredient: Dictionary) -> String:
	var ingredient_name: String = ingredient.get("name", "unknown")
	var prev: String = ingredient.get("status", "raw")
	var new_status: String = prev

	match station_type:
		"Ingredient":
			new_status = "raw"
			print("grab_ingredient_", ingredient_name, " -> ingredient retrieved")
		"Chopping":
			if prev == "raw":
				new_status = "chopped"
				print("ingredient chopped:", ingredient_name)
			else:
				print("Chopping skipped for", ingredient_name, "(status:", prev, ")")
		"Cooking":
			if prev in ["raw", "chopped"]:
				new_status = "cooked"
				print("ingredient cooked:", ingredient_name)
			else:
				print("Cooking skipped for", ingredient_name, "(status:", prev, ")")
		"Serving":
			if prev == "cooked":
				new_status = "served"
				print("ingredient served:", ingredient_name)
			else:
				print("Serving skipped for", ingredient_name, "(status:", prev, ")")
		_:
			print("Unknown station_type:", station_type)

	ingredient["status"] = new_status
	emit_signal("station_processed", ingredient_name, new_status)
	return new_status

# ------------------------
# API used by Bot
# ------------------------
# Called when the bot presses/interacts with this station.
func interact() -> void:
	#print("[STATION DEBUG] ", name, " interact called. station_type: ", station_type, " current_item: '", current_item, "'")
	
	match station_type:
		"Ingredient":
			# spawn an ingredient if empty
			if current_item == "":
				current_item = spawn_item_when_interacted
				print("[STATION DEBUG] Spawned: '", current_item, "' on ", name)
			else:
				print("[STATION DEBUG] Station not empty, has: '", current_item, "'")
	match station_type:
		"Ingredient":
			# spawn an ingredient if empty
			if current_item == "":
				current_item = spawn_item_when_interacted
				print("[STATION] Ingredient spawned:", current_item, "on", name)
		"Chopping":
			if current_item == "tomato":
				current_item = "chopped_tomato"
				print("[STATION] Chopped ->", current_item, "on", name)
		"Cooking":
			if current_item == "chopped_tomato":
				current_item = "cooked_tomato"
				print("[STATION] Cooked ->", current_item, "on", name)
		"Serving":
			if current_item == "cooked_tomato":
				print("[STATION] Served:", current_item, "from", name)
				current_item = ""
		_:
			print("[STATION] interact(): unknown station_type:", station_type)

	# update visuals if you implement it
	if has_method("update_appearance"):
		update_appearance()

# Give the bot a string of the current item and clear it.
func take_item() -> String:
	var tmp: String = current_item
	if tmp != "":
		current_item = ""
		if has_method("update_appearance"):
			update_appearance()
		print("[STATION] take_item() ->", tmp, "from", name)
	return tmp

# Place an item on the station (returns true if placed)
func place_item(it: String) -> bool:
	if current_item == "":
		current_item = it
		if has_method("update_appearance"):
			update_appearance()
		print("[STATION] place_item(", it, ") on", name)
		return true
	return false

# Helper used by bot
func update_appearance() -> void:
	# stub: update sprite/label according to current_item
	# e.g. change child Sprite2D region, show a Label, etc.
	# implement as you like later.
	pass

# Optional helper to get current item safely
func get_current_item() -> String:
	return current_item

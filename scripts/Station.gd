extends Area2D

@export var station_type: String = "Ingredient"
signal station_processed(ingredient_name: String, new_status: String)

# Used by the bot
var current_item: String = ""  # e.g. "", "tomato", "chopped_tomato", "cooked_tomato"
@export var spawn_item_when_interacted: String = "tomato"  # fallback if GM not available

# --- internals ---
var _gm: Node = null
var _local_spawn_idx := 0  # local round-robin if GM doesn't expose next_base_item()

func _ready() -> void:
	add_to_group("stations")
	_gm = get_tree().get_first_node_in_group("game_manager")

# Optional alias so GameManager can call either name
func process_item(item: Dictionary) -> String:
	return process(item)

# ------------------------
# API used by GameManager
# ------------------------
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
# API used by Bot / player input
# ------------------------
func interact() -> void:
	match station_type:
		"Ingredient":
			if current_item == "":
				# Ask GameManager for the next ingredient from the *active recipe*.
				# Priority:
				#   1) gm.next_base_item() if it exists
				#   2) round-robin over gm.recipes[current_recipe_id or "demo_salad"].base_items
				#   3) fallback to exported spawn_item_when_interacted
				var spawn := _spawn_from_recipe_or_fallback()
				if spawn != "":
					current_item = spawn
					print("[STATION] Ingredient spawned:", current_item, "on", name)
				else:
					print("[STATION] No base items available; using fallback:", spawn_item_when_interacted)
					current_item = spawn_item_when_interacted
		"Chopping":
			if current_item != "" and not current_item.begins_with("chopped_") and not current_item.begins_with("cooked_"):
				current_item = "chopped_%s" % current_item
				print("[STATION] Chopped ->", current_item, "on", name)
		"Cooking":
			if current_item.begins_with("chopped_"):
				var base := current_item.substr("chopped_".length())
				current_item = "cooked_%s" % base
				print("[STATION] Cooked ->", current_item, "on", name)
		"Serving":
			# Accept the right final stage depending on recipe flow if we can read it from GM.
			if _can_serve_current_item():
				print("[STATION] Served:", current_item, "from", name)
				current_item = ""
		_:
			print("[STATION] interact(): unknown station_type:", station_type)

	# update visuals if you implement it
	if has_method("update_appearance"):
		update_appearance()

func take_item() -> String:
	var tmp: String = current_item
	if tmp != "":
		current_item = ""
		if has_method("update_appearance"):
			update_appearance()
		print("[STATION] take_item() ->", tmp, "from", name)
	return tmp

func place_item(it: String) -> bool:
	if current_item == "":
		current_item = it
		if has_method("update_appearance"):
			update_appearance()
		print("[STATION] place_item(", it, ") on", name)
		return true
	return false

func update_appearance() -> void:
	# stub: update sprite/label according to current_item
	pass

func get_current_item() -> String:
	return current_item

# ------------------------
# Helpers to talk to GameManager
# ------------------------
func _spawn_from_recipe_or_fallback() -> String:
	if _gm == null:
		_gm = get_tree().get_first_node_in_group("game_manager")

	# 1) Preferred: manager provides next_base_item()
	if _gm and _gm.has_method("next_base_item"):
		var id := String(_gm.next_base_item())
		if id != "":
			return id

	# 2) Read allowed base items from the active recipe on the manager
	var base_items := _gm_get_allowed_base_items()
	if base_items.size() > 0:
		var id2 := String(base_items[_local_spawn_idx % base_items.size()])
		_local_spawn_idx += 1
		return id2

	# 3) Fallback to exported default
	return spawn_item_when_interacted

func _gm_get_allowed_base_items() -> Array:
	if _gm == null:
		_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm == null:
		return []

	# read current_recipe_id (default to "demo_salad")
	var rid_val = _gm.get("current_recipe_id")
	var rid: String = String(rid_val) if typeof(rid_val) == TYPE_STRING else "demo_salad"

	# read recipes dict
	var recipes_val = _gm.get("recipes")
	if typeof(recipes_val) != TYPE_DICTIONARY:
		return []

	var rec: Dictionary = (recipes_val.get(rid, Dictionary())) as Dictionary
	if typeof(rec) != TYPE_DICTIONARY:
		return []

	var items: Array = (rec.get("base_items", Array())) as Array
	return items



func _required_stage_for_serving() -> String:
	if _gm == null:
		_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm == null:
		return "Unknown"

	var recipes_val = _gm.get("recipes")
	if typeof(recipes_val) != TYPE_DICTIONARY:
		return "Unknown"

	var rid_val = _gm.get("current_recipe_id")
	var rid: String = String(rid_val) if typeof(rid_val) == TYPE_STRING else "demo_salad"

	var rec: Dictionary = (recipes_val.get(rid, Dictionary())) as Dictionary
	if typeof(rec) != TYPE_DICTIONARY:
		return "Unknown"

	var flow: Array = (rec.get("flow", Array())) as Array
	var i: int = flow.rfind("Serving")
	if i > 0:
		return String(flow[i - 1])
	return "Ingredient"


func _can_serve_current_item() -> bool:
	if current_item == "":
		return false
	var req := _required_stage_for_serving()
	match req:
		"Chopping":
			return current_item.begins_with("chopped_") or current_item.find("_chopped") != -1 # tolerate alt naming
		"Cooking":
			return current_item.begins_with("cooked_") or current_item.find("_cooked") != -1
		"Ingredient":
			# Rare flow ["Ingredient","Serving"]
			return not current_item.begins_with("chopped_") and not current_item.begins_with("cooked_")
		"Unknown":
			# If we can't read recipe flow, accept cooked first, then chopped.
			return current_item.begins_with("cooked_") or current_item.begins_with("chopped_")
	return false

extends Area2D

@export var station_type: String = "Ingredient"
signal station_processed(ingredient_name: String, new_status: String)


# Used by the bot
var current_item: String = ""  # e.g. "", "tomato", "chopped_tomato", "cooked_tomato"
@export var spawn_item_when_interacted: String = ""  # fallback if GM not available

# --- internals ---
var _gm: Node = null
var _local_spawn_idx := 0  # local round-robin if GM doesn't expose next_base_item()
var _plate_need: Array = []   # required base ids (e.g. ["tomato","lettuce","cucumber"])
var _plate_have: Array = [] 

func _ready() -> void:
	add_to_group("stations")
	_gm = get_tree().get_first_node_in_group("game_manager")
	# If this station is Serving, fetch the recipe needs now
	if station_type == "Serving" and _gm:
		var rid_val = _gm.get("current_recipe_id")
		var rid: String = (rid_val if typeof(rid_val) == TYPE_STRING else "demo_salad")
		var recipes_val = _gm.get("recipes")
		if typeof(recipes_val) == TYPE_DICTIONARY:
			var rec: Dictionary = (recipes_val.get(rid, Dictionary())) as Dictionary
			_plate_need = (rec.get("required_bases", Array())) as Array
	_plate_have.clear()

func plate_is_complete() -> bool:
	if _plate_need.is_empty():
		return false
	# All required bases present (order doesn’t require duplicates)
	for b in _plate_need:
		if not _plate_have.has(b):
			return false
	return true

func plate_state() -> Dictionary:
	return {"need": _plate_need.duplicate(), "have": _plate_have.duplicate()}

# Optional alias so GameManager can call either name
func process_item(item: Dictionary) -> String:
	return process(item)

# ------------------------
# API used by GameManager
# ------------------------
# used by the bot


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

				var spawn := _spawn_from_recipe_or_fallback()
				if spawn != "":
					current_item = spawn
					emit_signal("item_changed", "", current_item)  # spawned
		"Chopping":
			if current_item != "" and not current_item.begins_with("chopped_") and not current_item.begins_with("cooked_"):
				var before := current_item
				current_item = "chopped_%s" % current_item
				emit_signal("item_changed", before, current_item)
		"Cooking":
			if current_item.begins_with("chopped_"):
				var before := current_item
				var base := current_item.substr("chopped_".length())
				current_item = "cooked_%s" % base
				emit_signal("item_changed", before, current_item)
		"Serving":
			# ✅ no 'break'—use early return if nothing on station
			if current_item == "":
				return

			var req_stage := _required_stage_for_serving()
			var base := current_item
			if current_item.begins_with("chopped_"):
				base = current_item.substr("chopped_".length())
			elif current_item.begins_with("cooked_"):
				base = current_item.substr("cooked_".length())

			var ok := false
			match req_stage:
				"Chopping":
					ok = current_item.begins_with("chopped_")
				"Cooking":
					ok = current_item.begins_with("cooked_")
				"Ingredient":
					ok = not current_item.begins_with("chopped_") and not current_item.begins_with("cooked_")
					ok = false

			# Only add bases that are required and not duplicated
			if ok and (_plate_need.is_empty() or _plate_need.has(base)) and not _plate_have.has(base):
				_plate_have.append(base)
				emit_signal("item_progress", base, _plate_have.duplicate(), _plate_need.duplicate())
				current_item = ""  # consume placed item

				if plate_is_complete():
					emit_signal("item_served", "order:" + ",".join(_plate_have))
					_plate_have.clear()
			else:
				# reject or stage-mismatch; optionally consume anyway:
				current_item = spawn_item_when_interacted
				print("[STATION DEBUG] Spawned: '", current_item, "' on ", name)
			
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

	pass

# Optional helper to get current item safely
func get_current_item() -> String:
	return current_item


# ------------------------
# Helpers to talk to GameManager
# ------------------------
func _spawn_from_recipe_or_fallback() -> String:
	# 1) Ensure we have a reference to the GameManager
	if _gm == null:
		_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm == null:
		push_warning("[STATION] No GameManager found — cannot determine ingredient to spawn.")
		return ""  # no spawn possible

	# 2) Try to use GameManager-provided helper
	if _gm.has_method("next_base_item"):
		var id := String(_gm.next_base_item())
		if id != "":
			print("[STATION] Spawned from GM.next_base_item():", id)
			return id

	# 3) Try reading directly from the current recipe
	var current_recipe_id := "demo_salad"
	if _gm.get("current_recipe_id") != "":
		var rid_val = _gm.get("current_recipe_id")
		if typeof(rid_val) == TYPE_STRING and rid_val != "":
			current_recipe_id = rid_val

	var recipes_val = _gm.get("recipes")
	if typeof(recipes_val) == TYPE_DICTIONARY and recipes_val.has(current_recipe_id):
		var rec: Dictionary = recipes_val[current_recipe_id]
		var base_items: Array = rec.get("base_items", [])
		if base_items.size() > 0:
			var id2 := String(base_items[_local_spawn_idx % base_items.size()])
			_local_spawn_idx += 1
			print("[STATION] Spawned from recipe '%s': %s" % [current_recipe_id, id2])
			return id2

	# 4) If we get here, try exported fallback — only if non-empty
	if spawn_item_when_interacted != "":
		print("[STATION] Using fallback exported item:", spawn_item_when_interacted)
		return spawn_item_when_interacted

	# 5) If absolutely nothing works, return a placeholder to avoid crash
	push_warning("[STATION] No ingredients available to spawn — returning placeholder 'unknown_item'")
	return "unknown_item"

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

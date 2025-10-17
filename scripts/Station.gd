extends Area2D

@export var station_type: String = "Ingredient"
signal station_processed(ingredient_name: String, new_status: String)
signal item_served(item_id: String)  # GameManager listens to this

var current_item: String = ""                  # "", "tomato", "chopped_tomato", "cooked_tomato"
@export var spawn_item_when_interacted: String = "tomato"  # fallback if no GM/recipe

var _gm: Node = null
var _local_spawn_idx: int = 0  # round-robin if GM doesn’t provide next_base_item()

func _ready() -> void:
	add_to_group("stations")
	_gm = get_tree().get_first_node_in_group("game_manager")

# Alias so GameManager can call either name
func process_item(item: Dictionary) -> String:
	return process(item)

# -------- Called by GameManager (flow simulation) --------
func process(ingredient: Dictionary) -> String:
	var name: String = String(ingredient.get("name", "unknown"))
	var prev: String = String(ingredient.get("status", "raw"))
	var next := prev

	match station_type:
		"Ingredient":
			next = "raw"
		"Chopping":
			if prev == "raw":
				next = "chopped"
		"Cooking":
			if prev == "chopped":
				next = "cooked"
		"Serving":
			var req := _required_stage_for_serving()
			if (req == "Cooking" and prev == "cooked") \
			or (req == "Chopping" and prev == "chopped") \
			or (req == "Ingredient" and prev == "raw"):
				next = "served"
			else:
				next = prev
		_:
			pass

	ingredient["status"] = next
	emit_signal("station_processed", name, next)
	return next

# -------- Player/Bot interaction (no prints) --------
func interact() -> void:
	match station_type:
		"Ingredient":
			if current_item == "":
				var spawn := _spawn_from_recipe_or_fallback()
				if spawn != "":
					current_item = spawn

		"Chopping":
			if current_item != "" and not current_item.begins_with("chopped_") and not current_item.begins_with("cooked_"):
				current_item = "chopped_%s" % current_item

		"Cooking":
			if current_item.begins_with("chopped_"):
				var base := current_item.substr("chopped_".length())
				current_item = "cooked_%s" % base

		"Serving":
			if _can_serve_current_item():
				emit_signal("item_served", current_item)  # GM will log completion
				current_item = ""

		_:
			pass

	if has_method("update_appearance"):
		update_appearance()

func take_item() -> String:
	var tmp := current_item
	if tmp != "":
		current_item = ""
		if has_method("update_appearance"):
			update_appearance()
	return tmp

func place_item(it: String) -> bool:
	if current_item == "":
		current_item = it
		if has_method("update_appearance"):
			update_appearance()
		return true
	return false

func update_appearance() -> void:
	# hook for visuals
	pass

func get_current_item() -> String:
	return current_item

# -------- Helpers to talk to GameManager (no prints) --------
func _spawn_from_recipe_or_fallback() -> String:
	if _gm == null:
		_gm = get_tree().get_first_node_in_group("game_manager")

	# 1) Prefer GM selection
	if _gm and _gm.has_method("next_base_item"):
		var id1 = _gm.next_base_item()
		if typeof(id1) == TYPE_STRING and id1 != "":
			return String(id1)

	# 2) Round-robin local read of recipe base_items
	var base_items := _gm_get_allowed_base_items()
	if base_items.size() > 0:
		var id2 := String(base_items[_local_spawn_idx % base_items.size()])
		_local_spawn_idx += 1
		return id2

	# 3) Fallback
	return spawn_item_when_interacted

func _gm_get_allowed_base_items() -> Array:
	if _gm == null:
		return []
	var rid_val = _gm.get("current_recipe_id")
	var rid: String = String(rid_val) if typeof(rid_val) == TYPE_STRING else "demo_salad"

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
		return String(flow[i - 1])  # "Chopping" or "Cooking"
	return "Ingredient"

func _can_serve_current_item() -> bool:
	if current_item == "":
		return false
	var req := _required_stage_for_serving()
	match req:
		"Chopping":
			return current_item.begins_with("chopped_")
		"Cooking":
			return current_item.begins_with("cooked_")
		"Ingredient":
			return not current_item.begins_with("chopped_") and not current_item.begins_with("cooked_")
		"Unknown":
			return current_item.begins_with("cooked_") or current_item.begins_with("chopped_")
	return false

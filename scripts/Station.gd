extends Area2D

@export var station_type: String = "Ingredient"
signal station_processed(ingredient_name: String, new_status: String)

# Used by the bot / GameManager logic
var current_item: String = ""  # e.g. "", "tomato", "chopped_tomato", "cooked_tomato"
@export var spawn_item_when_interacted: String = "tomato"  # fallback if GM not available

# Visuals (node instance of Ingredient.tscn)
var current_ingredient: Node = null  # visual instance (preferred)

# --- internals ---
var _gm: Node = null
var _local_spawn_idx := 0  # local round-robin if GM doesn't expose next_base_item()

func _ready() -> void:
	add_to_group("stations")
	_gm = get_tree().get_first_node_in_group("game_manager")
	update_appearance()

# Optional alias so GameManager can call either name
func process_item(item: Dictionary) -> String:
	return process(item)

# ------------------------
# API used by GameManager (non-visual processing)
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
	# For ingredient station: spawn (node) if empty
	if station_type == "Ingredient":
		if current_ingredient == null and current_item == "":
			var gm = _ensure_gm()
			if gm and gm.has_method("spawn_ingredient"):
				var inst = gm.spawn_ingredient("", get_parent())  # parent = Game root
				if inst:
					_place_visual_on_station(inst)
					# sync string type if available
					if inst.has_method("get_type"):
						current_item = inst.get("type")
					elif inst.has_meta("type"):
						current_item = String(inst.get_meta("type"))
					else:
						# try name fallback
						current_item = String(inst.name)
					update_appearance()
		return

	# For transform stations: apply stage to what's on the station
	if station_type in ["Chopping", "Cooking", "Serving"]:
		# If there is a visual node on the station, prefer to transform it
		if current_ingredient != null and is_instance_valid(current_ingredient):
			if current_ingredient.has_method("apply_stage"):
				current_ingredient.apply_stage(station_type)
				# sync string type to remain compatible
				if current_ingredient.has_method("get_type"):
					current_item = current_ingredient.get("type")
				else:
					# try reading a "type" property if present
					if current_ingredient.has_meta("type"):
						current_item = String(current_ingredient.get_meta("type"))
					else:
						current_item = String(current_ingredient.name)
				# If the station is a Serving station, you may want to consume the item
				if station_type == "Serving":
					# Optionally free or keep the visual (here we free and clear)
					current_ingredient.queue_free()
					current_ingredient = null
					current_item = ""
				update_appearance()
			else:
				# no apply_stage supported, fall back to string-only behavior
				_transform_string_item()
		else:
			# no node present: maybe this station uses legacy string field
			_transform_string_item()
		return

	# default fallback
	print("[STATION] interact(): unknown station_type:", station_type)
	if has_method("update_appearance"):
		update_appearance()

# ------------------------
# Transform helper for legacy string-only mode
# ------------------------
func _transform_string_item() -> void:
	if current_item == "":
		return
	match station_type:
		"Chopping":
			if not current_item.begins_with("chopped_") and not current_item.begins_with("cooked_"):
				current_item = "chopped_%s" % current_item
				print("[STATION] Chopped ->", current_item, "on", name)
		"Cooking":
			if current_item.begins_with("chopped_"):
				var base := current_item.substr("chopped_".length())
				current_item = "cooked_%s" % base
				print("[STATION] Cooked ->", current_item, "on", name)
		"Serving":
			if _can_serve_current_item():
				print("[STATION] Served:", current_item, "from", name)
				current_item = ""
		_:
			pass
	update_appearance()

# ------------------------
# Visual-aware take/place
# ------------------------
func take_item():
	# prefer returning an Ingredient node if present
	if current_ingredient != null and is_instance_valid(current_ingredient):
		var tmp = current_ingredient
		current_ingredient = null
		current_item = ""
		update_appearance()
		print("[STATION] take_item() ->", tmp.name, "from", name)
		return tmp

	# fallback to old string behavior
	var tmp_str: String = current_item
	if tmp_str != "":
		current_item = ""
		# free any stale visual
		if current_ingredient and is_instance_valid(current_ingredient):
			current_ingredient.queue_free()
			current_ingredient = null
		update_appearance()
		print("[STATION] take_item() ->", tmp_str, "from", name)
		return tmp_str

	return null

func place_item(it) -> bool:
	# it can be Node or String
	if current_ingredient == null and current_item == "":
		if it == null:
			return false
		# Node: reparent and set
		if typeof(it) == TYPE_OBJECT and it is Node:
			_place_visual_on_station(it)
			# sync string if possible
			if it.has_method("get_type"):
				current_item = it.get("type")
			elif it.has_meta("type"):
				current_item = String(it.get_meta("type"))
			else:
				current_item = String(it.name)
			update_appearance()
			print("[STATION] place_item(node) on", name)
			return true
		# String: spawn a visual via GM if possible
		else:
			var gm = _ensure_gm()
			if gm and gm.has_method("spawn_ingredient"):
				var node = gm.spawn_ingredient(String(it), get_parent())
				if node:
					_place_visual_on_station(node)
					current_item = String(it)
					update_appearance()
					print("[STATION] place_item(string->node) on", name)
					return true
			# fallback to legacy string-only placement
			current_item = String(it)
			update_appearance()
			print("[STATION] place_item(string) on", name)
			return true
	return false

# ------------------------
# Appearance and helpers
# ------------------------
func update_appearance() -> void:
	# Align the visual ingredient on the station and optionally change station's tint
	# If the station has its own Sprite2D child, we modulate it for feedback
	if current_ingredient != null and is_instance_valid(current_ingredient):
		# ensure the ingredient sits centered on the station
		if current_ingredient.get_parent() != self:
			# already parented by place_item/_place_visual_on_station in most flows, but ensure
			if current_ingredient.get_parent():
				current_ingredient.get_parent().remove_child(current_ingredient)
			add_child(current_ingredient)
		current_ingredient.position = Vector2.ZERO
		# tint station sprite to show occupied (optional)
		if has_node("Sprite2D"):
			$Sprite2D.modulate = Color(1, 0.95, 0.85)
	else:
		# no visual item: reset tint
		if has_node("Sprite2D"):
			$Sprite2D.modulate = Color(1,1,1)

func _place_visual_on_station(node: Node) -> void:
	# helper to reparent and center a visual node on this station
	if node.get_parent():
		node.get_parent().remove_child(node)
	add_child(node)
	node.position = Vector2.ZERO
	if node.has_method("drop_at"):
		node.drop_at(self)
	current_ingredient = node

func _ensure_gm() -> Node:
	if _gm == null:
		_gm = get_tree().get_first_node_in_group("game_manager")
	return _gm

# ------------------------
# existing helpers unchanged (recipe-based spawning etc.)
# ------------------------
func get_current_item() -> String:
	return current_item

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
			return current_item.begins_with("chopped_") or current_item.find("_chopped") != -1
		"Cooking":
			return current_item.begins_with("cooked_") or current_item.find("_cooked") != -1
		"Ingredient":
			return not current_item.begins_with("chopped_") and not current_item.begins_with("cooked_")
		"Unknown":
			return current_item.begins_with("cooked_") or current_item.begins_with("chopped_")
	return false

extends Area2D

@export var station_type: String = "Ingredient"
signal station_processed(ingredient_name: String, new_status: String)

var current_item: String = ""
@export var spawn_item_when_interacted: String = ""

# For serving station: track all ingredients
var served_ingredients: Array = []  # Array of ingredient Nodes
var _gm: Node = null
var _local_spawn_idx := 0

func _ready() -> void:
	add_to_group("stations")
	_gm = get_tree().get_first_node_in_group("game_manager")
	update_appearance()

func process_item(item: Dictionary) -> String:
	return process(item)

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

func interact() -> void:
	if station_type == "Ingredient":
		# Ingredient stations don't use interact for spawning anymore
		# Bots handle spawning directly
		return

	if station_type in ["Chopping", "Cooking"]:
		# Transform the item on the station
		if has_ingredient():
			var ing = get_current_ingredient()
			if ing and ing.has_method("apply_stage"):
				ing.apply_stage(station_type)
				if ing.has_method("get_type"):
					current_item = ing.get_type()
				elif "type" in ing:
					current_item = ing.type
				print("[STATION] Processed at", station_type, "->", current_item)
				update_appearance()
		return

	if station_type == "Serving":
		# Serving station: DON'T process individual items
		# Just acknowledge placement
		print("[STATION] Item placed on serving station (waiting for recipe completion)")
		return

func take_item() -> Node:
	"""Remove and return the ingredient node"""
	# For serving station, don't allow taking items back
	if station_type == "Serving":
		print("[STATION] Cannot take items from serving station")
		return null
	
	var ing = get_current_ingredient()
	if ing and is_instance_valid(ing):
		# Remove from our tracking
		_remove_ingredient(ing)
		current_item = ""
		
		print("[STATION] take_item() ->", ing.name, "from", name)
		update_appearance()
		return ing
	
	print("[STATION] take_item() -> null (nothing to take) from", name)
	return null

func place_item(it) -> bool:
	"""Place an ingredient on this station"""
	if it == null:
		return false
	
	# Serving station: accumulate ingredients
	if station_type == "Serving":
		if typeof(it) == TYPE_OBJECT and it is Node:
			_add_ingredient_to_serving(it)
			print("[STATION] 🍽️ Added to serving station:", it.name, "(total: %d)" % served_ingredients.size())
			return true
		return false
	
	# Other stations: only hold one item
	if not has_ingredient():
		if typeof(it) == TYPE_OBJECT and it is Node:
			_add_ingredient(it)
			if it.has_method("get_type"):
				current_item = it.get_type()
			elif "type" in it:
				current_item = it.type
			else:
				current_item = String(it.name)
			update_appearance()
			print("[STATION] place_item(node:", current_item, ") on", name)
			return true
		else:
			# String placement (legacy)
			var gm = _ensure_gm()
			if gm and gm.has_method("spawn_ingredient"):
				var node = gm.spawn_ingredient(String(it), get_parent())
				if node:
					_add_ingredient(node)
					current_item = String(it)
					update_appearance()
					print("[STATION] place_item(string->node:", current_item, ") on", name)
					return true
			current_item = String(it)
			update_appearance()
			return true
	
	print("[STATION] place_item() FAILED - station occupied at", name)
	return false

func has_ingredient() -> bool:
	"""Check if station has any ingredients"""
	if station_type == "Serving":
		return served_ingredients.size() > 0
	return get_current_ingredient() != null

func get_current_ingredient() -> Node:
	"""Get the first/main ingredient on this station"""
	if station_type == "Serving":
		return served_ingredients[0] if served_ingredients.size() > 0 else null
	
	# For other stations, check children for ingredient nodes
	for child in get_children():
		if child.has_method("get_type") or "type" in child:
			return child
	return null

func _add_ingredient(ing: Node) -> void:
	"""Add an ingredient node to this station (non-serving)"""
	if ing.get_parent():
		ing.get_parent().remove_child(ing)
	add_child(ing)
	ing.position = Vector2.ZERO
	if ing.has_method("drop_at"):
		ing.drop_at(self)

func _add_ingredient_to_serving(ing: Node) -> void:
	"""Add an ingredient to the serving station (accumulates)"""
	if ing.get_parent():
		ing.get_parent().remove_child(ing)
	add_child(ing)
	
	# Arrange ingredients in a row or grid
	var idx = served_ingredients.size()
	var offset_x = (idx % 3) * 20 - 20  # 3 items per row, centered
	var offset_y = int(idx / 3) * 20 - 10
	ing.position = Vector2(offset_x, offset_y)
	
	served_ingredients.append(ing)
	
	if ing.has_method("drop_at"):
		ing.drop_at(self)
	
	_check_recipe_completion()

func _remove_ingredient(ing: Node) -> void:
	"""Remove an ingredient from tracking"""
	if station_type == "Serving":
		served_ingredients.erase(ing)
	
	if ing.get_parent() == self:
		remove_child(ing)

func _check_recipe_completion() -> void:
	"""Check if the recipe is complete and trigger serving animation"""
	if station_type != "Serving":
		return
	
	var gm = _ensure_gm()
	if not gm:
		return
	
	# Get recipe requirements
	var recipe_id = gm.current_recipe_id if "current_recipe_id" in gm else "demo_salad"
	var required_ingredients = []
	
	if gm.has_method("get_recipe_ingredients"):
		required_ingredients = gm.get_recipe_ingredients(recipe_id)
	
	# Check if we have all required ingredients
	if served_ingredients.size() >= required_ingredients.size() and required_ingredients.size() > 0:
		print("[STATION] 🎉 Recipe complete! Serving %d ingredients..." % served_ingredients.size())
		_serve_complete_dish()

func _serve_complete_dish() -> void:
	"""Animate all ingredients disappearing and notify GameManager"""
	# Create a tween for smooth animation
	var tween = create_tween()
	tween.set_parallel(true)
	
	for ing in served_ingredients:
		if is_instance_valid(ing):
			# Fade out and move up
			tween.tween_property(ing, "modulate:a", 0.0, 0.8)
			tween.tween_property(ing, "position", ing.position + Vector2(0, -50), 0.8)
			tween.tween_property(ing, "scale", Vector2(0.15, 0.15), 0.8)
	
	# Wait for animation to complete
	await tween.finished
	
	# Clean up all ingredients
	for ing in served_ingredients:
		if is_instance_valid(ing):
			ing.queue_free()
	
	served_ingredients.clear()
	current_item = ""
	update_appearance()
	
	print("[STATION] ✅ Dish served to customer!")

func update_appearance() -> void:
	# Visual feedback for station occupancy
	if has_node("Sprite2D"):
		if has_ingredient():
			$Sprite2D.modulate = Color(1, 0.95, 0.85)
		else:
			$Sprite2D.modulate = Color(1, 1, 1)

func _ensure_gm() -> Node:
	if _gm == null:
		_gm = get_tree().get_first_node_in_group("game_manager")
	return _gm

func get_current_item() -> String:
	return current_item

func _spawn_from_recipe_or_fallback() -> String:
	if _gm == null:
		_gm = get_tree().get_first_node_in_group("game_manager")
	if _gm == null:
		push_warning("[STATION] No GameManager found – cannot determine ingredient to spawn.")
		return ""

	if _gm.has_method("next_base_item"):
		var id := String(_gm.next_base_item())
		if id != "":
			print("[STATION] Spawned from GM.next_base_item():", id)
			return id

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

	if spawn_item_when_interacted != "":
		print("[STATION] Using fallback exported item:", spawn_item_when_interacted)
		return spawn_item_when_interacted

	push_warning("[STATION] No ingredients available to spawn – returning placeholder 'unknown_item'")
	return "unknown_item"

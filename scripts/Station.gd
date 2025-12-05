extends Area2D

@export var station_type: String = "Ingredient"
@export var recipe_id: String = ""  # Which recipe this serving station handles
signal station_processed(ingredient_name: String, new_status: String)
var reserved_by: int = -1  
var current_item: String = ""
@export var spawn_item_when_interacted: String = ""
@export var station_id: int = -1

# For serving station: track ingredients by recipe
var served_ingredients: Array = []
var current_ingredient: Node = null
var _gm: Node = null
var _local_spawn_idx := 0
var _recipe_completed: bool = false  # NEW: Prevent duplicate completions

func _ready() -> void:
	add_to_group("stations")
	_gm = get_tree().get_first_node_in_group("game_manager")
	update_appearance()
	
	if station_type == "Serving":
		if recipe_id != "":
			print("[STATION %s] Dedicated to recipe: %s" % [name, recipe_id])
		else:
			print("[STATION %s] Accepts ALL recipes" % name)

func reserve(bot_id: int) -> bool:
	"""Try to reserve this station for a bot"""
	if reserved_by == -1:
		reserved_by = bot_id
		return true
	return reserved_by == bot_id

func unreserve(bot_id: int) -> void:
	"""Release reservation"""
	if reserved_by == bot_id:
		reserved_by = -1

func is_available() -> bool:
	"""Check if station can be used"""
	if station_type == "Serving":
		return not _recipe_completed  # Serving stations available until recipe done
	return reserved_by == -1 and current_ingredient == null

func process_item(item: Dictionary) -> String:
	return process(item)

func process(ingredient: Dictionary) -> String:
	var ingredient_name: String = ingredient.get("name", "unknown")
	var prev: String = ingredient.get("status", "raw")
	var new_status: String = prev

	match station_type:
		"Ingredient":
			new_status = "raw"
		"Chopping":
			if prev == "raw":
				new_status = "chopped"
		"Cooking":
			if prev in ["raw", "chopped"]:
				new_status = "cooked"
		"Serving":
			if prev == "cooked":
				new_status = "served"

	ingredient["status"] = new_status
	emit_signal("station_processed", ingredient_name, new_status)
	return new_status

func interact() -> void:
	if station_type == "Ingredient":
		return

	if station_type in ["Chopping", "Cooking"]:
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

func take_item() -> Node:
	"""Remove and return the ingredient node"""
	if station_type == "Serving":
		print("[STATION] Cannot take items from serving station")
		return null
	
	var ing = current_ingredient
	if ing and is_instance_valid(ing):
		current_ingredient = null
		current_item = ""
		
		if ing.get_parent() == self:
			remove_child(ing)
		
		print("[STATION] take_item() ->", ing.name, "from", name)
		update_appearance()
		return ing
	
	return null

func place_item(it, incoming_recipe_id: String = "") -> bool:
	"""Place an ingredient on this station"""
	if it == null:
		return false
	
	# Serving station: accumulate ingredients by recipe
	if station_type == "Serving":
		# Validate recipe match
		if recipe_id != "" and incoming_recipe_id != "" and incoming_recipe_id != recipe_id:
			print("[STATION] ❌ '%s' rejected ingredient (expected: %s, got: %s)" % 
				[name, recipe_id, incoming_recipe_id])
			return false
		
		# Don't accept more if recipe already completed
		if _recipe_completed:
			print("[STATION] ❌ '%s' recipe already completed, not accepting more" % name)
			return false
		
		if typeof(it) == TYPE_OBJECT and it is Node:
			_add_ingredient_to_serving(it)
			print("[STATION] 🍽️ Added to '%s' (recipe: %s): %s (%d/%d)" % 
				[name, recipe_id, it.name, served_ingredients.size(), _get_required_count()])
			return true
		return false
	
	# Other stations: only hold one item
	if current_ingredient == null and current_item == "":
		if typeof(it) == TYPE_OBJECT and it is Node:
			_place_visual_on_station(it)
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
			# String: spawn via GM
			var gm = _ensure_gm()
			if gm and gm.has_method("spawn_ingredient"):
				var node = gm.spawn_ingredient(String(it), get_parent())
				if node:
					_place_visual_on_station(node)
					current_item = String(it)
					update_appearance()
					print("[STATION] place_item(string->node:", current_item, ") on", name)
					return true
			current_item = String(it)
			update_appearance()
			print("[STATION] place_item(string:", current_item, ") on", name)
			return true
	
	print("[STATION] place_item() FAILED - station occupied at", name)
	return false

func has_ingredient() -> bool:
	"""Check if station has any ingredients"""
	if station_type == "Serving":
		return served_ingredients.size() > 0
	return current_ingredient != null

func get_current_ingredient() -> Node:
	"""Get the first/main ingredient on this station"""
	if station_type == "Serving":
		return served_ingredients[0] if served_ingredients.size() > 0 else null
	return current_ingredient

func _place_visual_on_station(node: Node) -> void:
	if node.get_parent():
		node.get_parent().remove_child(node)
	add_child(node)
	node.position = Vector2.ZERO
	if node.has_method("drop_at"):
		node.drop_at(self)
	current_ingredient = node

func _add_ingredient_to_serving(ing: Node) -> void:
	"""Add an ingredient to the serving station (accumulates)"""
	if ing.get_parent():
		ing.get_parent().remove_child(ing)
	add_child(ing)
	
	# Arrange ingredients in a row or grid
	var idx = served_ingredients.size()
	var offset_x = (idx % 2) * 18 - 9
	var offset_y = int(idx / 2) * 18 - 9
	ing.position = Vector2(offset_x, offset_y)
	
	served_ingredients.append(ing)
	
	if ing.has_method("drop_at"):
		ing.drop_at(self)
	
	_check_recipe_completion()

func _get_required_count() -> int:
	"""Get how many ingredients needed for this recipe"""
	var gm = _ensure_gm()
	if gm and gm.has_method("get_recipe_ingredients"):
		return gm.get_recipe_ingredients(recipe_id).size()
	return 0

func _check_recipe_completion() -> void:
	"""Check if the recipe is complete and trigger serving animation"""
	if station_type != "Serving" or _recipe_completed:
		return
	
	var gm = _ensure_gm()
	if not gm:
		return
	
	var required_count = _get_required_count()
	var current_count = served_ingredients.size()
	
	# Check if we have all required ingredients
	if current_count >= required_count and required_count > 0:
		_recipe_completed = true  # Prevent duplicate completions
		print("[STATION] 🎉 Recipe '%s' complete on '%s'! Serving %d ingredients..." % 
			[recipe_id, name, served_ingredients.size()])
		
		# Notify GM
		if gm.has_method("_complete_recipe_timer"):
			gm._complete_recipe_timer(recipe_id)
		
		_show_final_dish()

func _show_final_dish() -> void:
	"""Hide individual ingredients and show the complete dish icon"""
	for ing in served_ingredients:
		if is_instance_valid(ing) and ing.has_node("Sprite2D"):
			ing.get_node("Sprite2D").visible = false
	
	var dish_type = recipe_id
	match recipe_id:
		"demo_salad":
			dish_type = "greek_salad"
	
	var gm = _ensure_gm()
	if gm and gm.has_method("spawn_ingredient"):
		var final_dish = gm.spawn_ingredient(dish_type, self)
		if final_dish:
			final_dish.position = Vector2.ZERO
			
			if dish_type in ["greek_salad", "caesar_salad", "potato_soup"]:
				if final_dish.has_method("set_scale_override"):
					final_dish.set_scale_override(Vector2(0.08, 0.08))
				else:
					final_dish.scale = Vector2(0.08, 0.08)
			else:
				if final_dish.has_method("set_scale_override"):
					final_dish.set_scale_override(Vector2(0.15, 0.15))
				else:
					final_dish.scale = Vector2(0.15, 0.15)
			
			print("[STATION] ✨ Final dish '%s' displayed on '%s'" % [dish_type, name])
			
			await get_tree().create_timer(1.5).timeout
			_serve_complete_dish(final_dish)

func _serve_complete_dish(final_dish: Node = null) -> void:
	"""Animate all ingredients disappearing"""
	var tween = create_tween()
	tween.set_parallel(true)
	
	if final_dish and is_instance_valid(final_dish):
		tween.tween_property(final_dish, "modulate:a", 0.0, 0.8)
		tween.tween_property(final_dish, "position", final_dish.position + Vector2(0, -50), 0.8)
		tween.tween_property(final_dish, "scale", final_dish.scale * 1.3, 0.8)
	
	for ing in served_ingredients:
		if is_instance_valid(ing):
			tween.tween_property(ing, "modulate:a", 0.0, 0.8)
	
	await tween.finished
	
	if final_dish and is_instance_valid(final_dish):
		final_dish.queue_free()
	
	for ing in served_ingredients:
		if is_instance_valid(ing):
			ing.queue_free()
	
	served_ingredients.clear()
	current_item = ""
	_recipe_completed = false  # Reset for next recipe
	update_appearance()
	
	print("[STATION] ✅ Dish '%s' served from '%s'!" % [recipe_id, name])

func update_appearance() -> void:
	if station_type == "Serving":
		if has_node("Sprite2D"):
			if served_ingredients.size() > 0:
				$Sprite2D.modulate = Color(1, 0.95, 0.85)
			else:
				$Sprite2D.modulate = Color(1, 1, 1)
		return
	
	if current_ingredient != null and is_instance_valid(current_ingredient):
		if current_ingredient.get_parent() != self:
			if current_ingredient.get_parent():
				current_ingredient.get_parent().remove_child(current_ingredient)
			add_child(current_ingredient)
		current_ingredient.position = Vector2.ZERO
		if has_node("Sprite2D"):
			$Sprite2D.modulate = Color(1, 0.95, 0.85)
	else:
		if has_node("Sprite2D"):
			$Sprite2D.modulate = Color(1, 1, 1)

func _ensure_gm() -> Node:
	if _gm == null:
		_gm = get_tree().get_first_node_in_group("game_manager")
	return _gm

func get_current_item() -> String:
	return current_item

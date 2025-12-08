extends Area2D

@export var station_type: String = "Ingredient"
@export var recipe_id: String = ""  # Which recipe this serving station handles
signal station_processed(ingredient_name: String, new_status: String)
var reserved_by: int = -1  
var current_item: String = ""
@export var spawn_item_when_interacted: String = ""
@export var station_id: int = -1
var progress_label: Label = null


# For serving station: track ingredients by recipe
var served_ingredients: Array = []
var served_ingredient_types: Array = []  # NEW: Track what types we've added
var current_ingredient: Node = null
var _gm: Node = null
var _local_spawn_idx := 0
var _recipe_completed: bool = false
var _is_animating: bool = false  # NEW: Track animation state

func _ready() -> void:
	add_to_group("stations")
	_gm = get_tree().get_first_node_in_group("game_manager")
	update_appearance()
	
	if station_type == "Serving":
		if recipe_id != "":
			print("[STATION %s] Dedicated to recipe: %s" % [name, recipe_id])
		else:
			print("[STATION %s] Accepts ALL recipes" % name)
		_create_progress_label()

func _create_progress_label() -> void:
	"""Create a progress indicator label"""
	progress_label = Label.new()
	progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	progress_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	
	progress_label.add_theme_font_size_override("font_size", 12)
	progress_label.add_theme_color_override("font_color", Color.WHITE)
	progress_label.add_theme_color_override("font_outline_color", Color.BLACK)
	progress_label.add_theme_constant_override("outline_size", 3)
	
	progress_label.position = Vector2(-25, -35)
	progress_label.size = Vector2(50, 25)
	
	add_child(progress_label)
	_update_progress_display()
	
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
		# CRITICAL FIX: Station is available if it's not animating and not already full
		return not _is_animating and not _recipe_completed
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
		# CRITICAL FIX: Don't accept items while animating
		if _is_animating:
			print("[STATION] ❌ '%s' is animating completion, try again soon" % name)
			return false
		
		# Validate recipe match
		if recipe_id != "" and incoming_recipe_id != "" and incoming_recipe_id != recipe_id:
			print("[STATION] ❌ '%s' rejected ingredient (expected: %s, got: %s)" % 
				[name, recipe_id, incoming_recipe_id])
			return false
		
		# Don't accept more if recipe already completed
		if _recipe_completed:
			print("[STATION] ❌ '%s' recipe already completed, not accepting more" % name)
			return false
		
		# Verify we still need this ingredient
		if served_ingredients.size() >= _get_required_count():
			print("[STATION] ❌ '%s' already has enough ingredients (%d/%d)" % 
				[name, served_ingredients.size(), _get_required_count()])
			return false
		
		# NEW: Validation with special handling for cooked_veggies
		if typeof(it) == TYPE_OBJECT and it is Node:
			var base_type = _get_base_ingredient_type(it)
			
			# Special case: cooked_veggies can count as any veggie ingredient
			if base_type == "veggies":
				if not _can_accept_veggie(incoming_recipe_id if incoming_recipe_id != "" else recipe_id):
					print("[STATION] ❌ '%s' already has all required veggies for recipe '%s'" % 
						[name, incoming_recipe_id if incoming_recipe_id != "" else recipe_id])
					return false
			else:
				# Normal validation for other ingredients
				# Count how many of this type we already have
				var count_of_type = 0
				for existing in served_ingredient_types:
					if existing == base_type:
						count_of_type += 1
				
				# Get recipe requirements
				var gm = _ensure_gm()
				if gm and gm.has_method("get_recipe_ingredients"):
					var required = gm.get_recipe_ingredients(incoming_recipe_id if incoming_recipe_id != "" else recipe_id)
					
					# Count how many of this type the recipe needs
					var needed_count = 0
					for req in required:
						if req == base_type:
							needed_count += 1
					
					# Reject if we already have enough of this type
					if count_of_type >= needed_count:
						print("[STATION] ❌ '%s' already has enough '%s' (%d/%d needed)" % 
							[name, base_type, count_of_type, needed_count])
						return false
			
			_add_ingredient_to_serving(it, base_type)
			print("[STATION] 🍽️ Added to '%s' (recipe: %s): %s (%d/%d)" % 
				[name, recipe_id, it.name, served_ingredients.size(), _get_required_count()])
			return true
		return false
	
	# Other stations (Chopping, Cooking): only hold one item at a time
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

func _get_base_ingredient_type(ingredient_node: Node) -> String:
	"""Extract the base ingredient type (remove chopped_, cooked_ prefixes)"""
	var ingredient_type = ""
	if ingredient_node.has_method("get_type"):
		ingredient_type = ingredient_node.get_type()
	elif "type" in ingredient_node:
		ingredient_type = ingredient_node.type
	
	# Strip prefixes to get base type
	var base_type = ingredient_type
	if base_type.begins_with("chopped_"):
		base_type = base_type.substr(8)
	elif base_type.begins_with("cooked_"):
		base_type = base_type.substr(7)
	
	# Normalize olive/olives (they're the same ingredient)
	if base_type == "olives":
		base_type = "olive"
	
	return base_type

func _can_accept_veggie(check_recipe_id: String) -> bool:
	"""Check if we can accept another cooked_veggies ingredient for this recipe"""
	var gm = _ensure_gm()
	if not gm or not gm.has_method("get_recipe_ingredients"):
		return true  # Can't validate, allow it
	
	var required = gm.get_recipe_ingredients(check_recipe_id)
	
	# Count how many veggie ingredients the recipe needs (carrot, onion, broccoli, etc.)
	var veggie_types = ["carrot", "onion", "broccoli"]
	var needed_veggies = 0
	for req in required:
		if req in veggie_types:
			needed_veggies += 1
	
	# Count how many cooked_veggies we already have
	var current_veggies = 0
	for existing_type in served_ingredient_types:
		if existing_type == "veggies" or existing_type in veggie_types:
			current_veggies += 1
	
	return current_veggies < needed_veggies

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

func _add_ingredient_to_serving(ing: Node, base_type: String) -> void:
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
	served_ingredient_types.append(base_type)  # Track the type
	
	if ing.has_method("drop_at"):
		ing.drop_at(self)
	
	_update_progress_display()
	
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
		_recipe_completed = true
		_is_animating = true  # CRITICAL FIX: Mark as animating
		print("[STATION] 🎉 Recipe '%s' complete on '%s'! Serving %d ingredients..." % 
			[recipe_id, name, served_ingredients.size()])
		
		# Notify GM (it will find the right timer automatically)
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
	served_ingredient_types.clear()  # Clear the types too
	current_item = ""
	_recipe_completed = false
	_is_animating = false  # CRITICAL FIX: Animation finished
	update_appearance()
	_update_progress_display()
	print("[STATION] ✅ Dish '%s' served from '%s' - station ready for next order!" % [recipe_id, name])

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

func _update_progress_display() -> void:
	"""Update the progress bar display"""
	if not progress_label or station_type != "Serving":
		return
	
	var required = _get_required_count()
	var current = served_ingredients.size()
	
	if required == 0:
		progress_label.text = ""
		return
	
	var filled = "•" if current >= 1 else "_"
	var filled2 = "•" if current >= 2 else "_"
	var filled3 = "•" if current >= 3 else "_"
	var filled4 = "•" if current >= 4 else "_"
	
	match required:
		1:
			progress_label.text = "(%s)" % filled
		2:
			progress_label.text = "(%s%s)" % [filled, filled2]
		3:
			progress_label.text = "(%s%s%s)" % [filled, filled2, filled3]
		4:
			progress_label.text = "(%s%s%s%s)" % [filled, filled2, filled3, filled4]
		_:
			progress_label.text = "%d/%d" % [current, required]

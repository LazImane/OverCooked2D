extends Node2D

@export var type: String = ""
var status: String = "raw"
var _gm: Node = null
var _scale_override: Vector2 = Vector2.ZERO

@onready var sprite: Sprite2D = $Sprite2D

const ICONS := {
	"tomato": preload("res://assets/ingredients/tomato.png"),
	"chopped_tomato": preload("res://assets/ingredients/chopped_tomato.png"),
	"chopped_lettuce": preload("res://assets/ingredients/chopped_lettuce.png"),
	"chopped_cucumber": preload("res://assets/ingredients/chopped_cucumber.png"),
	"chopped_olives": preload("res://assets/ingredients/chopped_olives.png"),
	"chopped_olive": preload("res://assets/ingredients/chopped_olives.png"),  # Alias for single olive
	"cooked_tomato": preload("res://assets/ingredients/pot.png"),
	"cooked_olives": preload("res://assets/ingredients/chopped_olives.png"),  # You can change this if you have a different cooked olive icon
	"cooked_olive": preload("res://assets/ingredients/chopped_olives.png"),  # Alias
	"tomato_soup": preload("res://assets/ingredients/tomato_soup.png"),
	"lettuce": preload("res://assets/ingredients/lettuce.png"),
	"cucumber": preload("res://assets/ingredients/cucumber.png"),
	"olives": preload("res://assets/ingredients/olives.png"),
	"olive": preload("res://assets/ingredients/olives.png"),
	"salad": preload("res://assets/ingredients/salad.png")
}

# Scale adjustments per texture (relative to base scale)
const TEXTURE_SCALES := {
	"tomato": 1.0,              # Tomatoes are already good size
	"chopped_tomato": 1.0,
	"cooked_tomato": 1.0,
	"tomato_soup": 1.0,
	"lettuce": 0.7,             # Lettuce is too big
	"chopped_lettuce": 0.7,
	"cucumber": 0.7,            # Cucumber is too big
	"chopped_cucumber": 0.7,
	"olives": 0.8,              # Olives slightly too big
	"olive": 0.8,
	"chopped_olives": 0.8,
	"chopped_olive": 0.8,
	"cooked_olives": 0.8,
	"cooked_olive": 0.8,
	"salad": 1.0                # Final salad
}

func _ready() -> void:
	_gm = get_tree().get_first_node_in_group("game_manager")
	
	# Initialize visual
	update_visual()
	print("[INGREDIENT] Created: type='%s', status='%s', visible=%s" % [type, status, sprite.visible if sprite else false])

func set_type(t: String) -> void:
	type = t
	
	# Infer status from type name
	if type.begins_with("chopped_"):
		status = "chopped"
	elif type.begins_with("cooked_"):
		status = "cooked"
	elif type.ends_with("_soup") or type == "salad":
		status = "served"
	else:
		status = "raw"
	
	print("[INGREDIENT] set_type('%s') -> status='%s'" % [type, status])
	update_visual()

func get_type() -> String:
	return type

func set_scale_override(new_scale: Vector2) -> void:
	"""Allow external code to override the scale"""
	_scale_override = new_scale
	update_visual()

func update_visual() -> void:
	if not sprite:
		push_error("[INGREDIENT] Sprite2D node missing!")
		return
	
	# Make sure sprite is visible and has proper modulate
	sprite.visible = true
	sprite.modulate = Color(1, 1, 1, 1)
	
	var tex = ICONS.get(type, null)
	if tex:
		sprite.texture = tex
		print("[INGREDIENT] Visual updated: type='%s', texture loaded" % type)
	else:
		# Try base name fallback
		var base := _base_name(type)
		var tex2 = ICONS.get(base, null)
		if tex2:
			sprite.texture = tex2
			print("[INGREDIENT] Visual updated: base='%s', texture loaded" % base)
		else:
			# Show a placeholder
			sprite.visible = true
			push_warning("[INGREDIENT] No texture for '%s' or '%s' - sprite visible but no texture" % [type, base])
	
	# Apply appropriate scale
	_apply_scale()

func _apply_scale() -> void:
	"""Apply scale based on texture type"""
	# Start with base scale
	var base_scale = Vector2(0.1, 0.1)
	
	# Get texture-specific scale multiplier
	var scale_mult = TEXTURE_SCALES.get(type, 1.0)
	
	# Apply the multiplier
	var final_scale = base_scale * scale_mult
	
	# Use override if set
	if _scale_override != Vector2.ZERO:
		final_scale = _scale_override
	
	scale = final_scale
	print("[INGREDIENT] Scale set: %v (type: %s, mult: %.2f)" % [final_scale, type, scale_mult])

func _base_name(t: String) -> String:
	if t.begins_with("chopped_"):
		return t.substr(8)
	elif t.begins_with("cooked_"):
		return t.substr(7)
	return t

func apply_stage(stage: String) -> void:
	var base := _base_name(type)
	
	match stage:
		"Chopping":
			if status == "raw":
				status = "chopped"
				type = "chopped_%s" % base
				print("[INGREDIENT] Chopped: %s" % type)
		
		"Cooking":
			if status in ["raw", "chopped"]:
				status = "cooked"
				# For olives, keep them as chopped_olives visually (or use a different cooked texture if you have one)
				if base == "olive" or base == "olives":
					type = "cooked_olives"
				else:
					type = "cooked_%s" % base
				print("[INGREDIENT] Cooked: %s" % type)
		
		"Serving":
			if base == "tomato" or type.find("tomato") != -1:
				status = "served"
				type = "tomato_soup"
				print("[INGREDIENT] Served as soup")
			else:
				status = "served"
				type = "salad"
				print("[INGREDIENT] Served as salad")
		
		_:
			push_warning("[INGREDIENT] Unknown stage: %s" % stage)
	
	update_visual()

func pick_up(by_node: Node, offset: Vector2 = Vector2(0, -16)) -> void:
	var old_parent = get_parent()
	if old_parent:
		old_parent.remove_child(self)
	
	by_node.add_child(self)
	position = offset
	
	# Re-apply scale after reparenting
	_apply_scale()
	
	if has_node("CollisionShape2D"):
		$CollisionShape2D.disabled = true
	
	print("[INGREDIENT] Picked up by %s (pos: %v)" % [by_node.name, position])

func drop_at(station: Node) -> void:
	var old_parent = get_parent()
	if old_parent:
		old_parent.remove_child(self)
	
	station.add_child(self)
	position = Vector2.ZERO
	
	# Re-apply scale after reparenting
	_apply_scale()
	
	if has_node("CollisionShape2D"):
		$CollisionShape2D.disabled = false
	
	print("[INGREDIENT] Dropped at %s" % station.name)

func can_process_at(stage: String) -> bool:
	match stage:
		"Chopping":
			return status == "raw"
		"Cooking":
			return status in ["raw", "chopped"]
		"Serving":
			return status in ["raw", "chopped", "cooked"]
	return false

func get_display_name() -> String:
	if _gm and _gm.has_method("get_ingredient_name"):
		var base := _base_name(type)
		return _gm.get_ingredient_name(base)
	return type.capitalize()

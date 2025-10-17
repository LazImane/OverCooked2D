extends Node2D

@export var type: String = ""        # ex: "tomato", "chopped_tomato", "cooked_tomato"
var status: String = "raw"           # "raw", "chopped", "cooked", "served"
var _gm: Node = null
var _local_idx: int = 0

@onready var sprite: Sprite2D = $Sprite2D

# Updated textures to match your assets
const ICONS := {
	"tomato": preload("res://assets/ingredients/tomato.png"),
	"chopped_tomato": preload("res://assets/ingredients/chopped_tomato.png"),
	"cooked_tomato": preload("res://assets/ingredients/pot.png"),
	"tomato_soup": preload("res://assets/ingredients/tomato_soup.png"),
	#"lettuce": preload("res://assets/ingredients/lettuce.png"),
	#"cucumber": preload("res://assets/ingredients/cucumber.png"),
}

func _ready() -> void:
	_gm = get_tree().get_first_node_in_group("game_manager")
	if type == "":
		spawn_from_recipe("demo_salad")
	scale = Vector2(0.1, 0.1)
	update_visual()


# --- récupération d'un base_item depuis le GameManager (prévu: demo_salad) ---
func spawn_from_recipe(recipe_name: String = "demo_salad") -> void:
	if _gm and _gm.has_method("next_base_item"):
		var id := String(_gm.next_base_item())
		if id != "":
			set_type(id)
			return

	if _gm and typeof(_gm.get("recipes")) == TYPE_DICTIONARY:
		var rec = _gm.get("recipes").get(recipe_name, null)
		if typeof(rec) == TYPE_DICTIONARY:
			var base_items: Array = rec.get("base_items", [])
			if base_items.size() > 0:
				var id2 := String(base_items[_local_idx % base_items.size()])
				_local_idx += 1
				set_type(id2)
				return

	set_type("tomato")  # fallback


# --- met à jour le type + status puis l'apparence ---
func set_type(t: String) -> void:
	type = t
	if type.begins_with("chopped_"):
		status = "chopped"
	elif type.begins_with("cooked_"):
		status = "cooked"
	elif type.ends_with("_soup"):
		status = "served"
	else:
		status = "raw"
	update_visual()


func update_visual() -> void:
	if not sprite:
		return
	var tex = ICONS.get(type, null)
	if tex:
		sprite.texture = tex
		sprite.visible = true
	else:
		var base := _base_name(type)
		var tex2 = ICONS.get(base, null)
		if tex2:
			sprite.texture = tex2
			sprite.visible = true
		else:
			sprite.visible = false


func _base_name(t: String) -> String:
	if t.find("_") != -1:
		return t.substr(t.find("_") + 1)
	return t


# --- transforme l'ingrédient selon l'étape d'une station (appelé par la station) ---
# stage ex: "Chopping", "Cooking", "Serving"
func apply_stage(stage: String) -> void:
	match stage:
		"Chopping":
			if status == "raw":
				status = "chopped"
				type = "chopped_%s" % _base_name(type)

		"Cooking":
			# cooking accepte raw ou chopped -> cooked
			if status in ["raw", "chopped"]:
				status = "cooked"
				type = "cooked_%s" % _base_name(type)

		"Serving":
			# Only transform to soup if it’s a tomato-based item
			if _base_name(type) == "tomato" or type.ends_with("tomato"):
				status = "served"
				type = "tomato_soup"
			else:
				# Not a soup recipe → generic serving
				status = "served"

		_:
			pass

	update_visual()


# --- helpers pour que le Bot / Station puissent "prendre" / "poser" l'instance visuelle ---
func pick_up(by_node: Node, offset: Vector2 = Vector2(0, -16)) -> void:
	var old_parent = get_parent()
	if old_parent:
		old_parent.remove_child(self)
	by_node.add_child(self)
	global_position = global_position
	position = offset
	if has_node("CollisionShape2D"):
		$CollisionShape2D.disabled = true


func drop_at(station: Node) -> void:
	var old_parent = get_parent()
	if old_parent:
		old_parent.remove_child(self)
	station.add_child(self)
	global_position = station.global_position
	position = Vector2.ZERO
	if has_node("CollisionShape2D"):
		$CollisionShape2D.disabled = false

extends Node2D

var bot_scene = preload("res://scenes/bot.tscn")

# Spawn positions for ADDITIONAL bots beyond the 5 hardcoded ones
var extra_spawn_positions = [
	Vector2(-50, 30),
	Vector2(50, 30),
	Vector2(-100, -30),
	Vector2(100, -30),
	Vector2(0, -60),
]

func _ready() -> void:
	# Load desired bot count from config
	var config = ConfigFile.new()
	var desired_bot_count = 5  # Default
	
	if config.load("user://game_settings.cfg") == OK:
		desired_bot_count = config.get_value("game", "bot_count", 5)
	
	# Count existing bots in the scene (Bot, Bot2, Bot3, Bot4, Bot5)
	var existing_bots = []
	for child in get_children():
		if child.is_in_group("bots"):
			existing_bots.append(child)
	
	var existing_count = existing_bots.size()
	print("[GAME] Found %d existing bots, need %d total" % [existing_count, desired_bot_count])
	
	# If we need MORE bots, spawn them
	if desired_bot_count > existing_count:
		var bots_to_spawn = desired_bot_count - existing_count
		print("[GAME] Spawning %d additional bots" % bots_to_spawn)
		spawn_additional_bots(bots_to_spawn, existing_count)
	
	# If we need FEWER bots, remove extras
	elif desired_bot_count < existing_count:
		var bots_to_remove = existing_count - desired_bot_count
		print("[GAME] Removing %d extra bots" % bots_to_remove)
		for i in range(bots_to_remove):
			existing_bots[existing_count - 1 - i].queue_free()
	
	# Assign collision layers to ALL bots
	await get_tree().process_frame
	assign_collision_layers()
	
	var final_count = get_tree().get_nodes_in_group("bots").size()
	print("[GAME] ✅ Final bot count: %d" % final_count)

func spawn_additional_bots(count: int, start_id: int) -> void:
	for i in range(count):
		var bot = bot_scene.instantiate()
		var bot_id = start_id + i + 1
		bot.bot_id = bot_id
		bot.name = "Bot_%d" % bot_id
		
		# Use extra spawn positions
		var pos_index = i % extra_spawn_positions.size()
		bot.position = extra_spawn_positions[pos_index]
		
		add_child(bot)
		print("[GAME] Spawned bot %d at %v" % [bot_id, bot.position])

func assign_collision_layers() -> void:
	# Assign unique collision layer to each bot
	var all_bots = get_tree().get_nodes_in_group("bots")
	for i in range(all_bots.size()):
		var bot = all_bots[i]
		var layer_bit = i + 1
		bot.collision_layer = 1 << (layer_bit - 1)
		bot.collision_mask = 1  # Only collide with environment

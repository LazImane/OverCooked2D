extends Node2D

func _ready():
	pass

func _process(delta):
	pass

func _on_one_agent_pressed() -> void:
	start_game_with_bots(1)

func _on_two_agents_pressed() -> void:
	start_game_with_bots(2)

func _on_three_agents_pressed() -> void:
	start_game_with_bots(3)
	
func _on_four_agents_pressed() -> void:
	start_game_with_bots(4)

func _on_five_agents_pressed() -> void:
	start_game_with_bots(5)

func start_game_with_bots(bot_count: int) -> void:
	# Save the bot count to a file
	var config = ConfigFile.new()
	config.set_value("game", "bot_count", bot_count)
	config.save("user://game_settings.cfg")
	
	print("[MENU] Starting game with %d bots" % bot_count)
	
	# Change to game scene
	get_tree().change_scene_to_file("res://scenes/game.tscn")

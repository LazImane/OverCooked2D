extends CharacterBody2D

enum Act {
	MOVE_TO_STATION, TAKE_ITEM, PLACE_ITEM, PROCESS, NONE
}

@export var bot_id := 1
@export var speed := 70.0
@export var accel := 800.0
@export var stop_distance := 50.0

var _gm: Node = null
var _current_task: Dictionary = {}
var _current_station: Node = null
var _next_station_type: String = ""

var I := {
	"target": Vector2.ZERO,
	"carrying": "",
	"phase": "idle"  # idle, moving, processing, complete
}

@onready var sprite = $Sprite2D
@onready var navigation_agent = $NavigationAgent2D

func _ready() -> void:
	_gm = get_tree().get_first_node_in_group("game_manager")
	if not _gm:
		push_error("Bot: GameManager not found!")
		set_physics_process(false)
		return
	
	print("[BOT", bot_id, "] ready, requesting task from GameManager")
	_request_new_task()
	
	navigation_agent.target_desired_distance = stop_distance
	navigation_agent.path_desired_distance = stop_distance

func _physics_process(delta: float) -> void:
	var per := see()
	next(I, per)
	var a: Act = action(I, per)
	
	# Debug output
	if _current_task and not _current_task.is_empty():
		var step: int = _current_task.get("current_step", -1)
		var flow: Array = _current_task.get("flow", [])
		var flow_str: String = str(flow[step]) if step >= 0 and step < flow.size() else "DONE"
		if Engine.get_frames_drawn() % 60 == 0:  # Print every 60 frames
			print("[BOT", bot_id, "] Item:", _current_task.get("item", "?"), 
				  " | Step:", step, "/", flow.size(), " (", flow_str, ")",
				  " | Phase:", I.phase, " | Carrying:", I.carrying,
				  " | Action:", Act.keys()[a])
	
	act(a, delta)
	
	if sprite and velocity.x != 0:
		sprite.flip_h = velocity.x < 0
	
	move_and_slide()

# === TASK MANAGEMENT ===
func _request_new_task() -> void:
	_current_task = _gm.request_task(bot_id)
	
	if _current_task.is_empty():
		print("[BOT", bot_id, "] No tasks available. Idling.")
		I.phase = "idle"
		return
	
	print("[BOT", bot_id, "] Got task:", _current_task["item"], "flow:", _current_task["flow"])
	
	# Always start by going to Ingredient station to pick up the item
	_next_station_type = "Ingredient"
	_current_station = _gm.get_station_for_type("Ingredient")
	if _current_station:
		I.target = _current_station.global_position
		I.phase = "moving"

func _advance_to_next_step() -> void:
	"""Move to the next step in the current task"""
	_gm.advance_task_step(bot_id)
	_next_station_type = _gm.get_next_step_for_task(_current_task)
	
	if _next_station_type == "":
		# Task complete!
		print("[BOT", bot_id, "] Task complete:", _current_task["item"])
		_gm.complete_task(bot_id)
		_current_task = {}
		_request_new_task()
	else:
		# Go to next station
		_current_station = _gm.get_station_for_type(_next_station_type)
		if _current_station:
			I.target = _current_station.global_position
			I.phase = "moving"
			print("[BOT", bot_id, "] Moving to next station:", _next_station_type)

# === PERCEPTION ===
func see() -> Dictionary:
	var near_station := false
	if _current_station:
		near_station = global_position.distance_to(_current_station.global_position) <= stop_distance
	
	return {
		"bot_pos": global_position,
		"near_station": near_station,
		"station_has_item": _station_has_item(_current_station) if _current_station else false,
	}

# === DECISION MAKING ===
func next(state: Dictionary, per: Dictionary) -> void:
	if _current_station and state.phase == "moving":
		state.target = _current_station.global_position

func action(state: Dictionary, per: Dictionary) -> Act:
	if state.phase == "idle":
		return Act.NONE
	
	if not _current_task or _current_task.is_empty():
		return Act.NONE
	
	match state.phase:
		"moving":
			if per.near_station:
				state.phase = "processing"
				return action(state, per)  # Immediately process next action
			return Act.MOVE_TO_STATION
		
		"processing":
			return _decide_station_action(per)
		
		_:
			return Act.NONE

func _decide_station_action(per: Dictionary) -> Act:
	"""Decide what to do at the current station"""
	
	match _next_station_type:
		"Ingredient":
			# Take ingredient from source
			if I.carrying == "":
				return Act.TAKE_ITEM
			else:
				# Already carrying, move to next step
				_advance_to_next_step()
				return Act.MOVE_TO_STATION
		
		"Chopping", "Cooking":
			# Place item if carrying and station empty
			if I.carrying != "" and not per.station_has_item:
				return Act.PLACE_ITEM
			# Process if station has item and we're not carrying
			elif per.station_has_item and I.carrying == "":
				return Act.PROCESS
			# If we're carrying but station has item, wait (shouldn't happen with coordination)
			elif I.carrying != "" and per.station_has_item:
				print("[BOT", bot_id, "] WARNING: Station busy, waiting...")
				return Act.NONE
			# Try to take if something went wrong
			else:
				return Act.TAKE_ITEM
		
		"Serving":
			# Clear station if it has something and we're also carrying
			if per.station_has_item and I.carrying != "":
				_call_interact(_current_station)  # Clear it first
				print("[BOT", bot_id, "] Cleared Serving station")
				return Act.NONE  # Next frame we'll place ours
			# Place our item if carrying
			elif I.carrying != "":
				return Act.PLACE_ITEM
			# Station has our item (we just placed), serve it
			elif per.station_has_item:
				return Act.PROCESS
			else:
				# Task complete
				_advance_to_next_step()
				return Act.NONE
		
		_:
			return Act.NONE

# === ACTIONS ===
func act(a: Act, delta: float) -> void:
	match a:
		Act.MOVE_TO_STATION:
			_seek(I.target, delta)
		
		Act.TAKE_ITEM:
			if _next_station_type == "Ingredient":
				# Spawn the ingredient we need
				var want := String(_current_task.get("item", ""))
				_set_current_item(_current_station, want)
				print("[BOT", bot_id, "] Spawned ingredient:", want)
			
			# Take the item
			_call_interact(_current_station)
			var taken := _take_item_from(_current_station)
			if taken != "":
				I.carrying = taken
				print("[BOT", bot_id, "] Took:", I.carrying, "from", _next_station_type)
				
				# If we just took from Ingredient, move to FIRST processing step (index 0)
				if _next_station_type == "Ingredient":
					_next_station_type = _gm.get_next_step_for_task(_current_task)
					_current_station = _gm.get_station_for_type(_next_station_type)
					if _current_station:
						I.target = _current_station.global_position
						I.phase = "moving"
						print("[BOT", bot_id, "] Now heading to:", _next_station_type)
		
		Act.PLACE_ITEM:
			if I.carrying != "" and _current_station:
				if _place_item_on(_current_station, I.carrying):
					print("[BOT", bot_id, "] Placed:", I.carrying, "on", _next_station_type)
					I.carrying = ""
					
					# If this is Serving, immediately process
					if _next_station_type == "Serving":
						I.phase = "processing"
		
		Act.PROCESS:
			if _current_station:
				_call_interact(_current_station)
				print("[BOT", bot_id, "] Processed at", _next_station_type)
				
				# Take back the processed item (except for Serving)
				if _next_station_type != "Serving":
					var taken := _take_item_from(_current_station)
					if taken != "":
						I.carrying = taken
						print("[BOT", bot_id, "] Retrieved:", I.carrying)
				else:
					# Serving consumed the item
					I.carrying = ""
				
				# Move to next step
				_advance_to_next_step()
		
		Act.NONE:
			velocity = velocity.move_toward(Vector2.ZERO, accel * delta)

# === MOVEMENT ===
func _seek(target: Vector2, delta: float) -> void:
	var to_target: Vector2 = target - global_position
	var desired: Vector2 = (to_target.normalized() * speed) if to_target.length() > 0.001 else Vector2.ZERO
	if to_target.length() <= stop_distance:
		velocity = velocity.move_toward(Vector2.ZERO, accel * delta)
	else:
		velocity = velocity.move_toward(desired, accel * delta)

# === STATION HELPERS ===
func _call_interact(s: Node) -> void:
	if s and s.has_method("interact"): s.interact()

func _station_has_item(s: Node) -> bool:
	if not s: return false
	if "current_item" in s: return s.current_item != ""
	return false

func _get_current_item(s: Node) -> String:
	if not s: return ""
	if "current_item" in s: return String(s.current_item)
	return ""

func _set_current_item(s: Node, v: String) -> void:
	if not s: return
	if "current_item" in s:
		s.current_item = v
		if s.has_method("update_appearance"): s.update_appearance()

func _take_item_from(s: Node) -> String:
	if not s: return ""
	if s.has_method("take_item"): return String(s.take_item())
	var cur := _get_current_item(s)
	if cur != "": _set_current_item(s, "")
	return cur

func _place_item_on(s: Node, it: String) -> bool:
	if not s: return false
	if s.has_method("place_item"): return bool(s.place_item(it))
	if _get_current_item(s) == "":
		_set_current_item(s, it)
		return true
	return false

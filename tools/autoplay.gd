## Автоигрок для проверки прототипа (локально и в CI).
## Запуск: godot --path . -- --autoplay [--shots=папка]
## Щиплет струны рядом с кристаллами До, Ми, Соль, снимает кадры и выходит
## с кодом 0, если Сердце пробудилось, иначе с кодом 1.
extends Node

var main: Node
var shots_dir := ""
var t := 0.0
var step := 0

# Время (с), нота, точка (норм. координаты) — центр струны.
var plan := [
	[0.6, 60, Vector2(0.30, 0.86)], # До4 у кристалла До4
	[1.4, 64, Vector2(0.70, 0.82)], # Ми4 у кристалла Ми4
	[2.2, 67, Vector2(0.50, 0.68)], # Соль4 у кристалла Соль4
]
var shots := [1.0, 1.9, 2.8, 3.6, 4.6]
var shot_i := 0
var done := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			shots_dir = a.trim_prefix("--shots=")
			DirAccess.make_dir_recursive_absolute(shots_dir)


func _process(delta: float) -> void:
	t += delta
	if step < plan.size() and t >= plan[step][0]:
		_pluck(plan[step][1], plan[step][2])
		step += 1
	if shots_dir != "" and shot_i < shots.size() and t >= shots[shot_i]:
		var img := get_viewport().get_texture().get_image()
		img.save_png("%s/shot_%d.png" % [shots_dir, shot_i])
		shot_i += 1
	if not done and (main.won or t > 9.0):
		done = true
		print("AUTOPLAY: won=%s plucks=%d t=%.1f" % [main.won, main.plucks, t])
		if shots_dir != "" and main.won:
			await get_tree().create_timer(0.6).timeout
			get_viewport().get_texture().get_image().save_png("%s/shot_won.png" % shots_dir)
		get_tree().quit(0 if main.won else 1)


## Струна нужной длины (обратная формула из main._current_midi).
func _pluck(midi: int, center_n: Vector2) -> void:
	var freq := 440.0 * pow(2.0, (midi - 69) / 12.0)
	var length: float = 130.81 * main.world.y * 0.55 / freq
	var c: Vector2 = center_n * main.world
	var half := Vector2(length * 0.5, 0).rotated(-0.35)
	main.drag_start = c - half
	main.drag_end = c + half
	main.press_time = main.now - 0.8
	var got: int = main._current_midi()
	if got != midi:
		push_error("AUTOPLAY: ожидали ноту %d, получили %d" % [midi, got])
	main._release()

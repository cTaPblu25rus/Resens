## Автоигрок: проходит ВСЕ уровни по эталонным решениям из levels/levels.json.
## Запуск: godot --headless --path . -- --autoplay [--shots=папка] [--level=N]
## Код выхода 0 — все уровни проходимы, 1 — какой-то уровень не пройден.
##
## Шаг решения:
##   {"t": 0.6, "m": 60, "p": [x, y]}       — щипок ноты m с центром в p
##   {"t": 0.5, "target": 0, "p": [x, y]}   — удар по Глушителю №0: автоигрок сам
##       выбирает ноту, которую Глушитель будет иметь в момент прихода волны.
extends Node

const LEVEL_TIMEOUT := 14.0
const SHOT_TIMES := [1.2, 2.6, 4.0]

var main: Node
var shots_dir := ""
var only_level := -1
var t := 0.0
var step := 0
var shot_i := 0
var failed: Array[String] = []
var finishing := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shots="):
			shots_dir = a.trim_prefix("--shots=")
			DirAccess.make_dir_recursive_absolute(shots_dir)
		elif a.begins_with("--level="):
			only_level = int(a.trim_prefix("--level="))
	_start(only_level if only_level >= 0 else 0)


func _start(i: int) -> void:
	main.load_level(i)
	t = 0.0
	step = 0
	shot_i = 0
	finishing = false


func _process(delta: float) -> void:
	if finishing:
		return
	t += delta
	var sol: Array = main.level.get("solution", [])
	if step < sol.size() and t >= float(sol[step].t):
		_do(sol[step])
		step += 1
	if shots_dir != "" and shot_i < SHOT_TIMES.size() and t >= SHOT_TIMES[shot_i]:
		_shot("L%d_%d" % [main.level_i + 1, shot_i])
		shot_i += 1
	if main.won or t > LEVEL_TIMEOUT:
		finishing = true
		_finish_level()


func _finish_level() -> void:
	var name: String = main.level.name
	print("AUTOPLAY: Тишь %d «%s»: won=%s щипков=%d t=%.1f" % [main.level_i + 1, name, main.won, main.plucks, t])
	if not main.won:
		failed.append(name)
	if shots_dir != "" and main.won:
		await get_tree().create_timer(0.6).timeout
		_shot("L%d_won" % (main.level_i + 1))
	var next: int = main.level_i + 1
	if only_level < 0 and next < main.levels.size():
		_start(next)
		return
	if failed.is_empty():
		print("AUTOPLAY: все уровни пройдены")
	else:
		print("AUTOPLAY: НЕ пройдены: %s" % ", ".join(failed))
	get_tree().quit(0 if failed.is_empty() else 1)


func _shot(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [shots_dir, name])


func _do(s: Dictionary) -> void:
	var center: Vector2 = main._v(s.p) * main.world
	var midi: int
	if s.has("target"):
		var mf: Dictionary = main.mufflers[int(s.target)]
		var arrival: float = main.now + center.distance_to(mf.pos) / main.WAVE_SPEED
		midi = _nearest_playable(main.muffler_note(mf, arrival))
	else:
		midi = int(s.m)
	_pluck(midi, center)


## Нота Глушителя может быть вне лада уровня — берём её же в другой октаве, если надо.
func _nearest_playable(m: int) -> int:
	for cand in [m, m + 12, m - 12]:
		if cand >= main.MIN_MIDI and cand <= main.MAX_MIDI and main.note_scale.has(cand % 12):
			return cand
	return m


func _pluck(midi: int, center: Vector2) -> void:
	var length: float = main.length_for_midi(midi)
	var half := Vector2(length * 0.5, 0)
	main.drag_start = center - half
	main.drag_end = center + half
	main.press_time = main.now - 0.8
	var got: int = main._current_midi()
	if got != midi:
		push_error("AUTOPLAY: ожидали ноту %d, получили %d" % [midi, got])
	main._release()

## Тактильная отдача RESONA.
## Прототип использует Input.vibrate_handheld (длительность + амплитуда, Godot 4.3+).
## Следующий шаг — Android-плагин с VibrationEffect.Composition (LOW_TICK, THUD...).
extends RefCounted

var enabled := true


func _ok() -> bool:
	return enabled and OS.has_feature("mobile")


## «Тактильный лад»: щелчок на каждый полутон, пока тянешь струну.
func fret_tick() -> void:
	if _ok():
		Input.vibrate_handheld(8, 0.25)


## Щипок: сила отдачи = сила ноты.
func pluck(strength: float) -> void:
	if _ok():
		Input.vibrate_handheld(int(18.0 + 30.0 * strength), clampf(0.35 + 0.65 * strength, 0.0, 1.0))


## Кристалл ответил резонансом.
func resonance() -> void:
	if _ok():
		Input.vibrate_handheld(14, 0.35)


## Сердце пробудилось.
func heart() -> void:
	if _ok():
		Input.vibrate_handheld(260, 1.0)

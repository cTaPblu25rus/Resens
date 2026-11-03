## RESONA — вертикальный срез.
##
## Коснись и тяни: длина струны = высота ноты (длиннее — ниже).
## Отпусти: звуковая волна расходится по тёмному миру и подсвечивает его.
## Кристаллы звучат в ответ, если волна совпала с их нотой (унисон/октава — сильно,
## квинта/кварта — слабо). Их голоса будят другие кристаллы — цепная реакция.
## Сердце слышит только голос мира: его аккорд должны спеть кристаллы, и их волны
## должны дойти до Сердца в пределах HEART_WINDOW секунд.
##
## Уровни описаны в levels/levels.json (см. docs/LEVELS.md).
extends Control

const Synth := preload("res://scripts/synth.gd")
const Haptics := preload("res://scripts/haptics.gd")
const WaveShader := preload("res://shaders/waves.gdshader")

const LEVELS_PATH := "res://levels/levels.json"
const PROGRESS_PATH := "user://progress.cfg"

const MAX_WAVES := 24
const MAX_MUFFLERS := 4
const WAVE_SPEED := 420.0
const WAVE_LIFETIME := 4.5
const FULL_SCALE := [0, 2, 4, 5, 7, 9, 11] # До мажор
const NOTE_NAMES := ["До", "До♯", "Ре", "Ре♯", "Ми", "Фа", "Фа♯", "Соль", "Соль♯", "Ля", "Ля♯", "Си"]
const MIN_MIDI := 48 # До3
const MAX_MIDI := 84 # До6
const RESONANCE_THRESHOLD := 0.075
const HEART_THRESHOLD := 0.1
const MUFFLER_THRESHOLD := 0.06
const HEART_WINDOW := 3.5
const CRYSTAL_COOLDOWN := 2.0
const SRC_PLAYER := -1
const SRC_HEART := -2
const SRC_MUFFLER := -3

var synth := Synth.new()
var haptics := Haptics.new()

var levels: Array = []
var level_i := 0
var level: Dictionary = {}
var note_scale: Array = FULL_SCALE
var zone := Vector2(0.0, 1.0) # допустимая полоса струн по Y (нормализованно)
var autoplay := false

var waves: Array[Dictionary] = []
var crystals: Array[Dictionary] = []
var mufflers: Array[Dictionary] = []
var echoes: Array[Dictionary] = [] # дрожащие отпущенные струны
var heart := {}

var now := 0.0
var world := Vector2(720, 1280)
var wave_mat: ShaderMaterial
var overlay: Control
var hint: Label
var result: Label
var title: Label

var active_touch := -1
var drag_start := Vector2.ZERO
var drag_end := Vector2.ZERO
var press_time := 0.0
var last_midi := -1

var plucks := 0
var level_start := 0.0
var won := false
var won_at := 0.0

var players: Array[AudioStreamPlayer] = []
var next_player := 0


func _ready() -> void:
	autoplay = OS.get_cmdline_user_args().has("--autoplay")
	_build_scene()
	_build_audio()
	_load_levels()
	load_level(0 if autoplay else _load_progress())
	var all_plucks := []
	for m in range(MIN_MIDI, MAX_MIDI + 1):
		if FULL_SCALE.has(m % 12):
			all_plucks.append(m)
	synth.prewarm(all_plucks, all_plucks)
	if autoplay:
		var bot: Node = load("res://tools/autoplay.gd").new()
		bot.main = self
		add_child(bot)


func _exit_tree() -> void:
	synth.shutdown()


# ---------------------------------------------------------------- сцена

func _build_scene() -> void:
	# Волны рендерятся в половинном разрешении — вдвое дешевле для GPU и батареи.
	var container := SubViewportContainer.new()
	container.stretch = true
	container.stretch_shrink = 2
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(container)

	var vp := SubViewport.new()
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	container.add_child(vp)

	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wave_mat = ShaderMaterial.new()
	wave_mat.shader = WaveShader
	rect.material = wave_mat
	vp.add_child(rect)

	overlay = Control.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)

	hint = _make_label(24, Color(0.75, 0.85, 0.95, 0.85))
	hint.anchor_top = 0.62
	hint.anchor_bottom = 0.76
	add_child(hint)

	title = _make_label(44, Color(1.0, 0.95, 0.85, 1.0))
	title.anchor_top = 0.48
	title.anchor_bottom = 0.58
	add_child(title)

	result = _make_label(38, Color(1.0, 0.95, 0.85, 1.0))
	result.anchor_top = 0.40
	result.anchor_bottom = 0.62
	result.visible = false
	add_child(result)


func _make_label(font_size: int, color: Color) -> Label:
	var l := Label.new()
	l.anchor_left = 0.05
	l.anchor_right = 0.95
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	l.add_theme_constant_override("outline_size", 6)
	return l


func _build_audio() -> void:
	var reverb := AudioEffectReverb.new()
	reverb.room_size = 0.85
	reverb.damping = 0.35
	reverb.wet = 0.38
	reverb.dry = 0.85
	AudioServer.add_bus_effect(0, reverb)
	for i in 16:
		var p := AudioStreamPlayer.new()
		add_child(p)
		players.append(p)
	var drone := AudioStreamPlayer.new()
	drone.stream = synth.make_drone()
	drone.volume_db = -14.0
	add_child(drone)
	drone.play()


func _play(stream: AudioStream, volume: float) -> void:
	var p := players[next_player]
	next_player = (next_player + 1) % players.size()
	p.stream = stream
	p.volume_db = linear_to_db(clampf(volume, 0.02, 1.0))
	p.play()


# ---------------------------------------------------------------- уровни

func _load_levels() -> void:
	var f := FileAccess.open(LEVELS_PATH, FileAccess.READ)
	if f == null:
		push_error("Не удалось открыть %s" % LEVELS_PATH)
		return
	var data = JSON.parse_string(f.get_as_text())
	if data is Array and not data.is_empty():
		levels = data
	else:
		push_error("Ошибка формата %s" % LEVELS_PATH)


func _load_progress() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(PROGRESS_PATH) == OK:
		return int(cfg.get_value("progress", "level", 0))
	return 0


func _save_progress(i: int) -> void:
	if autoplay:
		return
	var cfg := ConfigFile.new()
	cfg.set_value("progress", "level", i)
	cfg.save(PROGRESS_PATH)


static func _v(a: Array) -> Vector2:
	return Vector2(float(a[0]), float(a[1]))


static func _ints(a: Array) -> Array:
	var out := []
	for x in a:
		out.append(int(x))
	return out


func load_level(i: int) -> void:
	level_i = clampi(i, 0, levels.size() - 1)
	level = levels[level_i]
	world = get_viewport_rect().size
	waves.clear()
	echoes.clear()
	crystals.clear()
	mufflers.clear()
	for c in level.crystals:
		var m := int(c.m)
		crystals.append({
			"pos": _v(c.p) * world,
			"midi": m,
			"freq": Synth.midi_to_freq(m),
			"glow": 0.0,
			"reveal": 0.0,
			"cooldown": 0.0,
		})
	for mf in level.get("mufflers", []):
		mufflers.append({
			"pos": _v(mf.p) * world,
			"r": float(mf.r) * world.x,
			"notes": _ints(mf.notes),
			"period": float(mf.period),
			"hp": int(mf.hp),
			"alive": true,
			"fade": 1.0,
			"flash": 0.0,
			"hit_cd": 0.0,
		})
	heart = {"pos": _v(level.heart.p) * world, "chord": _ints(level.heart.chord), "heard": {}, "glow": 0.0}
	note_scale = _ints(level.scale) if level.has("scale") else FULL_SCALE
	zone = _v(level.zone) if level.has("zone") else Vector2(0.0, 1.0)
	plucks = 0
	won = false
	level_start = now
	active_touch = -1
	result.visible = false
	title.text = "Тишь %d · %s" % [level_i + 1, level.name]
	title.modulate.a = 1.0
	hint.text = level.get("hint", "")
	hint.modulate.a = 1.0


func _next_level() -> void:
	var next := (level_i + 1) % levels.size()
	_save_progress(next)
	load_level(next)


# ---------------------------------------------------------------- ввод

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			if won:
				if now - won_at > 1.5:
					_next_level()
				return
			if active_touch == -1:
				active_touch = event.index
				drag_start = event.position
				drag_end = event.position
				press_time = now
				last_midi = -1
		elif event.index == active_touch:
			drag_end = event.position
			_release()
			active_touch = -1
	elif event is InputEventScreenDrag and event.index == active_touch:
		drag_end = event.position
		var m := _current_midi()
		if m != last_midi and drag_start.distance_to(drag_end) > 40.0:
			if last_midi != -1:
				haptics.fret_tick()
			last_midi = m


func _string_length() -> float:
	return drag_start.distance_to(drag_end)


func _in_zone(p: Vector2) -> bool:
	var y := p.y / world.y
	return y >= zone.x and y <= zone.y


## Длина струны → частота (как у настоящей струны: f ∝ 1/L), затем притяжение
## к ладу зоны, чтобы новичок всегда звучал чисто.
func _current_midi() -> int:
	var l := maxf(_string_length(), 40.0)
	var ref_len := world.y * 0.55
	var freq := 130.81 * ref_len / l
	var midi_f := 69.0 + 12.0 * log(freq / 440.0) / log(2.0)
	midi_f = clampf(midi_f, MIN_MIDI, MAX_MIDI)
	return _snap_to_scale(midi_f)


## Длина струны, дающая ноту midi (обратная формула; нужна автоигроку).
func length_for_midi(midi: int) -> float:
	return 130.81 * world.y * 0.55 / Synth.midi_to_freq(midi)


func _snap_to_scale(midi_f: float) -> int:
	var best := -1
	var best_d := 1e9
	var base := int(floor(midi_f / 12.0)) * 12
	for octave in [-12, 0, 12]:
		for s in note_scale:
			var m: int = base + octave + s
			if m < MIN_MIDI or m > MAX_MIDI:
				continue
			var d := absf(m - midi_f)
			if d < best_d:
				best_d = d
				best = m
	return best if best != -1 else MIN_MIDI


func _release() -> void:
	var length := _string_length()
	var mid := (drag_start + drag_end) * 0.5
	if length < 40.0:
		# Короткое касание — «эхолокация»: тихий светлый импульс без ноты.
		_spawn_wave(drag_end, 1400.0, 0.35, SRC_PLAYER, true)
		_play(synth.pluck(84), 0.12)
		haptics.pluck(0.1)
		return
	var midi := _current_midi()
	if not _in_zone(mid):
		# Вне полосы струн струна не держит натяжение — рвётся без звука.
		echoes.append({"a": drag_start, "b": drag_end, "t": now, "midi": midi, "amp": 0.3, "dead": true})
		haptics.fret_tick()
		return
	var hold := now - press_time
	var strength := clampf(0.55 + hold * 0.35, 0.55, 1.0)
	_spawn_wave(mid, Synth.midi_to_freq(midi), strength, SRC_PLAYER, false)
	_play(synth.pluck(midi), strength)
	haptics.pluck(strength)
	echoes.append({"a": drag_start, "b": drag_end, "t": now, "midi": midi, "amp": strength, "dead": false})
	plucks += 1
	if plucks == 1:
		title.modulate.a = minf(title.modulate.a, 0.6)


# ---------------------------------------------------------------- волны

## source: индекс кристалла или SRC_PLAYER / SRC_HEART / SRC_MUFFLER.
func _spawn_wave(pos: Vector2, freq: float, amp: float, source: int, ping: bool) -> void:
	waves.append({"pos": pos, "birth": now, "freq": freq, "amp": amp, "source": source, "ping": ping})
	while waves.size() > MAX_WAVES:
		waves.pop_front()


## Огибающая волнового пакета в точке — та же формула, что и в шейдере (без синуса).
func _envelope(p: Vector2, w: Dictionary) -> float:
	var age: float = now - w.birth
	var r: float = p.distance_to(w.pos)
	var behind := WAVE_SPEED * age - r
	if behind < 0.0:
		return 0.0
	var lambda := clampf(9000.0 / w.freq, 12.0, 90.0)
	return exp(-behind / (lambda * 2.5)) * exp(-age * 0.7) / sqrt(1.0 + r / 120.0)


## Пиковая сила волны в точке p, если её фронт пересёк p за этот кадр, иначе 0.
## Так попадание не зависит от частоты кадров: короткие высокие пакеты не
## проскакивают между кадрами, и каждая волна попадает в цель ровно один раз.
## Пик огибающей — это _envelope при behind = 0.
func _front_peak(p: Vector2, w: Dictionary, delta: float) -> float:
	var r: float = p.distance_to(w.pos)
	var behind: float = WAVE_SPEED * (now - w.birth) - r
	if behind < 0.0 or behind >= WAVE_SPEED * delta:
		return 0.0
	return exp(-(r / WAVE_SPEED) * 0.7) / sqrt(1.0 + r / 120.0) * float(w.amp)


## Насколько волна «попадает» в ноту: 1 — унисон/октава, 0.45 — квинта/кварта.
func _match(fw: float, fc: float) -> float:
	var cents := 1200.0 * log(fw / fc) / log(2.0)
	var m := fposmod(cents, 1200.0)
	var d := minf(m, 1200.0 - m)
	if d < 35.0:
		return 1.0
	if absf(m - 702.0) < 35.0 or absf(m - 498.0) < 35.0:
		return 0.45
	return 0.0


## Точка внутри живого Глушителя не слышит и не звучит.
func _muted(p: Vector2) -> bool:
	for mf in mufflers:
		if mf.alive and p.distance_to(mf.pos) < mf.r:
			return true
	return false


## Нота Глушителя в момент t (она плавает по кругу).
func muffler_note(mf: Dictionary, t: float) -> int:
	var notes: Array = mf.notes
	var k := int(floor((t - level_start) / float(mf.period)))
	return notes[posmod(k, notes.size())]


func _process(delta: float) -> void:
	now += delta
	var size := get_viewport_rect().size
	if size != world:
		_rescale(size)

	waves = waves.filter(func(w: Dictionary) -> bool: return now - w.birth < WAVE_LIFETIME)
	echoes = echoes.filter(func(e: Dictionary) -> bool: return now - e.t < 1.2)

	_update_mufflers(delta)
	_update_crystals(delta)
	_update_heart(delta)
	_push_shader()

	if now - level_start > 2.0:
		title.modulate.a = maxf(0.0, title.modulate.a - delta * 0.8)
	if plucks > 0 and not won:
		hint.modulate.a = maxf(0.0, hint.modulate.a - delta * 0.15)
	overlay.queue_redraw()


func _rescale(size: Vector2) -> void:
	var k := size / world
	for c in crystals:
		c.pos *= k
	for mf in mufflers:
		mf.pos *= k
		mf.r *= k.x
	heart.pos *= k
	for w in waves:
		w.pos *= k
	world = size


func _update_mufflers(delta: float) -> void:
	for mi in mufflers.size():
		var mf := mufflers[mi]
		mf.flash = maxf(0.0, mf.flash - delta * 2.0)
		if not mf.alive:
			mf.fade = maxf(0.0, mf.fade - delta * 0.8)
			continue
		mf.hit_cd -= delta
		if mf.hit_cd > 0.0:
			continue
		var note_f := Synth.midi_to_freq(muffler_note(mf, now))
		for w in waves:
			if w.ping or w.source == SRC_MUFFLER:
				continue
			var env := _front_peak(mf.pos, w, delta)
			if env > MUFFLER_THRESHOLD and _match(w.freq, note_f) >= 1.0:
				_muffler_hit(mf)
				break


func _muffler_hit(mf: Dictionary) -> void:
	mf.hp -= 1
	if autoplay:
		print("  Глушитель: попадание, осталось %d" % mf.hp)
	mf.flash = 1.0
	mf.hit_cd = 0.6
	haptics.resonance()
	if mf.hp <= 0:
		mf.alive = false
		# Распавшийся Глушитель выдыхает поглощённый звук.
		var m := muffler_note(mf, now)
		_spawn_wave(mf.pos, Synth.midi_to_freq(m), 0.6, SRC_MUFFLER, false)
		_play(synth.bell(m - 12), 0.9)
		haptics.heart()
	else:
		_play(synth.bell(muffler_note(mf, now)), 0.5)


func _update_crystals(delta: float) -> void:
	for ci in crystals.size():
		var c := crystals[ci]
		c.glow = maxf(0.0, c.glow - delta * 0.7)
		c.reveal = maxf(0.0, c.reveal - delta * 0.5)
		c.cooldown -= delta
		if _muted(c.pos):
			continue
		var best := 0.0
		var best_amp := 0.0
		for w in waves:
			if w.source == ci:
				continue
			var env := _envelope(c.pos, w) * float(w.amp)
			if env <= 0.001:
				continue
			c.reveal = maxf(c.reveal, minf(1.0, env * 4.0))
			if w.ping:
				continue
			var hit := _front_peak(c.pos, w, delta) * _match(w.freq, c.freq)
			if hit > best:
				best = hit
				best_amp = w.amp
		if best > RESONANCE_THRESHOLD and c.cooldown <= 0.0:
			_crystal_sing(ci, best_amp)


## Кристалл поёт: каждое поколение цепи чуть тише, поэтому цепь затухает сама.
func _crystal_sing(ci: int, incoming_amp: float) -> void:
	var c := crystals[ci]
	var amp := minf(0.85, incoming_amp * 0.85)
	c.cooldown = CRYSTAL_COOLDOWN
	c.glow = 1.0
	_spawn_wave(c.pos, c.freq, amp, ci, false)
	if autoplay:
		print("  кристалл %s%d поёт (сила %.2f)" % [NOTE_NAMES[c.midi % 12], c.midi / 12 - 1, amp])
	_play(synth.bell(c.midi), 0.35 + amp * 0.5)
	haptics.resonance()


func _update_heart(delta: float) -> void:
	heart.glow = maxf(0.0, heart.glow - delta * 0.4)
	if won or _muted(heart.pos):
		return
	for w in waves:
		if w.source < 0 or w.ping:
			continue # Сердце слышит только голоса кристаллов
		var env := _front_peak(heart.pos, w, delta)
		if env > HEART_THRESHOLD:
			var pc: int = int(crystals[w.source].midi) % 12
			if heart.chord.has(pc):
				if autoplay and not heart.heard.has(pc):
					print("  Сердце слышит %s (t=%.1f)" % [NOTE_NAMES[pc], now - level_start])
				heart.heard[pc] = now
	for pc in heart.chord:
		if not heart.heard.has(pc) or now - heart.heard[pc] > HEART_WINDOW:
			return
	_awaken()


func _awaken() -> void:
	won = true
	won_at = now
	heart.glow = 1.0
	for pc in heart.chord:
		var m: int = 72 + int(pc)
		_spawn_wave(heart.pos, Synth.midi_to_freq(m), 1.0, SRC_HEART, false)
		_play(synth.bell(m), 0.8)
	haptics.heart()
	var secs := int(now - level_start)
	var par := int(level.get("par", 0))
	var mark := "\n★ идеально ★" if par > 0 and plucks <= par else ""
	var last := level_i == levels.size() - 1
	var tail := "все Тиши пробуждены!\nкоснись, чтобы начать сначала" if last else "коснись — следующая Тишь"
	result.text = "Тишь пробуждена%s\n\nщипков: %d   ·   время: %d:%02d\n\n%s" % [mark, plucks, secs / 60, secs % 60, tail]
	result.visible = true
	hint.modulate.a = 0.0
	title.modulate.a = 0.0


func _push_shader() -> void:
	var data: Array[Vector4] = []
	var amps: Array[float] = []
	for w in waves:
		data.append(Vector4(w.pos.x, w.pos.y, now - w.birth, w.freq))
		amps.append(w.amp)
	var count := data.size()
	while data.size() < MAX_WAVES:
		data.append(Vector4.ZERO)
		amps.append(0.0)
	var mdata: Array[Vector4] = []
	for mf in mufflers:
		if mf.fade > 0.0 and mdata.size() < MAX_MUFFLERS:
			mdata.append(Vector4(mf.pos.x, mf.pos.y, mf.r, mf.fade))
	var mcount := mdata.size()
	while mdata.size() < MAX_MUFFLERS:
		mdata.append(Vector4.ZERO)
	wave_mat.set_shader_parameter("waves", data)
	wave_mat.set_shader_parameter("amps", amps)
	wave_mat.set_shader_parameter("wave_count", count)
	wave_mat.set_shader_parameter("mufflers", mdata)
	wave_mat.set_shader_parameter("muffler_count", mcount)
	wave_mat.set_shader_parameter("world_size", world)
	wave_mat.set_shader_parameter("speed", WAVE_SPEED)


# ---------------------------------------------------------------- отрисовка

static func freq_color(f: float) -> Color:
	var t := clampf(log(f / 110.0) / log(2.0) / 3.2, 0.0, 1.0)
	var low := Color(1.0, 0.42, 0.10)
	var mid := Color(0.10, 0.90, 0.78)
	var high := Color(0.78, 0.62, 1.0)
	return low.lerp(mid, t * 2.0) if t < 0.5 else mid.lerp(high, (t - 0.5) * 2.0)


func _draw_overlay() -> void:
	var font := get_theme_default_font()

	# Полоса струн: где можно натягивать.
	if zone != Vector2(0.0, 1.0):
		var y0 := zone.x * world.y
		var y1 := zone.y * world.y
		var zc := Color(0.6, 0.75, 0.9)
		overlay.draw_rect(Rect2(0, y0, world.x, y1 - y0), Color(zc, 0.035))
		overlay.draw_line(Vector2(0, y0), Vector2(world.x, y0), Color(zc, 0.22), 1.5)
		if y1 < world.y - 1.0:
			overlay.draw_line(Vector2(0, y1), Vector2(world.x, y1), Color(zc, 0.22), 1.5)

	# Кристаллы: почти невидимы, пока их не коснётся звук.
	for c in crystals:
		var col := freq_color(c.freq)
		var muted := _muted(c.pos)
		var light: float = 0.07 + c.reveal * 0.55 + c.glow
		if muted:
			light = 0.05
		var s: float = 16.0 + c.glow * 6.0
		var p: Vector2 = c.pos
		if c.glow > 0.0:
			overlay.draw_circle(p, s * 3.0, Color(col, 0.12 * c.glow))
			overlay.draw_circle(p, s * 1.8, Color(col, 0.22 * c.glow))
		var pts := PackedVector2Array([p + Vector2(0, -s * 1.4), p + Vector2(s * 0.8, 0), p + Vector2(0, s * 1.4), p + Vector2(-s * 0.8, 0)])
		overlay.draw_colored_polygon(pts, Color(col * minf(1.0, light), 1.0))
		if not muted and (c.reveal > 0.2 or c.glow > 0.0):
			var a: float = clampf(maxf(c.reveal, c.glow) - 0.1, 0.0, 0.8)
			overlay.draw_string(font, p + Vector2(-40, s * 1.4 + 26), NOTE_NAMES[c.midi % 12], HORIZONTAL_ALIGNMENT_CENTER, 80, 20, Color(col, a))

	# Глушители: рваное кольцо цвета текущей ноты и дуга времени до смены ноты.
	for mf in mufflers:
		if mf.fade <= 0.0:
			continue
		var p: Vector2 = mf.pos
		var r: float = mf.r
		var m := muffler_note(mf, now)
		var col := freq_color(Synth.midi_to_freq(m))
		var a: float = mf.fade
		var ring := PackedVector2Array()
		for i in 49:
			var ang := TAU * i / 48.0
			var jag := 1.0 + 0.05 * sin(ang * 7.0 + now * 2.3) + 0.03 * sin(ang * 13.0 - now * 3.1)
			ring.append(p + Vector2(cos(ang), sin(ang)) * r * jag)
		overlay.draw_polyline(ring, Color(col, (0.35 + mf.flash * 0.6) * a), 2.0 + mf.flash * 3.0, true)
		if mf.alive:
			var phase := fposmod((now - level_start) / float(mf.period), 1.0)
			overlay.draw_arc(p, r + 10.0, -PI / 2, -PI / 2 + TAU * (1.0 - phase), 48, Color(col, 0.35), 2.0, true)
			overlay.draw_string(font, p + Vector2(-60, -r - 18), NOTE_NAMES[m % 12], HORIZONTAL_ALIGNMENT_CENTER, 120, 24, Color(col, 0.9))
			for k in mf.hp:
				overlay.draw_circle(p + Vector2((k - (mf.hp - 1) * 0.5) * 16.0, r + 22.0), 4.0, Color(col, 0.8))

	# Сердце и огоньки аккорда: какие ноты оно уже услышало.
	var hp: Vector2 = heart.pos
	var pulse := 0.5 + 0.5 * sin(now * 1.6)
	var hcol := Color(1.0, 0.92, 0.8)
	overlay.draw_circle(hp, 46.0 + heart.glow * 60.0, Color(hcol, 0.04 + 0.03 * pulse + heart.glow * 0.25))
	overlay.draw_arc(hp, 26.0, 0, TAU, 48, Color(hcol, 0.25 + 0.15 * pulse + heart.glow), 2.0, true)
	var chord: Array = heart.chord
	for i in chord.size():
		var pc: int = chord[i]
		var ang := -PI / 2 + TAU * i / chord.size()
		var op := hp + Vector2(cos(ang), sin(ang)) * 40.0
		var heard: bool = heart.heard.has(pc) and (won or now - heart.heard[pc] < HEART_WINDOW)
		var oc := freq_color(Synth.midi_to_freq(60 + pc))
		overlay.draw_circle(op, 6.0, Color(oc, 0.9) if heard else Color(oc, 0.12))

	# Отпущенные струны дрожат и гаснут; оборванные — серые.
	for e in echoes:
		var age: float = now - e.t
		var col := Color(0.5, 0.5, 0.55) if e.dead else freq_color(Synth.midi_to_freq(e.midi))
		var fade := (1.0 - age / 1.2) * (0.5 if e.dead else 1.0)
		_draw_string_line(e.a, e.b, col, fade, sin(age * 70.0) * 10.0 * e.amp * exp(-age * 4.0))

	# Струна, которую тянут сейчас.
	if active_touch != -1 and _string_length() > 40.0:
		var m := _current_midi()
		var ok := _in_zone((drag_start + drag_end) * 0.5)
		var col := freq_color(Synth.midi_to_freq(m)) if ok else Color(0.5, 0.5, 0.55)
		var tension := clampf((now - press_time) * 0.35, 0.0, 0.45)
		_draw_string_line(drag_start, drag_end, col, (0.75 + tension) if ok else 0.4, sin(now * 50.0) * 1.2)
		overlay.draw_circle(drag_start, 7.0, Color(col, 0.9))
		overlay.draw_circle(drag_end, 7.0, Color(col, 0.9))
		var label := "%s%d" % [NOTE_NAMES[m % 12], m / 12 - 1] if ok else "вне полосы"
		overlay.draw_string(font, drag_end + Vector2(-80, -34), label, HORIZONTAL_ALIGNMENT_CENTER, 160, 26, Color(col, 0.95))


func _draw_string_line(a: Vector2, b: Vector2, col: Color, alpha: float, bend: float) -> void:
	var n := 24
	var normal := (b - a).orthogonal().normalized()
	var pts := PackedVector2Array()
	for i in n + 1:
		var t := float(i) / n
		pts.append(a.lerp(b, t) + normal * sin(t * PI) * bend)
	overlay.draw_polyline(pts, Color(col, 0.18 * alpha), 9.0, true)
	overlay.draw_polyline(pts, Color(col, alpha), 2.5, true)

## RESONA — прототип «Одна струна».
##
## Коснись и тяни: длина струны = высота ноты (длиннее — ниже).
## Отпусти: звуковая волна расходится по тёмному миру и подсвечивает его.
## Кристаллы звучат в ответ, если волна совпала с их нотой (унисон/октава — сильно,
## квинта/кварта — слабо). Их голоса будят другие кристаллы — цепная реакция.
## Сердце слышит только голос мира: разбуди кристаллы До, Ми и Соль, чтобы их волны
## одновременно (за 3.5 с) дошли до Сердца — и Тишь пробудится.
extends Control

const Synth := preload("res://scripts/synth.gd")
const Haptics := preload("res://scripts/haptics.gd")
const WaveShader := preload("res://shaders/waves.gdshader")

const MAX_WAVES := 24
const WAVE_SPEED := 420.0
const WAVE_LIFETIME := 4.5
const SCALE := [0, 2, 4, 5, 7, 9, 11] # До мажор
const NOTE_NAMES := ["До", "До♯", "Ре", "Ре♯", "Ми", "Фа", "Фа♯", "Соль", "Соль♯", "Ля", "Ля♯", "Си"]
const MIN_MIDI := 48 # До3
const MAX_MIDI := 84 # До6
const RESONANCE_THRESHOLD := 0.075
const HEART_THRESHOLD := 0.1
const HEART_CHORD := [0, 4, 7] # До, Ми, Соль
const HEART_WINDOW := 3.5
const CRYSTAL_COOLDOWN := 3.0
const SRC_PLAYER := -1
const SRC_HEART := -2

# Уровень: нормализованные координаты (0..1) и MIDI-нота кристалла.
const LEVEL := [
	{"p": Vector2(0.22, 0.80), "m": 60}, # До4
	{"p": Vector2(0.78, 0.74), "m": 64}, # Ми4
	{"p": Vector2(0.50, 0.60), "m": 67}, # Соль4
	{"p": Vector2(0.86, 0.90), "m": 62}, # Ре4 — отвлекающий
	{"p": Vector2(0.14, 0.58), "m": 69}, # Ля4 — отвлекающий
	{"p": Vector2(0.20, 0.38), "m": 72}, # До5
	{"p": Vector2(0.80, 0.40), "m": 76}, # Ми5
	{"p": Vector2(0.50, 0.30), "m": 79}, # Соль5
]
const HEART_POS := Vector2(0.5, 0.12)

var synth := Synth.new()
var haptics := Haptics.new()

var waves: Array[Dictionary] = []
var crystals: Array[Dictionary] = []
var echoes: Array[Dictionary] = [] # дрожащие отпущенные струны
var heart := {}

var now := 0.0
var world := Vector2(720, 1280)
var wave_mat: ShaderMaterial
var overlay: Control
var hint: Label
var result: Label

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
	_build_scene()
	_build_audio()
	_reset_level()
	var all_plucks := []
	for m in range(MIN_MIDI, MAX_MIDI + 1):
		if SCALE.has(m % 12):
			all_plucks.append(m)
	var bells := []
	for c in LEVEL:
		bells.append(c.m)
	synth.prewarm(all_plucks, bells)
	if OS.get_cmdline_user_args().has("--autoplay"):
		var bot: Node = load("res://tools/autoplay.gd").new()
		bot.main = self
		add_child(bot)


func _exit_tree() -> void:
	synth.shutdown()


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

	hint = _make_label(28, Color(0.75, 0.85, 0.95, 0.85))
	hint.anchor_top = 0.88
	hint.anchor_bottom = 0.98
	add_child(hint)

	result = _make_label(40, Color(1.0, 0.95, 0.85, 1.0))
	result.anchor_top = 0.42
	result.anchor_bottom = 0.58
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


func _reset_level() -> void:
	world = get_viewport_rect().size
	waves.clear()
	echoes.clear()
	crystals.clear()
	for c in LEVEL:
		crystals.append({
			"pos": c.p * world,
			"midi": c.m,
			"freq": Synth.midi_to_freq(c.m),
			"glow": 0.0,
			"reveal": 0.0,
			"cooldown": 0.0,
		})
	heart = {"pos": HEART_POS * world, "heard": {}, "glow": 0.0}
	plucks = 0
	won = false
	level_start = now
	result.visible = false
	hint.text = "Коснись и тяни — натяни струну.\nОтпусти — и мир зазвучит."
	hint.modulate.a = 1.0


# ---------------------------------------------------------------- ввод

func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			if won:
				if now - won_at > 1.5:
					_reset_level()
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


## Длина струны → частота (как у настоящей струны: f ∝ 1/L), затем мягкое
## притяжение к ладу зоны (До мажор), чтобы новичок всегда звучал чисто.
func _current_midi() -> int:
	var l := maxf(_string_length(), 40.0)
	var ref_len := world.y * 0.55
	var freq := 130.81 * ref_len / l
	var midi_f := 69.0 + 12.0 * log(freq / 440.0) / log(2.0)
	midi_f = clampf(midi_f, MIN_MIDI, MAX_MIDI)
	return _snap_to_scale(midi_f)


func _snap_to_scale(midi_f: float) -> int:
	var best := MIN_MIDI
	var best_d := 1e9
	var base := int(floor(midi_f / 12.0)) * 12
	for octave in [-12, 0, 12]:
		for s in SCALE:
			var m: int = base + octave + s
			if m < MIN_MIDI or m > MAX_MIDI:
				continue
			var d := absf(m - midi_f)
			if d < best_d:
				best_d = d
				best = m
	return best


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
	var hold := now - press_time
	var strength := clampf(0.55 + hold * 0.35, 0.55, 1.0)
	_spawn_wave(mid, Synth.midi_to_freq(midi), strength, SRC_PLAYER, false)
	_play(synth.pluck(midi), strength)
	haptics.pluck(strength)
	echoes.append({"a": drag_start, "b": drag_end, "t": now, "midi": midi, "amp": strength})
	plucks += 1
	if plucks == 1:
		hint.text = "Сердце слышит только голос мира.\nРазбуди кристаллы До, Ми и Соль."


# ---------------------------------------------------------------- волны

## source: индекс кристалла, SRC_PLAYER или SRC_HEART.
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


## Насколько волна «попадает» в ноту кристалла.
func _match(fw: float, fc: float) -> float:
	var cents := 1200.0 * log(fw / fc) / log(2.0)
	var m := fposmod(cents, 1200.0)
	var d := minf(m, 1200.0 - m)
	if d < 35.0:
		return 1.0 # унисон / октава
	if absf(m - 702.0) < 35.0 or absf(m - 498.0) < 35.0:
		return 0.45 # квинта / кварта
	return 0.0


func _process(delta: float) -> void:
	now += delta
	var size := get_viewport_rect().size
	if size != world:
		_rescale(size)

	# Старые волны уходят.
	waves = waves.filter(func(w: Dictionary) -> bool: return now - w.birth < WAVE_LIFETIME)
	echoes = echoes.filter(func(e: Dictionary) -> bool: return now - e.t < 1.2)

	_update_crystals(delta)
	_update_heart(delta)
	_push_shader()

	if plucks > 0 and not won:
		hint.modulate.a = maxf(0.35, hint.modulate.a - delta * 0.05)
	overlay.queue_redraw()


func _rescale(size: Vector2) -> void:
	var k := size / world
	for c in crystals:
		c.pos *= k
	heart.pos *= k
	for w in waves:
		w.pos *= k
	world = size


func _update_crystals(delta: float) -> void:
	for ci in crystals.size():
		var c := crystals[ci]
		c.glow = maxf(0.0, c.glow - delta * 0.7)
		c.reveal = maxf(0.0, c.reveal - delta * 0.5)
		c.cooldown -= delta
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
			var hit := env * _match(w.freq, c.freq)
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
	_play(synth.bell(c.midi), 0.35 + amp * 0.5)
	haptics.resonance()


func _update_heart(delta: float) -> void:
	heart.glow = maxf(0.0, heart.glow - delta * 0.4)
	if won:
		return
	for w in waves:
		if w.source < 0 or w.ping:
			continue # Сердце слышит только голоса кристаллов
		var env := _envelope(heart.pos, w) * float(w.amp)
		if env > HEART_THRESHOLD:
			var pc: int = int(crystals[w.source].midi) % 12
			if HEART_CHORD.has(pc):
				heart.heard[pc] = now
	var all_heard := true
	for pc in HEART_CHORD:
		if not heart.heard.has(pc) or now - heart.heard[pc] > HEART_WINDOW:
			all_heard = false
	if all_heard:
		_awaken()


func _awaken() -> void:
	won = true
	won_at = now
	heart.glow = 1.0
	for m in [72, 76, 79]:
		_spawn_wave(heart.pos, Synth.midi_to_freq(m), 1.0, SRC_HEART, false)
		_play(synth.bell(m), 0.8)
	haptics.heart()
	var secs := int(now - level_start)
	result.text = "Тишь пробуждена\n\nщипков: %d   ·   время: %d:%02d\n\nкоснись, чтобы начать снова" % [plucks, secs / 60, secs % 60]
	result.visible = true
	hint.modulate.a = 0.0


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
	wave_mat.set_shader_parameter("waves", data)
	wave_mat.set_shader_parameter("amps", amps)
	wave_mat.set_shader_parameter("wave_count", count)
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
	# Кристаллы: почти невидимы, пока их не коснётся звук.
	for c in crystals:
		var col := freq_color(c.freq)
		var light: float = 0.07 + c.reveal * 0.55 + c.glow
		var s: float = 16.0 + c.glow * 6.0
		var p: Vector2 = c.pos
		if c.glow > 0.0:
			overlay.draw_circle(p, s * 3.0, Color(col, 0.12 * c.glow))
			overlay.draw_circle(p, s * 1.8, Color(col, 0.22 * c.glow))
		var pts := PackedVector2Array([p + Vector2(0, -s * 1.4), p + Vector2(s * 0.8, 0), p + Vector2(0, s * 1.4), p + Vector2(-s * 0.8, 0)])
		overlay.draw_colored_polygon(pts, Color(col * minf(1.0, light), 1.0))
		if c.reveal > 0.2 or c.glow > 0.0:
			var a: float = clampf(maxf(c.reveal, c.glow) - 0.1, 0.0, 0.8)
			overlay.draw_string(font, p + Vector2(-40, s * 1.4 + 26), NOTE_NAMES[c.midi % 12], HORIZONTAL_ALIGNMENT_CENTER, 80, 20, Color(col, a))

	# Сердце и три огонька аккорда: какие ноты оно уже услышало.
	var hp: Vector2 = heart.pos
	var pulse := 0.5 + 0.5 * sin(now * 1.6)
	var hcol := Color(1.0, 0.92, 0.8)
	overlay.draw_circle(hp, 46.0 + heart.glow * 60.0, Color(hcol, 0.04 + 0.03 * pulse + heart.glow * 0.25))
	overlay.draw_arc(hp, 26.0, 0, TAU, 48, Color(hcol, 0.25 + 0.15 * pulse + heart.glow), 2.0, true)
	for i in HEART_CHORD.size():
		var pc: int = HEART_CHORD[i]
		var ang := -PI / 2 + TAU * i / 3.0
		var op := hp + Vector2(cos(ang), sin(ang)) * 40.0
		var heard: bool = heart.heard.has(pc) and (won or now - heart.heard[pc] < HEART_WINDOW)
		var oc := freq_color(Synth.midi_to_freq(60 + pc))
		overlay.draw_circle(op, 6.0, Color(oc, 0.9) if heard else Color(oc, 0.12))

	# Отпущенные струны дрожат и гаснут.
	for e in echoes:
		var age: float = now - e.t
		var col := freq_color(Synth.midi_to_freq(e.midi))
		var fade := 1.0 - age / 1.2
		_draw_string_line(e.a, e.b, col, fade, sin(age * 70.0) * 10.0 * e.amp * exp(-age * 4.0))

	# Струна, которую тянут сейчас.
	if active_touch != -1 and _string_length() > 40.0:
		var m := _current_midi()
		var col := freq_color(Synth.midi_to_freq(m))
		var tension := clampf((now - press_time) * 0.35, 0.0, 0.45)
		_draw_string_line(drag_start, drag_end, col, 0.75 + tension, sin(now * 50.0) * 1.2)
		overlay.draw_circle(drag_start, 7.0, Color(col, 0.9))
		overlay.draw_circle(drag_end, 7.0, Color(col, 0.9))
		var label_pos := drag_end + Vector2(-60, -34)
		overlay.draw_string(font, label_pos, "%s%d" % [NOTE_NAMES[m % 12], m / 12 - 1], HORIZONTAL_ALIGNMENT_CENTER, 120, 26, Color(col, 0.95))


func _draw_string_line(a: Vector2, b: Vector2, col: Color, alpha: float, bend: float) -> void:
	var n := 24
	var normal := (b - a).orthogonal().normalized()
	var pts := PackedVector2Array()
	for i in n + 1:
		var t := float(i) / n
		pts.append(a.lerp(b, t) + normal * sin(t * PI) * bend)
	overlay.draw_polyline(pts, Color(col, 0.18 * alpha), 9.0, true)
	overlay.draw_polyline(pts, Color(col, alpha), 2.5, true)

## Процедурный звук RESONA: никаких сэмплов, всё синтезируется.
## - pluck: струна по алгоритму Karplus-Strong
## - bell: голос кристалла (неоднородные обертоны, как у колокола)
## - drone: тихий фон зоны (зацикленный)
## Звуки рендерятся один раз и кэшируются; кэш прогревается в фоне.
extends RefCounted

const MIX_RATE := 44100
const PLUCK_SECONDS := 1.6
const BELL_SECONDS := 2.4

var _cache := {}
var _mutex := Mutex.new()
var _task := -1
var _cancel := false


static func midi_to_freq(midi: int) -> float:
	return 440.0 * pow(2.0, (midi - 69) / 12.0)


func pluck(midi: int) -> AudioStreamWAV:
	return _cached("p%d" % midi, func() -> AudioStreamWAV: return _render_pluck(midi_to_freq(midi)))


func bell(midi: int) -> AudioStreamWAV:
	return _cached("b%d" % midi, func() -> AudioStreamWAV: return _render_bell(midi_to_freq(midi)))


## Фоновый прогрев кэша, чтобы первый щипок не заикался.
func prewarm(plucks: Array, bells: Array) -> void:
	_task = WorkerThreadPool.add_task(func() -> void:
		var t0 := Time.get_ticks_msec()
		for m in bells:
			if _cancel:
				return
			bell(m)
		for m in plucks:
			if _cancel:
				return
			pluck(m)
		print("RESONA: звук прогрет за %d мс" % (Time.get_ticks_msec() - t0))
	)


## Вызывать при выходе: дождаться фоновой задачи, иначе движок упадёт.
func shutdown() -> void:
	_cancel = true
	if _task != -1:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1


func _cached(key: String, render: Callable) -> AudioStreamWAV:
	_mutex.lock()
	var hit: AudioStreamWAV = _cache.get(key)
	_mutex.unlock()
	if hit:
		return hit
	var stream: AudioStreamWAV = render.call()
	_mutex.lock()
	_cache[key] = stream
	_mutex.unlock()
	return stream


func _render_pluck(freq: float) -> AudioStreamWAV:
	var n := int(MIX_RATE * PLUCK_SECONDS)
	var period := maxi(2, int(round(MIX_RATE / freq)))
	var buf := PackedFloat32Array()
	buf.resize(period)
	# Начальный шум, слегка сглаженный: мягкий "щипок пальцем", а не медиатор.
	var prev := 0.0
	for i in period:
		var r := randf_range(-1.0, 1.0)
		prev = prev * 0.5 + r * 0.5
		buf[i] = prev
	# Высокие ноты в жизни затухают быстрее.
	var decay := clampf(0.9985 - freq * 0.0000025, 0.990, 0.9985)
	var out := PackedFloat32Array()
	out.resize(n)
	var idx := 0
	for i in n:
		var cur := buf[idx]
		var nxt := buf[(idx + 1) % period]
		buf[idx] = (cur + nxt) * 0.5 * decay
		idx = (idx + 1) % period
		out[i] = cur
	return _to_wav(out, 0.55)


func _render_bell(freq: float) -> AudioStreamWAV:
	var n := int(MIX_RATE * BELL_SECONDS)
	var ratios := [1.0, 2.0, 2.76, 4.07, 5.4]
	var gains := [1.0, 0.45, 0.32, 0.18, 0.12]
	var decays := [1.4, 1.0, 0.75, 0.5, 0.35]
	var out := PackedFloat32Array()
	out.resize(n)
	for k in ratios.size():
		var f: float = freq * ratios[k]
		if f > MIX_RATE * 0.45:
			continue
		var w := TAU * f / MIX_RATE
		var g: float = gains[k]
		var d: float = decays[k]
		for i in n:
			var t := float(i) / MIX_RATE
			out[i] += sin(w * i) * g * exp(-t / d)
	# Мягкая атака, чтобы не было щелчка.
	var attack := int(MIX_RATE * 0.004)
	for i in attack:
		out[i] *= float(i) / attack
	return _to_wav(out, 0.32)


## Фон зоны: низкий До с квинтой и медленными биениями. Длина 4 с, все частоты
## кратны 0.25 Гц — ровное целое число периодов, петля без щелчков.
func make_drone() -> AudioStreamWAV:
	var seconds := 4.0
	var n := int(MIX_RATE * seconds)
	var freqs := [65.5, 65.75, 98.25, 131.0, 196.5]
	var gains := [0.5, 0.35, 0.3, 0.12, 0.06]
	var out := PackedFloat32Array()
	out.resize(n)
	for k in freqs.size():
		var w: float = TAU * freqs[k] / MIX_RATE
		var g: float = gains[k]
		for i in n:
			out[i] += sin(w * i) * g
	var wav := _to_wav(out, 0.18)
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = n
	return wav


func _to_wav(samples: PackedFloat32Array, gain: float) -> AudioStreamWAV:
	var peak := 0.0001
	for s in samples:
		peak = maxf(peak, absf(s))
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	var k := gain / peak
	var fade := int(samples.size() * 0.1)
	var start_fade := samples.size() - fade
	for i in samples.size():
		var v := samples[i] * k
		if i > start_fade:
			v *= float(samples.size() - i) / fade
		data.encode_s16(i * 2, int(clampf(v, -1.0, 1.0) * 32767.0))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = MIX_RATE
	wav.stereo = false
	wav.data = data
	return wav

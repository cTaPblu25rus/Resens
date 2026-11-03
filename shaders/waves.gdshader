// RESONA — звук это свет.
// Аналитическая сумма волновых пакетов + отражения от краёв методом мнимых источников.
// Интерференция получается сама: поля складываются со знаком, противофаза гасит свет.
shader_type canvas_item;

#define MAX_WAVES 24
#define MAX_MUFFLERS 4

uniform vec4 waves[MAX_WAVES];   // x, y (px мира), возраст (с), частота (Гц)
uniform float amps[MAX_WAVES];   // амплитуда волны
uniform int wave_count = 0;
uniform vec2 world_size = vec2(720.0, 1280.0);
uniform float speed = 420.0;
uniform float reflection = 0.45; // 0 — отражения выключены
uniform vec4 mufflers[MAX_MUFFLERS]; // x, y, радиус (px), сила 0..1
uniform int muffler_count = 0;

vec3 freq_color(float f) {
	// бас — янтарь, середина — бирюза, верх — фиолетово-белый лёд
	float t = clamp(log2(f / 110.0) / 3.2, 0.0, 1.0);
	vec3 low = vec3(1.0, 0.42, 0.10);
	vec3 mid = vec3(0.10, 0.90, 0.78);
	vec3 high = vec3(0.78, 0.62, 1.0);
	return t < 0.5 ? mix(low, mid, t * 2.0) : mix(mid, high, (t - 0.5) * 2.0);
}

float wave_at(vec2 p, vec2 src, float age, float f) {
	float r = distance(p, src);
	float behind = speed * age - r;
	if (behind < 0.0) {
		return 0.0;
	}
	float lambda = clamp(9000.0 / f, 12.0, 90.0);
	float env = exp(-behind / (lambda * 2.5)) * exp(-age * 0.7) * inversesqrt(1.0 + r / 120.0);
	return sin(6.2831853 * behind / lambda) * env;
}

void fragment() {
	vec2 p = UV * world_size;
	float field = 0.0;
	vec3 tint = vec3(0.0);
	float weight = 0.0;
	for (int i = 0; i < MAX_WAVES; i++) {
		if (i >= wave_count) {
			break;
		}
		vec4 w = waves[i];
		float h = wave_at(p, w.xy, w.z, w.w);
		if (reflection > 0.0) {
			h += reflection * wave_at(p, vec2(-w.x, w.y), w.z, w.w);
			h += reflection * wave_at(p, vec2(2.0 * world_size.x - w.x, w.y), w.z, w.w);
			h += reflection * wave_at(p, vec2(w.x, -w.y), w.z, w.w);
			h += reflection * wave_at(p, vec2(w.x, 2.0 * world_size.y - w.y), w.z, w.w);
		}
		h *= amps[i];
		field += h;
		tint += freq_color(w.w) * abs(h);
		weight += abs(h);
	}
	vec3 col = weight > 0.0001 ? tint / weight : vec3(0.0);
	float light = pow(abs(field), 0.8) * 1.4;
	vec3 c = col * light;
	// Глушители пожирают свет и звук внутри себя.
	for (int j = 0; j < MAX_MUFFLERS; j++) {
		if (j >= muffler_count) {
			break;
		}
		vec4 m = mufflers[j];
		float inside = 1.0 - smoothstep(m.z * 0.8, m.z, distance(p, m.xy));
		c *= 1.0 - 0.9 * inside * m.w;
	}
	c = c / (1.0 + c);             // мягкий тонмаппинг
	c += vec3(0.004, 0.005, 0.009); // почти чёрный: OLED экономит батарею
	COLOR = vec4(c, 1.0);
}

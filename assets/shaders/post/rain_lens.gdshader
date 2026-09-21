shader_type canvas_item;
// Rain on the lens (see rain.gd): small beads that appear and evaporate, bigger drops that run
// down leaving a trail, and a full wet film right after surfacing. Every drop refracts the image
// behind it. Drawn before the PS1 post-process, so it gets the same pixelation and dither.

uniform sampler2D screen_texture : hint_screen_texture, filter_nearest;
/** How many drops land on the lens (0..1). Driven by rain intensity. */
uniform float amount : hint_range(0.0, 1.0) = 0.0;
/** Whole-lens wetness right after coming out of the water (0..1), fades by itself. */
uniform float film : hint_range(0.0, 1.0) = 0.0;
/** How strongly drops bend the image. */
uniform float refraction : hint_range(0.0, 0.1) = 0.035;
/** Size of the drops (fraction of screen height). */
uniform float drop_size : hint_range(0.005, 0.1) = 0.03;
uniform float time_offset = 0.0;

vec3 hash32(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yxz + 33.33);
	return fract((p3.xxy + p3.yzz) * p3.zyx);
}

// One grid of drops. Returns (normal xy, coverage). `slide` makes drops run down the lens.
vec3 drop_layer(vec2 uv, float aspect, float cell, float t, float slide, float chance) {
	vec2 grid = vec2(aspect, 1.0) / cell;
	vec2 p = uv * grid;
	// Sliding columns move down at their own speed.
	vec2 col_id = vec2(floor(p.x), 0.0);
	vec3 col = hash32(col_id + 7.0);
	p.y += t * slide * mix(0.6, 1.4, col.x);
	vec2 id = floor(p);
	vec2 f = fract(p) - 0.5;
	vec3 h = hash32(id + col.yz * 31.0);
	if (h.z > chance) return vec3(0.0);
	// Life cycle: fades in, lingers, dries out.
	float life = fract(t * mix(0.08, 0.2, h.x) + h.y);
	float alive = smoothstep(0.0, 0.05, life) * (1.0 - smoothstep(0.6, 1.0, life));
	vec2 center = (h.xy - 0.5) * 0.5;
	vec2 d = f - center;
	d.y *= slide > 0.0 ? 0.8 : 1.0; // Running drops are a little elongated.
	float r = length(d) / (0.28 * mix(0.6, 1.0, h.x));
	float bead = (1.0 - smoothstep(0.85, 1.0, r)) * alive;
	vec2 n = d * bead * 2.0;
	// Trail left above a running drop.
	if (slide > 0.0) {
		float trail = (1.0 - smoothstep(0.02, 0.08, abs(d.x))) * smoothstep(0.0, -0.45, d.y) * alive * 0.5;
		bead = max(bead, trail);
	}
	return vec3(n, bead);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	float aspect = SCREEN_PIXEL_SIZE.y / SCREEN_PIXEL_SIZE.x;
	float t = TIME + time_offset;
	vec3 still = drop_layer(uv, aspect, drop_size, t, 0.0, amount * 0.35);
	vec3 small = drop_layer(uv + 0.37, aspect, drop_size * 0.55, t * 1.3, 0.0, amount * 0.25);
	vec3 run = drop_layer(uv + 0.71, aspect, drop_size * 2.2, t, 0.35, amount * 0.2);
	vec2 bend = still.xy + small.xy * 0.6 + run.xy * 1.5;
	float cover = max(max(still.z, small.z), run.z);
	// Film after surfacing: a wobbly wash over everything.
	bend += film * vec2(sin(uv.y * 23.0 + t * 3.0), cos(uv.x * 17.0 - t * 2.3)) * 0.4;
	cover = max(cover, film * 0.6);
	vec3 col = textureLod(screen_texture, uv - bend * refraction, 0.0).rgb;
	// Drops are slightly darker at their edges and catch a little light.
	col *= mix(1.0, 0.85, cover * (1.0 - cover) * 4.0);
	COLOR = vec4(col, cover > 0.001 ? 1.0 : 0.0);
}

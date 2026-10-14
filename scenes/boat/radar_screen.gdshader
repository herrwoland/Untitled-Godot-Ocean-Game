shader_type spatial;
// The radar's round screen (radar.gd). `hits` holds, per texel, when the ring last touched
// something there (r, in `now` seconds) and what it was (g creature, b land); the glow is worked out
// here from the age, so nothing is redrawn while it fades. The ring, the range circles and the
// ship at the centre are drawn here too.
render_mode unshaded, cull_back, shadows_disabled;

uniform sampler2D hits : filter_nearest, repeat_disable;
uniform float now = 0.0;
uniform float ring = -1.0; // how far out the ring is, 0..1 of the radius; < 0 = none
uniform float powered = 1.0;
uniform vec2 bow = vec2(0.0, -1.0); // the ship's bow, as a direction in UV
uniform vec3 creature_color : source_color = vec3(0.35, 1.0, 0.55);
uniform vec3 land_color : source_color = vec3(0.1575, 0.45, 0.2475);
uniform vec3 ring_color : source_color = vec3(0.35, 1.0, 0.55);
uniform vec3 marks_color : source_color = vec3(0.35, 1.0, 0.55);
uniform vec3 background : source_color = vec3(0.0034, 0.0096, 0.0053);
uniform float wake = 0.2;
uniform float energy = 1.6;
uniform float afterglow = 8.0; // s a blip takes to fade
uniform float flare = 1.5; // the flash when the ring touches it
uniform float ring_width = 0.012;
uniform float grain = 0.35;
uniform float range_rings = 4.0;
uniform float texels = 128.0;
uniform vec2 uv_center = vec2(0.5); // where the screen's circle sits in the mesh's UVs
uniform vec2 uv_half = vec2(0.5);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

void fragment() {
	vec2 p = (UV - uv_center) / uv_half;
	float r = length(p);
	vec2 cell = floor((p * 0.5 + 0.5) * texels);
	// The phosphor: bright the moment the ring touches, then a long slow fade.
	vec3 hit = texture(hits, (cell + 0.5) / texels).rgb;
	float age = max(now - hit.r, 0.0);
	float glow = exp(-age * 3.0 / afterglow) + flare * exp(-age * 4.0);
	// The ring: a thin bright front with a faint wake behind it.
	float sweep = 0.0;
	if (ring >= 0.0) {
		float d = ring - r;
		sweep = smoothstep(ring_width, 0.0, abs(d)) * step(r, 1.0);
		sweep += d > 0.0 ? exp(-d / (ring_width * 6.0)) * wake : 0.0;
	}
	// Faint fixed markings: range circles and the ship (a short line pointing to the bow).
	float marks = 0.0;
	if (range_rings > 0.0) {
		float band = abs(fract(r * range_rings + 0.5) - 0.5) / range_rings;
		marks += (1.0 - smoothstep(0.0, 1.5 / texels, band)) * 0.035 * step(r, 1.0);
	}
	float along = dot(p, bow);
	float across = abs(dot(p, vec2(-bow.y, bow.x)));
	marks += step(across, 0.8 / texels) * step(-0.015, along) * step(along, 0.05) * 0.5;
	marks += (1.0 - smoothstep(0.96, 1.0, r)) * smoothstep(0.93, 0.99, r) * 0.08; // rim
	float speckle = (hash(cell + floor(now * 12.0)) - 0.5) * grain;
	vec3 lit = (creature_color * hit.g + land_color * hit.b) * glow + ring_color * sweep + marks_color * marks;
	vec3 col = (background + lit * energy) * max(1.0 + speckle, 0.0);
	ALBEDO = col * step(r, 1.0) * powered;
}

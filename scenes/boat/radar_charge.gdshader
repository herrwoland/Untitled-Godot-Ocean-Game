shader_type spatial;
// The radar's charge bar (radar.gd): fills along U while it charges; full, it breathes softly
// to say a ping is ready. Dark with the ship's power cut.
render_mode unshaded, cull_back, shadows_disabled;

uniform float fill = 1.0;
uniform float powered = 1.0;
uniform vec3 tint : source_color = vec3(0.35, 1.0, 0.55);
uniform float energy = 1.6;
uniform float now = 0.0;

void fragment() {
	float lit = step(UV.x, fill);
	float ready = step(1.0, fill) * (0.75 + 0.25 * sin(now * 3.0));
	float light = mix(0.03, mix(0.45, 1.0, ready), lit);
	ALBEDO = tint * light * energy * powered;
}

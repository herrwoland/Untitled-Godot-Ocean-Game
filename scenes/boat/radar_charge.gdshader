shader_type spatial;
// The radar's charge bar (radar.gd): fills from bar_from to bar_to (the mesh's own space)
// while it charges; full, it breathes softly to say a ping is ready. Dark with the power cut.
render_mode unshaded, cull_back, shadows_disabled;

uniform float fill = 1.0;
uniform float powered = 1.0;
uniform vec3 tint : source_color = vec3(0.35, 1.0, 0.55);
uniform float energy = 1.6;
uniform float now = 0.0;
uniform vec3 bar_from = vec3(-0.5, 0.0, 0.0);
uniform vec3 bar_to = vec3(0.5, 0.0, 0.0);

varying float along;

void vertex() {
	vec3 d = bar_to - bar_from;
	along = dot(VERTEX - bar_from, d) / max(dot(d, d), 1e-8);
}

void fragment() {
	float lit = step(along, fill);
	float ready = step(1.0, fill) * (0.75 + 0.25 * sin(now * 3.0));
	float light = mix(0.03, mix(0.45, 1.0, ready), lit);
	ALBEDO = tint * light * energy * powered;
}

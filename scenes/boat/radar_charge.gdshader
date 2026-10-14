shader_type spatial;
// The radar's charge bar (radar.gd): fills from bar_from to bar_to (the mesh's own space)
// while it charges; full, it breathes softly to say a ping is ready. Dark with the power cut.
render_mode unshaded, cull_back, shadows_disabled;

uniform float fill = 1.0;
uniform float powered = 1.0;
uniform vec3 empty_color : source_color = vec3(0.0168, 0.048, 0.0264);
uniform vec3 charging_color : source_color = vec3(0.252, 0.72, 0.396);
uniform vec3 ready_color : source_color = vec3(0.56, 1.6, 0.88);
uniform float pulse = 0.25;
uniform float pulse_speed = 3.0;
uniform float now = 0.0;
uniform vec3 bar_from = vec3(-0.5, 0.0, 0.0);
uniform vec3 bar_to = vec3(0.5, 0.0, 0.0);

varying float along;

void vertex() {
	vec3 d = bar_to - bar_from;
	along = dot(VERTEX - bar_from, d) / max(dot(d, d), 1e-8);
}

void fragment() {
	vec3 col = empty_color;
	if (fill >= 1.0) {
		col = ready_color * (1.0 - pulse + pulse * sin(now * pulse_speed));
	} else if (along <= fill) {
		col = charging_color;
	}
	ALBEDO = col * powered;
}

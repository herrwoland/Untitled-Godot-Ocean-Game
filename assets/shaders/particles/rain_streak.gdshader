shader_type spatial;
// Rain streaks: thin quads stretched along the fall direction, turned to face the camera around
// that axis. Hard-edged and dithered (PS1), lit by scattering like the marine snow: brightest
// when between the camera and a light, so lamps and lightning catch the rain.
render_mode cull_disabled, shadows_disabled, ambient_light_disabled, specular_disabled;

uniform vec3 color : source_color = vec3(0.62, 0.66, 0.7);
/** Coverage of a streak (dithered): lower = fainter, finer rain. */
uniform float opacity : hint_range(0.0, 1.0, 0.01) = 0.45;
/** Brightness with no light on it. */
uniform float ambient_glow : hint_range(0.0, 2.0, 0.01) = 0.35;
uniform float light_scatter : hint_range(0.0, 8.0, 0.01) = 1.5;
uniform float forward_scatter : hint_range(0.0, 0.95, 0.01) = 0.7;

float bayer4(vec2 p) {
	ivec2 i = ivec2(mod(p, 4.0));
	int m[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[i.y * 4 + i.x]) + 0.5) / 16.0;
}

void vertex() {
	// Axis-aligned billboard: keep the streak's length axis, face the camera around it.
	vec3 axis = MODEL_MATRIX[1].xyz;
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 to_cam = normalize(CAMERA_POSITION_WORLD - origin);
	vec3 side = normalize(cross(axis, to_cam)) * length(MODEL_MATRIX[0].xyz);
	vec3 world = origin + side * VERTEX.x * 2.0 + axis * VERTEX.y;
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	MODELVIEW_MATRIX = mat4(1.0);
	MODELVIEW_NORMAL_MATRIX = mat3(1.0);
}

void fragment() {
	float along = UV.y; // 0 = head, 1 = tail: fade the tail.
	float coverage = opacity * mix(1.0, 0.25, along);
	if (coverage < bayer4(FRAGCOORD.xy)) discard;
	ALBEDO = color;
	NORMAL = vec3(0.0, 0.0, 1.0);
	EMISSION = color * ambient_glow;
}

float scatter_phase(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5);
}

void light() {
	float phase = min(scatter_phase(dot(LIGHT, -VIEW), forward_scatter), 4.0);
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * phase * light_scatter / PI;
}

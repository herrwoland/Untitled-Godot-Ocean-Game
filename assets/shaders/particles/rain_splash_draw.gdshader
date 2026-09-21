shader_type spatial;
// Draws rain splash pieces (see rain_splash.gdshader): droplets as camera-facing square specks,
// rings as flat pixelated rings lying on the surface. Hard-edged, fading out by dithering (PS1),
// lit by scattering like the rain streaks.
render_mode cull_disabled, shadows_disabled, ambient_light_disabled, specular_disabled;

uniform vec3 color : source_color = vec3(0.85, 0.9, 0.9);
/** Pixels across a ring (its shape is snapped to this grid). */
uniform float ring_pixels = 10.0;
/** Rings are fainter than droplets. */
uniform float ring_opacity : hint_range(0.0, 1.0, 0.01) = 0.9;
uniform float ambient_glow : hint_range(0.0, 2.0, 0.01) = 0.5;
uniform float light_scatter : hint_range(0.0, 8.0, 0.01) = 1.5;

varying float is_ring;

float bayer4(vec2 p) {
	ivec2 i = ivec2(mod(p, 4.0));
	int m[16] = int[](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
	return (float(m[i.y * 4 + i.x]) + 0.5) / 16.0;
}

void vertex() {
	is_ring = INSTANCE_CUSTOM.x;
	vec3 origin = MODEL_MATRIX[3].xyz;
	float s = length(MODEL_MATRIX[0].xyz);
	vec3 world;
	if (is_ring > 0.5) {
		world = origin + vec3(VERTEX.x, 0.0, VERTEX.y) * 2.0 * s; // Flat on the surface.
	} else {
		world = origin + (INV_VIEW_MATRIX[0].xyz * VERTEX.x + INV_VIEW_MATRIX[1].xyz * VERTEX.y) * s;
	}
	VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
	MODELVIEW_MATRIX = mat4(1.0);
	MODELVIEW_NORMAL_MATRIX = mat3(1.0);
}

void fragment() {
	float alpha = smoothstep(0.0, 0.4, COLOR.a); // Solid for most of its life, dithers out at the end.
	if (is_ring > 0.5) {
		vec2 uv = (floor(UV * ring_pixels) + 0.5) / ring_pixels;
		float r = length(uv - 0.5) * 2.0;
		// Thin ring that gets thinner as it spreads (alpha falls with age).
		float width = mix(0.2, 0.35, COLOR.a);
		if (abs(r - (1.0 - width * 0.5)) > width * 0.5) discard;
		alpha *= ring_opacity;
	}
	if (alpha < bayer4(FRAGCOORD.xy)) discard;
	ALBEDO = color;
	NORMAL = vec3(0.0, 0.0, 1.0);
	EMISSION = color * ambient_glow;
}

void light() {
	DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * light_scatter / PI;
}

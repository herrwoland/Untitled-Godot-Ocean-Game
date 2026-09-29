shader_type spatial;
/**
 * Glow laid over something the player can interact with (material_overlay).
 * Sits exactly on the surface instead of growing the mesh: growing pushes every
 * vertex along its normal, and on a flat-shaded model each face has its own
 * normals, so the faces drift apart and the model shows through the seams.
 * Here the whole mesh is pulled a few millimetres towards the camera instead,
 * which keeps it in one piece and still wins the depth test against the model.
 */
render_mode unshaded, blend_mix, depth_draw_never, cull_back, fog_disabled;

uniform vec4 color : source_color = vec4(1.0, 0.9, 0.2, 1.0);
/** Opacity over the whole surface. */
uniform float fill : hint_range(0.0, 1.0) = 0.3;
/** Extra opacity on edges seen side-on, which outlines the shape. */
uniform float rim : hint_range(0.0, 1.0) = 0.35;
uniform float rim_sharpness : hint_range(0.5, 8.0) = 2.0;
/** Brightness (above 1 it blooms). */
uniform float energy : hint_range(0.0, 4.0) = 1.5;
/** Gentle breathing of the glow: speed (per second) and depth (0 = steady). */
uniform float pulse_speed : hint_range(0.0, 10.0) = 0.0;
uniform float pulse_amount : hint_range(0.0, 1.0) = 0.0;
/** How far the glow is pulled towards the camera (m), to stay on top of the model. */
uniform float surface_offset : hint_range(0.0, 0.1, 0.001) = 0.01;

void vertex() {
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float dist = length(view.xyz);
	view.xyz *= max(dist - surface_offset, dist * 0.5) / max(dist, 1e-4);
	POSITION = PROJECTION_MATRIX * view;
}

void fragment() {
	float edge = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), rim_sharpness);
	float pulse = 1.0 - pulse_amount * (0.5 + 0.5 * sin(TIME * pulse_speed * TAU));
	ALBEDO = color.rgb * energy;
	ALPHA = clamp((fill + rim * edge) * color.a * pulse, 0.0, 1.0);
}

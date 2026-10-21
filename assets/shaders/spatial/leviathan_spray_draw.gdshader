shader_type spatial;
// How the leviathan's spray is drawn (see leviathan_splash.gd). Each quad turns to the eye, but it is
// lit as if it faced the sky, like the sea's own surface: spray scatters light every way, so it
// must not go dark just because the moon is behind it (a plume against the sky then stood there
// like smoke). It takes the scene's real light, so it follows day, moon, storm and exposure.
render_mode blend_mix, depth_draw_never, cull_disabled, diffuse_lambert_wrap, specular_disabled;

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec4 tint : source_color = vec4(1.0);
/** 0: turns freely to the eye, spun by INSTANCE_CUSTOM.x (puffs, mist). 1: turns only about its own
 *  Y axis (a sheet standing upright, a drop streaking along its flight). */
uniform int axis_mode = 0;
/** Fades out this close to the eye (m), so a sheet never walls off the view from inside the mouth. */
uniform float fade_near = 6.0;
uniform float fade_far = 40.0;

void vertex() {
	vec3 sx = vec3(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz), length(MODEL_MATRIX[2].xyz));
	if (axis_mode == 1) {
		vec3 y = normalize(MODEL_MATRIX[1].xyz);
		vec3 to_eye = normalize(CAMERA_POSITION_WORLD - MODEL_MATRIX[3].xyz);
		vec3 x = cross(y, to_eye);
		x = length(x) > 1e-4 ? normalize(x) : normalize(cross(y, vec3(0.0, 0.0, 1.0)));
		vec3 z = cross(x, y);
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(vec4(x * sx.x, 0.0), vec4(y * sx.y, 0.0), vec4(z * sx.z, 0.0), MODEL_MATRIX[3]);
	} else {
		float a = INSTANCE_CUSTOM.x;
		mat4 spin = mat4(vec4(cos(a), -sin(a), 0.0, 0.0), vec4(sin(a), cos(a), 0.0, 0.0), vec4(0.0, 0.0, 1.0, 0.0), vec4(0.0, 0.0, 0.0, 1.0));
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0] * sx.x, INV_VIEW_MATRIX[1] * sx.x, INV_VIEW_MATRIX[2] * sx.x, MODEL_MATRIX[3]) * spin;
	}
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec4 c = texture(tex, UV) * COLOR * tint;
	ALBEDO = c.rgb;
	ALPHA = c.a * smoothstep(fade_near, fade_far, -VERTEX.z);
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz); // faces the sky
	ROUGHNESS = 1.0;
}

#[compute]
#version 450
// Builds a tiling "light focus" map for the largest wave cascade: how much the surface
// concentrates sunlight at a given depth below it. Wave crests act as lenses; the bright
// lines this produces become the underwater light shafts (see underwater_post.glsl).
//
// A beam hitting the surface at x with slope gradient g is bent sideways by roughly
// -k * g per meter of depth, so at depth D it lands at x - D*k*g. Light intensity there is
// 1 / det(Jacobian) = 1 / det(I - D*k * dg/dx).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(r16f, set = 0, binding = 0) uniform restrict writeonly image2D focus_image;
layout(set = 0, binding = 1) uniform sampler2DArray normals; // xy = slope gradient (unscaled)

layout(push_constant, std430) uniform PushConstant {
	float texel_meters;  // World size of one focus texel.
	float normal_scale;  // Cascade normal scale (map_scales[0].w).
	float focus;         // D * k: focus depth times refraction bend factor.
	float size;          // Focus map resolution.
} pc;

// Slopes are differenced over several texels: this low-passes out the small ripples so only
// the big storm waves focus light, giving broad shafts instead of fine hair-like lines.
const float SPAN = 3.0;

vec2 slope(vec2 uv) {
	return textureLod(normals, vec3(uv, 0.0), 0.0).xy * pc.normal_scale;
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(px, ivec2(pc.size)))) return;
	vec2 uv = (vec2(px) + 0.5) / pc.size;
	vec2 e = vec2(SPAN / pc.size, 0.0);

	// Jacobian of the slope field (per meter) by central differences.
	vec2 dgdx = (slope(uv + e.xy) - slope(uv - e.xy)) / (2.0 * SPAN * pc.texel_meters);
	vec2 dgdz = (slope(uv + e.yx) - slope(uv - e.yx)) / (2.0 * SPAN * pc.texel_meters);
	mat2 jacobian = mat2(1.0) - pc.focus * mat2(dgdx, dgdz);
	float intensity = 1.0 / max(abs(determinant(jacobian)), 0.05);

	imageStore(focus_image, px, vec4(min(intensity, 12.0), 0.0, 0.0, 1.0));
}

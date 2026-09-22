#[versions]

scroll = "#define MODE_SCROLL";
update = "";

#[compute]

#version 450

#VERSION_DEFINES
// Ship wake trail map (see wake_map.gd): a world-space texture around the camera holding
//   r = foam strength, g = churn strength (turbulent water: lighter tint, flatter waves),
//   b = foam life left (1 -> 0), a = churn life left. Life is stored apart from strength so a
//   faint wake lasts just as long as a strong one; the water shader draws strength * life.
// `scroll` copies the map into a scratch texture, shifted when the map's centre moves.
// `update` reads that copy, lets the trail spread and fade, and stamps new wake segments.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict readonly image2D src_image;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D dst_image;

#ifndef MODE_SCROLL
layout(set = 0, binding = 2, std140) uniform Stamps {
	vec4 params;    // x foam life lost this frame, y churn life lost, z spread (0..0.25), w stamp count
	vec4 map_rect;  // xy world xz of texel (0,0), z world size of the map (m), w resolution
	vec4 seg_a[16]; // Segment start xz, end xz (m).
	vec4 seg_b[16]; // x half width (m), y foam, z churn, w edge bias (0 = even, 1 = foam at the sides)
} s;
#endif

#ifdef MODE_SCROLL
layout(push_constant, std430) uniform PushConstant {
	ivec2 shift; // Texels the map moved since last frame.
	ivec2 pad;
} pc;
#endif

vec4 load_clamped(ivec2 px, ivec2 size) {
	if (any(lessThan(px, ivec2(0))) || any(greaterThanEqual(px, size))) return vec4(0.0);
	return imageLoad(src_image, px);
}

void main() {
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(dst_image);
	if (any(greaterThanEqual(px, size))) return;

#ifdef MODE_SCROLL
	imageStore(dst_image, px, load_clamped(px + pc.shift, size));
#else
	// Spread: a little diffusion each frame widens the trail as it ages (the V of the wake).
	vec4 c = load_clamped(px, size);
	vec4 n = load_clamped(px + ivec2(1, 0), size) + load_clamped(px - ivec2(1, 0), size)
	       + load_clamped(px + ivec2(0, 1), size) + load_clamped(px - ivec2(0, 1), size);
	vec4 v = mix(c, n * 0.25, s.params.z);
	// Life runs down linearly, so a wake lasts exactly `wake_lifetime` whatever its strength.
	v.b = max(v.b - s.params.x, 0.0);
	v.a = max(v.a - s.params.y, 0.0);
	if (v.b <= 0.0) v.r = 0.0;
	if (v.a <= 0.0) v.g = 0.0;

	vec2 world = s.map_rect.xy + (vec2(px) + 0.5) / s.map_rect.w * s.map_rect.z;
	int count = int(s.params.w);
	for (int i = 0; i < count; i++) {
		vec2 a = s.seg_a[i].xy;
		vec2 b = s.seg_a[i].zw;
		vec2 ab = b - a;
		float t = clamp(dot(world - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
		float d = length(world - (a + ab * t)) / max(s.seg_b[i].x, 0.01); // 0 on the line, 1 at the edge.
		if (d >= 1.0) continue;
		float body = 1.0 - d * d;
		float profile = mix(body, smoothstep(0.3, 0.9, d) * body * 3.0, s.seg_b[i].w);
		if (s.seg_b[i].y * profile > 0.001) {
			v.r = max(v.r, s.seg_b[i].y * profile);
			v.b = 1.0;
		}
		if (s.seg_b[i].z * body > 0.001) {
			v.g = max(v.g, s.seg_b[i].z * body);
			v.a = 1.0;
		}
	}
	imageStore(dst_image, px, clamp(v, 0.0, 1.0));
#endif
}

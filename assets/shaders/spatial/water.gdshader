shader_type spatial;
render_mode world_vertex_coords, depth_draw_always, cull_disabled;
/**
 * Water lighting model roughly follows the 2019 GDC talk: "Wakes, Explosions and Lighting: Interactive Water Simulation in Atlas".
 * Source: https://gpuopen.com/gdc-presentations/2019/gdc-2019-agtd6-interactive-water-simulation-in-atlas.pdf
 */

#define MAX_CASCADES 8    // I am unsure how to generalize this.
#define REFLECTANCE  0.02 // Reflectance from air to water (eta=1.33).

global uniform vec4 water_color : source_color;
global uniform vec4 foam_color : source_color;
uniform bool backface_culling = true; // Toggle in the material inspector: discards back faces when on.
uniform vec3 depth_color_consumption = vec3(7.5, 22.0, 38.0);

// Radial water shapes (domes, ring swells) from WaterDeformer nodes. Set every frame by water.gd.
group_uniforms water_shapes;
uniform int water_shape_count = 0;
uniform vec4 water_shape_a[16];
uniform vec4 water_shape_b[16];
group_uniforms;

group_uniforms wave_blockers;
uniform int wave_blocker_count = 0;
uniform vec4 wave_blocker_a[8]; // (pos.x, pos.z, cos yaw, sin yaw)
uniform vec4 wave_blocker_b[8]; // (half x / radius, half z, fade width, flags: +1 box, +2 hole)
group_uniforms;


uniform float roughness : hint_range(0.0, 1.0) = 0.4;
uniform float normal_strength : hint_range(0.0, 1.0) = 1.0; // Global normal strength
uniform sampler2D foam_noise_tex : repeat_enable, filter_linear_mipmap;

uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;

group_uniforms cascade_data;
uniform vec4 map_scales[MAX_CASCADES];               // Scales for displacement/normal maps. Packed: [uv scale, displacement scale, normal scale]
global uniform uint num_cascades;
global uniform sampler2DArray displacements;         // Each layer represents one wave cascade.
global uniform sampler2DArray normals : hint_normal; // Each layer represents one wave cascade.

group_uniforms underwater;
/** Index of refraction of water. Sets the size of Snell's window (~97 degree cone at 1.333). */
uniform float water_ior : hint_range(1.0, 2.0) = 1.333;
/** Per-channel IOR spread, gives the edge of Snell's window a faint rainbow fringe. */
uniform float ior_dispersion : hint_range(0.0, 0.05) = 0.01;
/** How strongly the refracted ray bends the screen sample. 1.0 = physically based offset. */
uniform float window_refraction_strength : hint_range(0.0, 1.5) = 0.6;
/** Brightness of the world seen through Snell's window. */
uniform float window_brightness : hint_range(0.0, 4.0) = 1.0;
/** Blur toward the edge of the window, where the whole horizon gets squeezed together. */
uniform float window_edge_blur : hint_range(0.0, 6.0) = 3.0;
/** Colour of the lit water column, seen through total internal reflection. Also the underwater fog colour. */
uniform vec3 underwater_color : source_color = vec3(0.04, 0.13, 0.14);
/** Per-meter extinction (r, g, b) used by the underwater screen effect. Red dies first. */
uniform vec3 underwater_absorption = vec3(0.22, 0.06, 0.05);
group_uniforms;

// Light shafts are drawn by underwater_effect.gd, not by this shader. Like the caustics below,
// they live here so the whole water look is tuned in one material.
group_uniforms light_shafts;
uniform bool shafts_enabled = true;
/** Overall brightness of the underwater light shafts. */
uniform float shaft_strength : hint_range(0.0, 2.0, 0.01) = 0.2;
/** Colour of the shafts (multiplied with the sun colour). */
uniform vec3 shaft_tint : source_color = vec3(1.0);
/** Caps how bright the shafts can glow. Lower = no blown-out beams towards the sun. */
uniform float shaft_max_brightness : hint_range(0.0, 4.0, 0.01) = 1.0;
/** Shapes the beams: > 1 = crisp defined rays, < 1 = soft hazy glow. */
uniform float shaft_contrast : hint_range(0.1, 4.0, 0.01) = 1.0;
/** How focused light must be to form a ray. Higher = fewer, stronger rays. */
uniform float shaft_threshold : hint_range(0.0, 3.0, 0.01) = 1.0;
/** Thin streaks (low) vs broad beams (high): how much small waves are smoothed away. */
uniform float shaft_softness : hint_range(1.0, 8.0, 0.1) = 3.0;
/** Pattern size. > 1 = more, narrower rays closer together. */
uniform float shaft_scale : hint_range(0.1, 4.0, 0.01) = 1.0;
/** Depth (m) at which the waves focus light most sharply. Deeper = thinner, more intense rays. */
uniform float shaft_focus_depth : hint_range(0.5, 40.0, 0.5) = 8.0;
/** How far from the camera shafts are gathered (m). */
uniform float shaft_max_distance : hint_range(5.0, 150.0, 1.0) = 40.0;
/** Forward scattering. Higher = shafts concentrate towards the sun, fade looking away from it. */
uniform float shaft_scattering : hint_range(0.0, 0.95, 0.01) = 0.6;
/** Ray march samples per pixel. Fewer = faster but grainier. */
uniform int shaft_quality : hint_range(4, 64) = 24;
group_uniforms;

// Caustics are drawn by caustics_effect.gd, not by this shader. They live here so the whole
// water look is tuned in one material; water.gd forwards them to the effect every frame.
group_uniforms caustics;
uniform bool caustics_enabled = true;
/** Overall brightness of the caustic light net. */
uniform float caustic_strength : hint_range(0.0, 5.0, 0.01) = 0.6;
/** Colour of the caustic light (multiplied with the sun colour). */
uniform vec3 caustic_tint : source_color = vec3(1.0);
/** Caps how bright a caustic line can get. Lower = no blown-out hot spots. */
uniform float caustic_max_brightness : hint_range(0.0, 10.0, 0.01) = 1.5;
/** Shapes the lines: > 1 = thin crisp lines, < 1 = soft broad light. */
uniform float caustic_contrast : hint_range(0.1, 4.0, 0.01) = 1.0;
/** How much the gaps between lines darken (light the waves focus away). 0 = only add light. */
uniform float caustic_darkening : hint_range(0.0, 1.0, 0.01) = 0.5;
/** Pattern size. > 1 = smaller, denser net. */
uniform float caustic_scale : hint_range(0.1, 8.0, 0.01) = 1.0;
/** Depth (m) where caustics are sharpest. Higher also focuses harder: thinner, brighter lines. */
uniform float caustic_focus_depth : hint_range(0.5, 30.0, 0.1) = 6.0;
/** Below the focus depth, caustics fade out over roughly this many meters. */
uniform float caustic_fade_depth : hint_range(0.5, 60.0, 0.1) = 9.0;
/** Rainbow split at the caustic edges. */
uniform float caustic_dispersion : hint_range(0.0, 0.03, 0.0005) = 0.004;
/** Wave cascade that draws the caustics (-1 = smallest waves). Mid-sized waves make the classic net. */
uniform int caustic_cascade : hint_range(-1, 7) = 1;
group_uniforms;

varying float wave_height;
varying float foam_factor;
varying float fresnel;
varying float blocker_mask;
varying float blocker_hole;
varying float underside; // 1.0 when this fragment is the water surface seen from below.

// Wave-blocker attenuation at a rest position (pre-displacement). Returns
// (mask, hole): mask 0 inside a blocker rising to 1 across its fade width;
// hole 1 inside a HOLE blocker (surface discarded there).
// Must mirror distance_xz() in wave_blocker.gd exactly.
vec2 wave_blocker_eval(vec2 p) {
	float mask = 1.0;
	float hole = 0.0;
	for (int i = 0; i < wave_blocker_count; i++) {
		vec4 a = wave_blocker_a[i];
		vec4 b = wave_blocker_b[i];
		vec2 rel = p - a.xy;
		int flags = int(b.w + 0.5);
		float d;
		if ((flags & 1) == 1) { // box footprint, rotated by yaw
			vec2 lp = vec2(a.z*rel.x + a.w*rel.y, -a.w*rel.x + a.z*rel.y);
			vec2 q = abs(lp) - b.xy;
			d = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
		} else { // circle footprint
			d = length(rel) - b.x;
		}
		mask = min(mask, smoothstep(0.0, max(b.z, 0.001), d));
		if (flags >= 2 && d <= 0.0) {
			hole = 1.0;
		}
	}
	return vec2(mask, hole);
}

// Sum of all water shapes at a rest position. Returns (height, dh/dx, dh/dz, calm); `foam` gets
// the white water they add. Must mirror water_shapes_eval() in water.gd and water_shapes.glsli.
//   dome: a = (x, z, width, height), b = (trough, calm, 0, foam)
//   ring: a = (x, z, radius, amplitude), b = (width, 0, 1, foam)
vec4 water_shapes_eval(vec2 p, out float foam) {
	vec4 result = vec4(0.0);
	foam = 0.0;
	for (int i = 0; i < water_shape_count; i++) {
		vec4 a = water_shape_a[i];
		vec4 b = water_shape_b[i];
		vec2 rel = p - a.xy;
		if (b.z < 0.5) {
			// Gaussian dome, with an optional trough ring around it: h = H e^-q (1 - t q).
			float w2 = a.z * a.z;
			float q = dot(rel, rel) / w2;
			if (q > 16.0) continue;
			float e = exp(-q);
			float h = a.w * e * (1.0 - b.x * q);
			vec2 grad = -a.w * e * (1.0 + b.x - b.x * q) * 2.0 * rel / w2;
			result.xyz += vec3(h, grad);
			result.w = max(result.w, b.y * e);
			foam = max(foam, b.w * clamp(length(grad) * 1.5, 0.0, 1.0)); // Water sheeting off steep flanks.
		} else {
			// Gaussian swell travelling outwards.
			float r = length(rel);
			float u = (r - a.z) / b.x;
			if (abs(u) > 4.0) continue;
			float g = exp(-u * u);
			result.xyz += vec3(a.w * g, a.w * g * (-2.0 * u / b.x) * rel / max(r, 1e-3));
			foam = max(foam, b.w * g * clamp(a.w, 0.0, 1.0));
		}
	}
	return result;
}

void vertex() {
	UV = VERTEX.xz;
	float shape_foam;
	vec4 shape = water_shapes_eval(VERTEX.xz, shape_foam);
	vec2 blocker = wave_blocker_eval(VERTEX.xz);
	blocker_mask = blocker.x;
	blocker_hole = blocker.y;
	// is optimized: first check if the distance is greater than 150 meters.
	// if so, then don't calculate the displacement.
	float distance_cam = length(VERTEX.xz - CAMERA_POSITION_WORLD.xz);
	if (distance_cam < 1024.0) // fall of to 0 at 600 meters
	{
		float distance_factor = min(exp(-(distance_cam-512.0)*0.007), 1.0); // Displacement amonut falls off after 256m.

		// Read displacements from displacement maps.
		vec3 displacement = vec3(0);
		for (uint i = 0U; i < num_cascades; ++i) {
			vec4 scales = map_scales[i];
			displacement += texture(displacements, vec3(UV*scales.xy, float(i))).xyz * scales.z;
		}
		float wave_scale = blocker_mask * (1.0 - shape.w); // Domes smooth out the waves riding on them.
		VERTEX += displacement * distance_factor * wave_scale;
		wave_height = displacement.y * wave_scale;
	}
	else
	{
		wave_height = 0.0;
	}
	VERTEX.y += shape.x;
	wave_height += shape.x;
}

/** Filter weights for a cubic B-spline. */
vec4 cubic_weights(float a) {
	float a2 = a*a;
	float a3 = a2*a;

	float w0 =-a3     + a2*3.0 - a*3.0 + 1.0;
	float w1 = a3*3.0 - a2*6.0         + 4.0;
	float w2 =-a3*3.0 + a2*3.0 + a*3.0 + 1.0;
	float w3 = a3;
	return vec4(w0, w1, w2, w3) / 6.0;
}

/** Performs bicubic B-spline filtering on the provided sampler. */
// Source: https://developer.nvidia.com/gpugems/gpugems2/part-iii-high-quality-rendering/chapter-20-fast-third-order-texture-filtering
vec4 texture_bicubic(in sampler2DArray sampler, in vec3 uvw) {
	vec2 dims = vec2(textureSize(sampler, 0).xy);
	vec2 dims_inv = 1.0 / dims;
	uvw.xy = uvw.xy*dims + 0.5;

	vec2 fuv = fract(uvw.xy);
	vec4 wx = cubic_weights(fuv.x);
	vec4 wy = cubic_weights(fuv.y);

	vec4 g = vec4(wx.xz + wx.yw, wy.xz + wy.yw);
	vec4 h = (vec4(wx.yw, wy.yw) / g + vec2(-1.5, 0.5).xyxy + floor(uvw.xy).xxyy)*dims_inv.xxyy;
	vec2 w = g.xz / (g.xz + g.yw);
	return mix(
		mix(texture(sampler, vec3(h.yw, uvw.z)), texture(sampler, vec3(h.xw, uvw.z)), w.x),
		mix(texture(sampler, vec3(h.yz, uvw.z)), texture(sampler, vec3(h.xz, uvw.z)), w.x), w.y);
}

/** Samples the screen with mirrored edges, so strongly bent rays don't smear the border pixels. */
vec3 screen_mirrored(in sampler2D tex, vec2 uv, float lod) {
	uv = 1.0 - abs(1.0 - abs(uv)); // Mirror into [0, 1] (valid for uv in [-1, 2]).
	return textureLod(tex, clamp(uv, vec2(0.001), vec2(0.999)), lod).rgb;
}

/**
 * Shades the water surface as seen from below: Snell's window + total internal reflection.
 * All vectors in view space. `n` is the surface normal facing the (underwater) camera.
 * Returns rgb = colour, a = average transmittance (how much of the air world is visible).
 */
vec4 shade_underside(vec3 view, vec3 n, vec2 screen_uv, float foam) {
	vec3 incident = -view;
	vec3 etas = water_ior + vec3(-1.0, 0.0, 1.0) * ior_dispersion;
	vec3 transmitted = vec3(0.0);
	vec3 transmittance = vec3(0.0);
	for (int c = 0; c < 3; c++) {
		vec3 t = refract(incident, n, etas[c]);
		if (dot(t, t) < 1e-6) continue; // Total internal reflection: nothing from above gets through.

		// Fresnel for the water->air interface must use the angle on the air side.
		float cos_t = clamp(dot(t, -n), 0.0, 1.0);
		float tr = 1.0 - (REFLECTANCE + (1.0 - REFLECTANCE) * pow(1.0 - cos_t, 5.0));
		// Bend the screen lookup by how far the refracted ray deviates from the straight one.
		vec2 bend = (t - incident).xy * window_refraction_strength;
		vec2 uv = screen_uv + vec2(bend.x, -bend.y);
		transmitted[c] = screen_mirrored(screen_texture, uv, (1.0 - cos_t) * window_edge_blur)[c];
		transmittance[c] = tr;
	}

	// Outside the window the surface is a mirror of the water column below it.
	vec3 color = transmitted * transmittance * window_brightness + underwater_color * (1.0 - transmittance);

	// Foam blocks the window: dark silhouettes against the sky, pale against the depths.
	// (foam can exceed 1 since foam_alpha sums over cascades; clamp so mix() can't overshoot.)
	float avg_t = dot(transmittance, vec3(1.0 / 3.0));
	color = mix(color, foam_color.rgb * mix(0.35, 0.12, avg_t), clamp(foam, 0.0, 1.0));

	// Absorption between the camera and the surface is applied by the underwater screen effect
	// (underwater_effect.gd), which also covers everything else seen underwater.
	return vec4(color, avg_t);
}

void fragment() {
	if (backface_culling && !FRONT_FACING) {
		discard;
	}
	if (blocker_hole > 0.5) {
		discard; // inside a HOLE wave blocker there is no water surface at all
	}
	float map_size = float(textureSize(normals, 0).x);
	float dist = length(VERTEX.xz);
	// Read foam and normal information from normal maps.
	vec3 gradient = vec3(0);
	float foam_alpha = 0.0;
	for (uint i = 0U; i < num_cascades; ++i) {
		vec4 scales = map_scales[i];
		vec3 coords = vec3(UV*scales.xy, float(i));
		float ppm = map_size * min(scales.x, scales.y); // Pixels per meter
		// Mix between bicubic and bilinear filtering depending on the world space pixels per meter.
		// This is dependent on the tile size as well as displacement/normal map resolution.
		gradient += mix(texture_bicubic(normals, coords), texture(normals, coords), min(1.0, ppm*0.1)).xyw * vec3(scales.ww, 1.0);
		foam_alpha += texture(foam_noise_tex, UV * scales.xy * 1.0).r;
	}
	gradient *= blocker_mask; // calm zones lose their wave normals and foam too
	float shape_foam;
	vec4 shape = water_shapes_eval(UV, shape_foam);
	gradient.xy *= 1.0 - shape.w;
	foam_factor = max(smoothstep(0.0, 1.0, gradient.z*0.75) * exp(-dist*0.0075), shape_foam);

	// A back face is only the underside if the camera is actually below it. Otherwise it's a
	// folding storm crest seen from above, which should keep the regular top shading.
	vec3 world_frag = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	underside = (!FRONT_FACING && CAMERA_POSITION_WORLD.y < world_frag.y) ? 1.0 : 0.0;

	if (underside > 0.5) {
		gradient *= mix(0.015, normal_strength, exp(-length(VERTEX)*0.0175));
		gradient.xy += shape.yz; // Water shapes are large and smooth, never faded with distance.
		vec3 n_down = (VIEW_MATRIX * vec4(-normalize(vec3(-gradient.x, 1.0, -gradient.y)), 0.0)).xyz;
		vec4 under = shade_underside(VIEW, n_down, SCREEN_UV, foam_factor * foam_alpha * foam_alpha);

		// Unlit: everything comes from the refracted/reflected light computed above.
		NORMAL = n_down;
		ALBEDO = vec3(0.0);
		EMISSION = under.rgb;
		SPECULAR = 0.0;
		ROUGHNESS = 1.0;
		RADIANCE = vec4(0.0, 0.0, 0.0, 1.0);
		IRRADIANCE = vec4(0.0, 0.0, 0.0, 1.0);
		ALPHA = 1.0;
		fresnel = 0.0;
	} else {
	// ===================== shine through ===================================#
	// Proximity Fade
	float depth_tex = texture(depth_texture, SCREEN_UV).r;
	//float depth_tex_blur = textureLod(depth_texture, SCREEN_UV, 16.0).r;
	//if (depth_tex > 0.0001 && abs(depth_tex - depth_tex_blur) < 0.000001)
		//{ALPHA *= 0.99;}
	vec4 world_pos = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_tex, 1.0);
	world_pos.xyz /= world_pos.w;
	float smooth_alpha = 1.0 - smoothstep(world_pos.z + 0.66, world_pos.z, VERTEX.z);
	ALPHA *= clamp(smooth_alpha, 0.00, 1.0);
	if (ALPHA < 0.9){
		foam_factor = clamp(foam_factor + 0.5 - ALPHA, 0.0, 1.0);
	}

	// Depth color tinting of submerged objects
	float depth_visibility_range = clamp(max(depth_color_consumption.r, max(depth_color_consumption.g,depth_color_consumption.b)),0.0,200.0);
	float factor_translucency =  1.0 - smoothstep(world_pos.z + depth_visibility_range, world_pos.z, VERTEX.z);
	factor_translucency = clamp(factor_translucency,0.35,1.0);
	vec3 screen_albedo = texture(screen_texture, SCREEN_UV, 0.0).rgb;
	vec3 depth_water_color = mix(screen_albedo, water_color.rgb, factor_translucency);

	float smooth_red = 0.0 + smoothstep(world_pos.z + depth_color_consumption.r, world_pos.z, VERTEX.z);
	float smooth_green = 0.0 + smoothstep(world_pos.z + depth_color_consumption.g, world_pos.z, VERTEX.z);
	float smooth_blue = 0.0 + smoothstep(world_pos.z + depth_color_consumption.b, world_pos.z, VERTEX.z);
	vec3 color_shallow = max(vec3(smooth_red, smooth_green, smooth_blue) * depth_water_color, water_color.rgb);
	//vec3 color_shallow = vec3(smooth_red, smooth_green, smooth_blue) * depth_water_color;


	depth_water_color = mix(color_shallow, water_color.rgb, factor_translucency);
	// ===================== shine through ===================================#
	ALBEDO = mix(depth_water_color, foam_color.rgb, foam_factor * foam_alpha * foam_alpha);
	fresnel = mix(pow(1.0 - dot(VIEW, NORMAL), 5.0*exp(-2.69*roughness)) / (1.0 + 22.7*pow(roughness, 1.5)), 1.0, REFLECTANCE);
	ROUGHNESS = (1.0 - fresnel) * foam_factor + 0.4; // Roughness is proportional to foam/fog amount and fresnel.

	gradient *= mix(0.015, normal_strength, exp(-dist*0.0175)); // Blend normal with terrain normal as distance increases.
	gradient.xy += shape.yz; // Water shapes are large and smooth, never faded with distance.
	NORMAL = (VIEW_MATRIX * vec4(normalize(vec3(-gradient.x, 1.0, -gradient.y)), 0.0)).xyz;
	}
}

float smith_masking_shadowing(in float cos_theta, in float alpha) {
	float a = cos_theta / (alpha * sqrt(1.0 - cos_theta*cos_theta)); // Approximate: 1.0 / (alpha * tan(acos(cos_theta)))
	float a_sq = a*a;
	return a < 1.6 ? (1.0 - 1.259*a + 0.396*a_sq) / (3.535*a + 2.181*a_sq) : 0.0;
}

// Source: https://github.com/godotengine/godot/blob/7b56111c297f24304eb911fe75082d8cdc3d4141/drivers/gles3/shaders/scene.glsl#L995
float ggx_distribution(in float cos_theta, in float alpha) {
	float a_sq = alpha*alpha;
	float d = 1.0 + (a_sq - 1.0) * cos_theta * cos_theta;
	return a_sq / (PI * d*d);
}

void light() {
	if (underside < 0.5) { // Underside is fully shaded in fragment().
		vec3 halfway = normalize(LIGHT + VIEW);
		float dot_nl = max(dot(NORMAL, LIGHT), 2e-5);
		float dot_nv = max(dot(NORMAL, VIEW), 2e-5);

		// --- SPECULAR ---
		float light_mask = smith_masking_shadowing(roughness, dot_nv);
		float view_mask = smith_masking_shadowing(roughness, dot_nl);
		float microfacet_distribution = ggx_distribution(dot(NORMAL, halfway), roughness);
		float geometric_attenuation = 1.0 / (1.0 + light_mask + view_mask);
		SPECULAR_LIGHT += fresnel * microfacet_distribution * geometric_attenuation / (4.0 * dot_nv + 0.1) * ATTENUATION;

		// --- DIFFUSE ---
		const vec3 sss_modifier = vec3(0.9,1.15,0.85); // Subsurface scattering produces a 'greener' color.
		float sss_height = 1.0*max(0.0, wave_height + 2.5) * pow(max(dot(LIGHT, -VIEW), 0.0), 4.0) * pow(0.5 - 0.5 * dot(LIGHT, NORMAL), 3.0);
		float sss_near = 0.5*pow(dot_nv, 2.0);
		float lambertian = 0.5*dot_nl;
		DIFFUSE_LIGHT += mix((sss_height + sss_near) * sss_modifier / (1.0 + light_mask) + lambertian, foam_color.rgb, foam_factor) * (1.0 - fresnel) * ATTENUATION * LIGHT_COLOR;
	}
}

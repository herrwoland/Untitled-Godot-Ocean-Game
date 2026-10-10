#[compute]
#version 450
// The cloud map (see cloud_map.gd): the whole sky dome's clouds, stored by view direction,
// read by sky.gdshader. rgb = the clouds' light (already over black), a = how much of the
// sky behind still shows.
//
// Each frame refreshes one texel in sixteen (a different one of each 4x4 block in turn), at
// a fresh random spot inside the texel and a fresh random start along the ray, and blends
// the result into what the texel held. Texels outside the camera's view are only refreshed
// one round in eight, so the work goes where it's seen. Over a few frames every texel averages many samples:
// that is what lets the march afford fine detail without turning it into grain. Stored by
// direction, so turning the camera never smears it; only drifting clouds move through it.
//
// Map layout: x = azimuth (wraps), y = elevation from the horizon (row 0) to the zenith,
// rows packed tighter near the horizon where clouds are squeezed: v = (elevation / 90deg)^0.6.
//
// The clouds: a layer on a shell around a (stylised) planet. The 2D weather noise says
// where cloud may be; columns narrow toward the top (heaped cumulus) or not (a deck); big
// 3D fractal noise carves the body and finer noise frays it into wisps. Light: a short
// march toward the sun, Beer's law in three octaves (multiple scattering), a forward-peaked
// phase (silver rims toward the sun, where the deep glow fades so backlit cores go dark),
// darker undersides that haven't gathered light yet, sky light from above, sea bounce from
// below. Under heavy cloud, rain shafts; far away, haze.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D cloud_map;
layout(set = 0, binding = 1) uniform sampler2D weather_noise; // the sky material's noise_texture
layout(set = 0, binding = 2) uniform sampler3D detail_noise; // fractal 3D noise, tiles
layout(set = 0, binding = 3, std140) uniform Params {
	vec4 shape;    // coverage, density (per km), billow, cloud_detail
	vec4 layer;    // cloud_erosion, cloud_base (km), cloud_thickness (km), cloud_size (km per noise tile)
	vec4 motion;   // warp_strength, wind_speed (km/s), scud_speed_mult, rain_shafts
	vec4 world;    // wind_direction.xy, haze_distance (km), planet_radius (km)
	vec4 lit;      // cloud_lit_color (linear), silver_lining
	vec4 dark;     // cloud_dark_color (linear), sun_glow
	vec4 zenith;   // zenith_color (linear), time (s)
	vec4 horizon;  // horizon_color (linear), detail_size (km per 3D noise tile)
	vec4 light;    // direction toward the light, 1 = light enabled
	vec4 light_c;  // light colour (linear), frame number
	vec4 update;   // map width, map height, blend (0..1), cos of the view cone's half angle
	vec4 view;     // camera forward (xyz), 1 = refresh off-view texels this round
} p;

const int CLOUD_STEPS = 24;
const int FAR_STEPS = 6;
const int LIGHT_STEPS = 4;
const int RAIN_CURTAINS = 4;
const float PI = 3.14159265;

float hash12(vec2 v) {
	vec3 p3 = fract(vec3(v.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Distance along a ray from the camera (sea level) to the shell `altitude` km up.
float shell_distance(vec3 dir, float altitude) {
	float r = p.world.w + altitude;
	float b = p.world.w * dir.y;
	return -b + sqrt(max(b * b - p.world.w * p.world.w + r * r, 0.0));
}

float altitude_of(vec3 pos) {
	return length(pos + vec3(0.0, p.world.w, 0.0)) - p.world.w;
}

// Where in the sky there is cloud at all, 0..1, at `uv` (noise tiles); `cov` = local coverage.
float cloud_cover(vec2 uv, float lod, float cov) {
	float n = textureLod(weather_noise, uv, lod).r;
	n = (n - 0.5) * 2.4 + 0.5; // the noise sits mostly within 0.3..0.7
	// Above 0.8 coverage the threshold drops fast, so 1 closes the sky completely
	// (an overcast deck) rather than leaving the noise's lowest dips as clear holes.
	float lo = 1.0 - cov - max(cov - 0.8, 0.0) * 3.0;
	return smoothstep(lo, lo + 0.45, n);
}

// Fractal 3D noise stretched to 0..1, at `q` (km) with `size` km per tile.
float noise3d(vec3 q, float size, float lod) {
	return smoothstep(0.3, 0.75, textureLod(detail_noise, q / size, lod).r);
}

// Cloud density (0..1) at `pos` (km from the camera), h = height fraction in the layer.
float cloud_density(vec3 pos, float h, vec2 warp, vec3 drift3, float lod, bool fast, float cov) {
	if (h < -0.3 || h > 1.0) return 0.0;
	vec2 uv = pos.xz / p.layer.w + warp;
	float weather = cloud_cover(uv, lod, cov);
	if (weather <= 0.0) return 0.0;
	float billow = p.shape.z;
	// How tall this stretch of cloud grows, from a broader look at the weather: towers of
	// different heights, decks with thick and thin patches.
	float tallness = mix(0.35, 1.0, smoothstep(0.3, 0.7, textureLod(weather_noise, uv * 0.37 + vec2(0.71, 0.29), lod).r));
	float hc = h / tallness;
	// Decks hang lumpy undersides (heaps keep flat bases): big soft bulges sagging below the
	// layer's base and pockets reaching up into it, which is what gives a storm sky its
	// light and dark mottling seen from below.
	float sag = (textureLod(weather_noise, uv * 2.3 + drift3.xz * 0.05 / p.layer.w, lod).r - 0.5) * 2.2 * (1.0 - billow);
	float hb = h + sag * 0.25;
	if (hb < 0.0 && h < 0.0) return 0.0;
	weather *= smoothstep(0.0, 0.07, hb) * smoothstep(1.0, 0.65, hc); // crisp bases, crowns fade
	if (weather <= 0.0) return 0.0;
	// Heaped clouds narrow toward the top, which rounds their crowns; a deck hardly does.
	float shape = pow(weather, mix(0.6, 0.35 + 2.0 * smoothstep(0.1, 0.8, hc), billow));
	vec3 q = vec3(pos.x, h * p.layer.z, pos.z) + drift3;
	float den = shape - p.shape.w * 0.7 * noise3d(q, p.horizon.w, lod * 0.4);
	if (den <= 0.0) return 0.0;
	if (!fast) {
		// Two finer scales fray the edges into wisps and break up the surface.
		den -= p.layer.x * 0.28 * noise3d(q * 1.07 + vec3(0.0, drift3.y, 0.0), p.horizon.w * 0.27, lod * 0.4);
		den -= p.layer.x * 0.12 * noise3d(q * 0.93 - vec3(drift3.y * 2.0, 0.0, 0.0), p.horizon.w * 0.08, lod * 0.4);
	}
	return clamp(den * 3.0, 0.0, 1.0);
}

float henyey_greenstein(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5); // x 4pi: 1 = isotropic
}

vec4 march_clouds(vec3 dir, float jitter) {
	float cloud_base = p.layer.y;
	float cloud_thickness = p.layer.z;
	float cloud_size = p.layer.w;
	float haze_distance = p.world.z;
	float t_near = shell_distance(dir, max(cloud_base - cloud_thickness * 0.3 * (1.0 - p.shape.z), 0.05)); // decks sag below their base
	float t_far = shell_distance(dir, cloud_base + cloud_thickness);
	float max_distance = haze_distance * 3.0;
	if (t_near > max_distance) return vec4(0.0, 0.0, 0.0, 1.0);
	t_far = min(t_far, max_distance);

	float time = p.zenith.w;
	vec2 wind_dir = normalize(p.world.xy);
	vec2 drift = wind_dir * p.motion.y * time / cloud_size;
	float boil = time * p.motion.y * p.motion.z;
	vec3 drift3 = -vec3(wind_dir.x, -0.15, wind_dir.y) * boil; // the 3D noise drifts and rises
	vec2 noise_size = vec2(textureSize(weather_noise, 0));

	// Domain warp and regional weather, from where the ray enters the layer.
	vec2 entry = (dir.xz * t_near) / cloud_size;
	float swirl = textureLod(weather_noise, entry * 0.5 + drift * 0.3, 0.0).r * 12.566;
	vec2 warp = vec2(cos(swirl), sin(swirl)) * p.motion.x * 0.08 + drift;
	float region = textureLod(weather_noise, entry * 0.11 + drift * 0.1 + vec2(0.43, 0.17), 2.0).r;
	float coverage = p.shape.x;
	float cov = clamp(coverage + (region - 0.5) * 0.6 * (1.0 - coverage), 0.0, 1.0);

	vec3 to_light = p.light.xyz;
	vec3 light_color = p.light_c.rgb * p.light.w;
	// Under a closed sky the sunlight reaching any cloud has come through the deck around it:
	// dim and scattered, no bright rims. Fades in as coverage closes the sky.
	float overcast = smoothstep(0.75, 1.0, p.shape.x);
	float silver = p.lit.w * (1.0 - overcast);
	float cos_light = dot(dir, to_light);
	// Phases for the three scattering octaves. Toward the sun the deep, many-times-scattered
	// glow fades (backlit cores go dark) and the direct light through thin rims brightens.
	vec3 phase;
	for (int k = 0; k < 3; k++) {
		float spread = exp2(-float(k));
		phase[k] = spread * mix(henyey_greenstein(cos_light, -0.15 * spread), henyey_greenstein(cos_light, 0.85 * spread), 0.3 * silver);
	}
	phase.yz *= mix(0.1, 1.0, smoothstep(0.96, 0.3, cos_light));
	phase.x *= 1.0 + 1.5 * silver * pow(max(cos_light, 0.0), 4.0);
	vec3 sun_light = p.lit.rgb * light_color * mix(1.0, 0.25, overcast);
	vec3 sky_light = mix(p.horizon.rgb, p.zenith.rgb, 0.3) * 1.3;
	vec3 haze_color = p.horizon.rgb + light_color * p.dark.w * 0.5 * pow(max(cos_light, 0.0), 8.0);
	float light_reach = cloud_thickness * 0.7;
	float density = p.shape.y;

	vec3 light = vec3(0.0);
	float transmittance = 1.0;

	// Rain shafts, on curtains at set distances so each column of the sky meets the same
	// rain all the way up (streaks, not speckle); each curtain ends at the cloud base.
	float rain_shafts = p.motion.w;
	if (rain_shafts > 0.0) {
		vec3 rain_color = mix(p.horizon.rgb, p.lit.rgb * light_color, 0.5);
		vec2 flat_dir = normalize(dir.xz);
		float t_base = shell_distance(dir, cloud_base);
		for (int i = 0; i < RAIN_CURTAINS; i++) {
			float t = 3.0 * exp2(float(i)); // 3, 6, 12, 24 km
			if (t > t_base) break;
			vec3 pos = vec3(flat_dir.x, dir.y, flat_dir.y) * t;
			vec2 above = (pos.xz - wind_dir * (cloud_base - pos.y) * 0.03) / cloud_size + drift;
			// Rain falls in patches under the heaviest parts, even when the sky is closed.
			float heavy = smoothstep(0.55, 0.7, textureLod(weather_noise, above * 0.7 + vec2(0.31, 0.83), 3.0).r)
					* smoothstep(0.5, 1.0, cloud_cover(above, 3.0, min(coverage, 0.95)));
			float streaks = textureLod(weather_noise, above * 16.0 + vec2(0.0, boil / cloud_size), float(i)).r;
			float sigma = rain_shafts * heavy * smoothstep(0.38, 0.62, streaks) * 0.3;
			sigma *= smoothstep(0.0, 0.6, (cloud_base - pos.y) / cloud_base);
			if (sigma > 0.0) {
				float haze = 1.0 - exp(-t / haze_distance);
				float a = 1.0 - exp(-sigma * t * 0.5);
				light += transmittance * a * mix(rain_color, haze_color, haze);
				transmittance *= 1.0 - a;
			}
		}
	}

	float near_end = min(t_far, t_near + cloud_thickness * 4.0);
	float dt = (near_end - t_near) / float(CLOUD_STEPS);
	float lod = max(log2(dt / cloud_size * noise_size.x) - 2.0, 0.0);
	float t = t_near + jitter * dt;
	for (int i = 0; i < CLOUD_STEPS + FAR_STEPS; i++) {
		bool far = i >= CLOUD_STEPS;
		if (i == CLOUD_STEPS) {
			if (near_end >= t_far) break;
			dt = (t_far - near_end) / float(FAR_STEPS);
			lod += 2.0;
			t = near_end + jitter * dt;
		}
		vec3 pos = dir * t;
		float h = (altitude_of(pos) - cloud_base) / cloud_thickness;
		// Blur the noise to whichever is bigger: the step, or a map texel at this distance.
		float lod_t = max(lod, log2(t * 0.004 / cloud_size * noise_size.x) - 1.0);
		float d = cloud_density(pos, h, warp, drift3, lod_t, far, cov);
		if (d > 0.001) {
			// March toward the light: how much cloud stands in its way.
			float shadow = 0.0;
			if (!far) {
				for (int j = 0; j < LIGHT_STEPS; j++) {
					float l0 = float(j) / float(LIGHT_STEPS);
					float l1 = float(j + 1) / float(LIGHT_STEPS);
					float lm = (j == 0 ? jitter : 0.5);
					float l = mix(l0 * l0, l1 * l1, lm) * light_reach; // denser near the sample
					vec3 lp = pos + to_light * l;
					float lh = h + to_light.y * l / cloud_thickness;
					shadow += cloud_density(lp, lh, warp, drift3, lod_t + 1.0, j > 1, cov) * (l1 * l1 - l0 * l0);
				}
				shadow *= light_reach;
			} else {
				shadow = (1.0 - h) * cloud_thickness * 0.5;
			}
			float optical = shadow * density * 2.0;
			float scatter = phase.x * exp(-optical) + phase.y * exp(-optical * 0.3) + phase.z * exp(-optical * 0.09);
			// Wisps and undersides that haven't gathered light read darker (the lower, the
			// more so), unless the light already came through cloud.
			scatter *= mix(0.15 + 1.2 * pow(min(1.0, d * 1.7), 0.3 + 4.0 * h), 1.0, clamp(optical * 0.15, 0.0, 1.0));
			// Sky light comes from above, through whatever cloud is over this point: two
			// looks straight up. Thick decks go dark underneath, thin patches glow.
			float above = 0.0;
			if (!far) {
				for (int j = 1; j <= 2; j++) {
					float uh = h + (1.0 - h) * float(j) / 2.5;
					vec3 up_pos = pos + vec3(0.0, (uh - h) * cloud_thickness, 0.0);
					above += cloud_density(up_pos, uh, warp, drift3, lod_t + 1.0, true, cov);
				}
				above *= (1.0 - h) * cloud_thickness * 0.5;
			} else {
				above = (1.0 - h) * cloud_thickness * 0.4;
			}
			float sky_reach = exp(-above * density * 0.5);
			// More sky light higher up; a grey bounce off the sea low down.
			vec3 ambient = sky_light * (0.45 + 0.6 * h) * mix(0.25, 1.0, sky_reach) * mix(1.0, 0.6, overcast)
					+ p.dark.rgb * max(0.0, 1.0 - 2.0 * h);
			vec3 c = ambient + sun_light * scatter;
			float haze = 1.0 - exp(-pow(t / haze_distance, 1.3));
			c = mix(c, haze_color, haze);

			float a = 1.0 - exp(-d * density * dt * (far ? 0.5 : 1.0));
			light += transmittance * a * c;
			transmittance *= 1.0 - a;
			if (transmittance < 0.005) break;
		}
		t += dt;
	}
	return vec4(light, transmittance);
}

void main() {
	ivec2 size = ivec2(p.update.xy);
	int frame = int(p.light_c.w);
	// This frame's texel in each 4x4 block, in an order that spreads them out (Bayer).
	const int bayer[16] = int[16](0, 10, 2, 8, 5, 15, 7, 13, 1, 11, 3, 9, 4, 14, 6, 12);
	int k = bayer[frame & 15];
	ivec2 px = ivec2(gl_GlobalInvocationID.xy) * 4 + ivec2(k & 3, k >> 2);
	if (any(greaterThanEqual(px, size))) return;

	// A fresh random spot in the texel and along the ray every visit.
	vec2 rnd = vec2(hash12(vec2(px) + float(frame) * 1.618), hash12(vec2(px.yx) * 1.37 + float(frame) * 2.414));
	float jitter = hash12(vec2(px) * 0.71 + float(frame) * 0.618);
	vec2 uv = (vec2(px) + rnd) / vec2(size);
	float azimuth = uv.x * 2.0 * PI;
	float elevation = 0.5 * PI * pow(uv.y, 1.0 / 0.6);
	vec3 dir = vec3(cos(elevation) * cos(azimuth), sin(elevation), cos(elevation) * sin(azimuth));
	if (dot(dir, p.view.xyz) < p.update.w && p.view.w < 0.5) return; // out of view, not its round

	vec4 clouds = march_clouds(dir, jitter);
	vec4 history = imageLoad(cloud_map, px);
	imageStore(cloud_map, px, mix(history, clouds, p.update.z));
}

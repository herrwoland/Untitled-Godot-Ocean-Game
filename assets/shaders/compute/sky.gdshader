shader_type sky;
// No use_debanding: its per-channel noise, blown up by the sRGB curve near black, gave every
// pixel of a dark night sky a random hue that the low-res post dither turned into rainbow specks.
/**
 * Ocean sky. The clouds come from the cloud map (assets/weather/cloud_map.gd and
 * cloud_map.glsl): the whole dome's clouds, ray-marched a slice per frame on the GPU and
 * stored by view direction, so here they are a single texture read. The cloud settings
 * below are read off this material by the cloud map; `billow` shapes them: 0 = a flat
 * stratus deck (overcast, storms), 1 = heaped cumulus with flat dark bases and sunlit tops.
 * The scene's light (LIGHT0) is drawn as a disc behind the clouds: the sun by day, the
 * moon by night. Distant lightning is added here, as it flickers too fast for the map.
 *
 * The radiance cubemap (ambient light) and the first frames, before the map has filled,
 * use a one-sample stand-in for the clouds.
 */

group_uniforms Clouds;
uniform sampler2D noise_texture : filter_linear_mipmap, repeat_enable;
uniform float coverage : hint_range(0.0, 1.0) = 0.5; // how much of the sky is cloud
uniform float density : hint_range(0.5, 16.0) = 6.0; // opacity per km of cloud
uniform float billow : hint_range(0.0, 1.0) = 0.8; // 0 = flat deck, 1 = heaped cumulus towers
uniform float cloud_detail : hint_range(0.0, 1.0) = 0.5; // how deeply big 3D noise carves the clouds
uniform float cloud_erosion : hint_range(0.0, 1.0) = 0.5; // finer noise fraying the edges into wisps
uniform float detail_size : hint_range(0.2, 10.0) = 2.0; // km across one tile of the 3D detail noise
uniform float cloud_base : hint_range(0.2, 6.0) = 1.2; // km above the sea
uniform float cloud_thickness : hint_range(0.1, 8.0) = 1.6; // km
uniform float cloud_size : hint_range(1.0, 60.0) = 10.0; // km across one noise tile (bigger = bigger clouds)
uniform float warp_strength : hint_range(0.0, 1.0) = 0.3; // churns the shapes as they drift
uniform vec2 wind_direction = vec2(1.0, 0.35);
uniform float wind_speed : hint_range(0.0, 0.2) = 0.015; // km per second
uniform float scud_speed_mult : hint_range(1.0, 5.0) = 2.2; // the lumps boil faster than the clouds drift
uniform float rain_shafts : hint_range(0.0, 1.0) = 0.0; // grey curtains under the heaviest cloud
uniform float haze_distance : hint_range(5.0, 200.0) = 45.0; // km over which cloud fades into the horizon
uniform float planet_radius : hint_range(100.0, 6400.0) = 2000.0; // km: smaller = clouds dip to the horizon sooner
group_uniforms;

// Set by the cloud map through the RenderingServer (never saved with the material).
uniform sampler2D cloud_map : filter_linear, repeat_enable;
uniform bool cloud_map_ready = false;

group_uniforms Palette;
uniform vec3 cloud_lit_color : source_color = vec3(0.30, 0.31, 0.33); // sunlit cloud
uniform vec3 cloud_dark_color : source_color = vec3(0.035, 0.04, 0.055); // shaded bases and cores
uniform vec3 zenith_color : source_color = vec3(0.05, 0.06, 0.08);
uniform vec3 horizon_color : source_color = vec3(0.30, 0.31, 0.32);
uniform vec3 ground_color : source_color = vec3(0.02, 0.03, 0.04);
group_uniforms;

group_uniforms Effects;
uniform float sun_glow : hint_range(0.0, 2.0) = 0.35; // sky brightening around the sun
uniform float silver_lining : hint_range(0.0, 4.0) = 1.0; // thin cloud edges glowing toward the sun
uniform float lightning_strength : hint_range(0.0, 1.0) = 0.35; // 0 disables distant lightning
uniform float exposure : hint_range(0.0, 4.0) = 1.0;
group_uniforms;

group_uniforms SunAndMoon;
uniform float sun_size : hint_range(0.1, 10.0) = 1.4; // apparent diameter, degrees (the real one is ~0.5)
uniform float sun_disc_energy : hint_range(0.0, 50.0) = 14.0; // HDR brightness of the disc: feeds the glow/bloom
uniform float sun_corona : hint_range(0.0, 3.0) = 0.8; // bright haze hugging the disc
uniform float moon_amount : hint_range(0.0, 1.0) = 0.0; // 0 = the light is the sun, 1 = it is the moon
uniform float moon_size : hint_range(0.1, 10.0) = 2.4; // apparent diameter, degrees
uniform vec3 moon_color : source_color = vec3(0.86, 0.88, 0.92);
uniform float moon_brightness : hint_range(0.0, 40.0) = 1.8; // night presets dim the whole sky (background energy): raise this to match
uniform float moon_phase : hint_range(-1.0, 1.0) = 0.25; // 0 = full, +-1 = new; the sign picks the lit side
uniform float moon_halo : hint_range(0.0, 2.0) = 0.35; // pale ring of light around the moon
group_uniforms;

group_uniforms Sunset;
uniform vec3 sunset_color : source_color = vec3(0.9, 0.45, 0.2);
uniform float sunset_strength : hint_range(0.0, 2.0) = 1.0; // 0 disables the sunset band
uniform float sunset_spread : hint_range(1.0, 8.0) = 2.5; // higher = band hugs the sun azimuth tighter
group_uniforms;


// The light's disc in the sky: the sun (limb-darkened, with a corona) or the
// moon (maria from the noise, a lit phase, a faint halo), blended by
// moon_amount. Returns light to add before the clouds go over it.
vec3 celestial_disc(vec3 dir, vec3 to_light, vec3 light_color) {
	float cos_angle = dot(dir, to_light);
	if (cos_angle < 0.9) {
		return vec3(0.0); // far from it: skip (corona and halo are long gone by 25 degrees)
	}
	float angle = acos(clamp(cos_angle, -1.0, 1.0));
	vec3 right = normalize(cross(to_light, abs(to_light.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
	vec3 up = cross(right, to_light);

	// Sun: a hot disc, darker toward its rim, in a soft corona.
	float sun_radius = radians(sun_size) * 0.5;
	float sr = angle / sun_radius;
	float sun_disc = smoothstep(1.0, 0.96, sr);
	float limb = 1.0 - 0.55 * (1.0 - sqrt(max(1.0 - sr * sr, 0.0)));
	vec3 sun = light_color * (sun_disc * limb * sun_disc_energy
			+ sun_corona * (exp(-sr * 0.55) * 0.6 + exp(-sr * 0.12) * 0.15));

	// Moon: a sphere lit from the side by an unseen sun, its seas from the noise.
	float moon_radius = radians(moon_size) * 0.5;
	vec2 p = vec2(dot(dir, right), dot(dir, up)) / max(sin(moon_radius), 1e-4);
	float mr = length(p);
	float moon_disc = smoothstep(1.0, 0.95, mr);
	vec3 n = vec3(p, sqrt(max(1.0 - mr * mr, 0.0)));
	float ph = moon_phase * 3.14159;
	float lit = smoothstep(-0.08, 0.12, dot(n, vec3(sin(ph), 0.0, cos(ph))));
	float maria = texture(noise_texture, p * 0.35 + vec2(0.37, 0.61)).r;
	float albedo = mix(0.62, 1.0, smoothstep(0.35, 0.7, maria));
	vec3 moon = moon_color * moon_brightness * (moon_disc * albedo * mix(0.03, 1.0, lit)
			+ moon_halo * exp(-max(mr - 1.0, 0.0) * 1.6) * (1.0 - moon_disc) * 0.25);

	return mix(sun, moon, moon_amount);
}

// Distance along a ray from the camera (sea level) to the shell `altitude` km up.
float shell_distance(vec3 dir, float altitude) {
	float r = planet_radius + altitude;
	float b = planet_radius * dir.y;
	return -b + sqrt(max(b * b - planet_radius * planet_radius + r * r, 0.0));
}

// Where in the sky there is cloud at all, 0..1, from one noise tap at `uv` (noise tiles).
// `lod` blurs the noise to the length of a march step, so a step stands for all of it
// rather than one point (one point per step turns cloud edges into grain).
// `cov` is the coverage here: the uniform, nudged by regional weather.
float cloud_cover(vec2 uv, float lod, float cov) {
	float n = textureLod(noise_texture, uv, lod).r;
	// The noise sits mostly within 0.3..0.7; spread it so coverage reads as a sky fraction.
	n = (n - 0.5) * 2.4 + 0.5;
	// Above 0.8 coverage the threshold drops fast, so 1 closes the sky completely
	// (an overcast deck) rather than leaving the noise's lowest dips as clear holes.
	float lo = 1.0 - cov - max(cov - 0.8, 0.0) * 3.0;
	return smoothstep(lo, lo + 0.45, n);
}

// The clouds along `dir` from the cloud map: their light (over black) in rgb, how much of the
// sky behind shows in a. Map layout as in cloud_map.glsl: x = azimuth, y = elevation^0.6.
vec4 map_clouds(vec3 dir) {
	vec2 size = vec2(textureSize(cloud_map, 0));
	float u = fract(atan(dir.z, dir.x) / (2.0 * PI));
	float v = pow(asin(clamp(dir.y, 0.0, 1.0)) / (0.5 * PI), 0.6);
	v = clamp(v, 0.5 / size.y, 1.0 - 0.5 / size.y);
	return textureLod(cloud_map, vec2(u, v), 0.0);
}

// Distant lightning: brief random flashes from a random horizon direction.
float lightning_flash(vec3 dir) {
	float cell = floor(TIME * 0.35); // one chance roughly every 3 seconds
	float rnd = fract(sin(cell * 127.1) * 43758.5453);
	float phase_t = fract(TIME * 0.35);
	float flash = rnd > 0.8 ? exp(-40.0 * phase_t) + 0.6 * exp(-40.0 * abs(phase_t - 0.12)) : 0.0;
	float flash_dir = rnd * 6.2831;
	return flash * lightning_strength * (0.5 + 0.5 * dot(normalize(dir.xz + 1e-5), vec2(cos(flash_dir), sin(flash_dir))));
}

// The radiance cubemap (ambient light) only needs the sky's overall tone: one tap
// where the view crosses the cloud base. Also stands in before the cloud map is ready.
vec4 cheap_clouds(vec3 dir, vec3 light_color) {
	float t = shell_distance(dir, cloud_base + cloud_thickness * 0.5);
	vec2 uv = (dir.xz * t) / cloud_size + normalize(wind_direction) * wind_speed * TIME / cloud_size;
	float s = cloud_cover(uv, 3.0, coverage);
	float thick = clamp(s * density * cloud_thickness * 0.2, 0.0, 1.0);
	vec3 c = mix(cloud_lit_color * light_color * 0.6 + mix(horizon_color, zenith_color, 0.4) * 0.5, cloud_dark_color, thick * 0.7);
	float haze = 1.0 - exp(-t / haze_distance);
	c = mix(c, horizon_color, haze);
	float a = s * (1.0 - haze);
	return vec4(c * a, 1.0 - a);
}

void sky() {
	vec3 dir = EYEDIR;
	vec3 light_color = LIGHT0_ENABLED ? LIGHT0_COLOR : vec3(0.0);
	vec3 to_light = LIGHT0_ENABLED ? LIGHT0_DIRECTION : vec3(0.0, 1.0, 0.0);

	float horizon_fade = pow(1.0 - abs(dir.y), 6.0);

	// Setting-sun band: warm light bleeding along the horizon around the sun's
	// azimuth, only when the sun actually sits low in the sky.
	float sunset = 0.0;
	vec2 dir_xz = vec2(dir.x, dir.z);
	vec2 sun_xz = vec2(to_light.x, to_light.z);
	if (sunset_strength > 0.0 && length(dir_xz) > 1e-4 && length(sun_xz) > 1e-4) {
		float azimuth = max(dot(normalize(dir_xz), normalize(sun_xz)), 0.0);
		float sun_low = smoothstep(0.45, 0.02, max(to_light.y, 0.0));
		sunset = sunset_strength * sun_low * horizon_fade * pow(azimuth, sunset_spread);
	}

	// --- below the horizon: dark sea haze (the water mesh covers most of it) ---
	if (dir.y <= 0.0) {
		vec3 sea_col = mix(ground_color, horizon_color, horizon_fade);
		sea_col = mix(sea_col, sunset_color, clamp(sunset, 0.0, 1.0) * 0.55);
		COLOR = sea_col * exposure;
	} else {
	// Clear sky: zenith to horizon, brighter around the sun.
	vec3 sky_col = mix(zenith_color, horizon_color, horizon_fade);
	sky_col += light_color * sun_glow * pow(max(dot(dir, to_light), 0.0), 24.0);
	// The sun or moon hangs in that sky, behind the clouds. Low down, the haze swallows it.
	if (LIGHT0_ENABLED) {
		sky_col += celestial_disc(dir, to_light, light_color) * (1.0 - horizon_fade * 0.85);
	}

	vec4 clouds = AT_CUBEMAP_PASS || !cloud_map_ready ? cheap_clouds(dir, light_color) : map_clouds(dir);
	vec3 col = sky_col * clouds.a + clouds.rgb;
	// Lightning lights the cloud from within and below.
	if (lightning_strength > 0.0) {
		col += vec3(0.7, 0.75, 0.9) * lightning_flash(dir) * (1.0 - clouds.a) * 0.6;
	}
	// A thin band of haze right on the horizon.
	col = mix(col, horizon_color, pow(1.0 - dir.y, 40.0) * 0.6);

	// The sunset band burns through the haze itself.
	col = mix(col, sunset_color, clamp(sunset, 0.0, 1.0) * 0.7);

	COLOR = col * exposure;
	}
}

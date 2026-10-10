shader_type sky;
// No use_debanding: its per-channel noise, blown up by the sRGB curve near black, gave every
// pixel of a dark night sky a random hue that the low-res post dither turned into rainbow specks.
/**
 * Ocean sky: a layer of real cloud shapes, ray-marched.
 * The layer is a shell around a (stylised) planet between cloud_base and
 * cloud_base + cloud_thickness, so the clouds crowd and flatten toward the horizon.
 * `billow` shapes it: 0 = a flat stratus deck (overcast, storms), 1 = heaped
 * cumulus with flat dark bases and sunlit domed tops. Each sample looks once
 * toward the light to shade itself; looking toward the sun the thin edges
 * glow (silver lining). Under heavy cloud, grey rain shafts hang down to the
 * sea. Distant cloud melts into the horizon haze. The scene's light (LIGHT0)
 * is drawn as a disc behind the clouds: the sun by day, the moon by night.
 *
 * Cost: the march runs on the visible sky only (Godot's half/quarter-res sky
 * passes come back empty here); the radiance cubemap, redrawn every frame because
 * of TIME, gets a one-sample stand-in instead.
 */

group_uniforms Clouds;
uniform sampler2D noise_texture : filter_linear_mipmap, repeat_enable;
uniform float coverage : hint_range(0.0, 1.0) = 0.5; // how much of the sky is cloud
uniform float density : hint_range(0.5, 16.0) = 6.0; // opacity per km of cloud
uniform float billow : hint_range(0.0, 1.0) = 0.8; // 0 = flat deck, 1 = heaped cumulus towers
uniform float cloud_detail : hint_range(0.0, 1.0) = 0.5; // cauliflower lumps on the cloud edges
uniform float cloud_erosion : hint_range(0.0, 1.0) = 0.5; // frays the thin outer parts into wisps
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

const int CLOUD_STEPS = 10; // full samples through the near part of the layer
const int FAR_STEPS = 4; // single-tap samples beyond it
const int RAIN_CURTAINS = 4;
const float SURFACE = 0.05; // density the march treats as a cloud's surface

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
	return smoothstep(1.0 - cov, 1.0 - cov + 0.45, n);
}

// Cloud density at height fraction h (0 = base, 1 = top of the layer) above a column
// with cover s. Heaped clouds are lens-shaped: a flat base that curls up at the rim and
// a domed top. The deck fills the layer with ragged edges above and below. `lumps`
// (about -0.3..0.7, billowy) bulges the surface into cauliflower. `top` returns where
// the column ends, so the shading can tell its base from its crown.
float cloud_profile(float s, float h, float lumps, out float top) {
	float heap_top = sqrt(s) * 0.95;
	float heap_bottom = (1.0 - s) * (1.0 - s) * 0.3;
	top = mix(0.3 + 0.6 * s, heap_top, billow) + lumps * cloud_detail * 0.45;
	float bottom = mix(0.15, heap_bottom, billow) - lumps * cloud_detail * mix(0.25, 0.04, billow);
	// Bases are fairly crisp, crowns fade out softly.
	float body = smoothstep(bottom, bottom + 0.08, h) * smoothstep(top, top - 0.35, h);
	return body * mix(s, sqrt(s), billow);
}

// Cloud density at point p (km from the camera). `warp` is the drift plus domain warp,
// `boil` how far the lumps have churned, `lod` the noise blur for the step length.
// Far samples skip the lumps. Also returns the height fraction, column top and lumps.
float cloud_density(vec3 p, vec2 warp, float boil, float lod, bool far, float cov, out float h, out float top, out float lumps, out float crease) {
	float altitude = length(p + vec3(0.0, planet_radius, 0.0)) - planet_radius;
	h = (altitude - cloud_base) / cloud_thickness;
	top = 0.0;
	lumps = 0.0;
	crease = 1.0;
	vec2 uv = p.xz / cloud_size + warp;
	float s = cloud_cover(uv, lod, cov);
	// Above the highest the lumps could lift this column's top, or below the lowest base: empty.
	float max_top = mix(0.3 + 0.6 * s, sqrt(s) * 0.95, billow) + mix(0.5, 1.35, billow) * cloud_detail * 0.45;
	if (s <= 0.001 || h > max_top || h < -0.2) {
		return 0.0;
	}
	if (!far) {
		// Billowy lumps that change with height, so the edges read as stacked heaps. Heaps
		// get billows (round lobes with creases between); decks get soft swells, as creases
		// there read as glowing cracks against the sun.
		float n = textureLod(noise_texture, uv * 3.1 + vec2(h * 0.29, h * 0.13) + vec2(boil, -boil * 0.6), lod + 0.8).r;
		lumps = mix(n - 0.5, abs(n * 2.0 - 1.0) * 1.6 - 0.25, billow);
	}
	float d = cloud_profile(s, h, lumps, top);
	if (!far && d > 0.0 && cloud_erosion > 0.0) {
		// Erosion: finer billows eat into the thin outer parts, fraying them into wisps
		// and breaking up the inside, while the dense cores hold.
		float e = textureLod(noise_texture, uv * 9.3 + vec2(h * 0.71, -h * 0.47) + vec2(-boil * 1.7, boil), lod + 0.5).r;
		e = smoothstep(0.3, 0.7, e);
		float bite = (1.0 - e) * cloud_erosion * 0.6;
		// The folds between the small billows and between the big lumps sit in each
		// other's shadow: kept for the shading, it's what makes cauliflower read.
		crease = mix(1.0, smoothstep(-0.25, 0.35, lumps), billow);
		d = clamp((d - bite) / max(1.0 - bite, 0.05), 0.0, 1.0);
	}
	return d;
}

float henyey_greenstein(float cos_theta, float g) {
	float g2 = g * g;
	return (1.0 - g2) / pow(1.0 + g2 - 2.0 * g * cos_theta, 1.5); // x 4pi: 1 = isotropic
}

// Marches the cloud layer (and the rain under it) along `dir`. Returns the cloud's
// light in rgb (already over black) and how much of the sky behind still shows in a.
// The first stretch through the layer is marched in full; past it, the clouds are
// small and hazy, so a few single-tap samples stand in for them.
vec4 march_clouds(vec3 dir, vec3 to_light, vec3 light_color, vec2 frag, float time) {
	float t_near = shell_distance(dir, cloud_base);
	float t_far = shell_distance(dir, cloud_base + cloud_thickness);
	float max_distance = haze_distance * 3.0;
	if (t_near > max_distance) {
		return vec4(0.0, 0.0, 0.0, 1.0);
	}
	t_far = min(t_far, max_distance);

	vec2 wind_dir = normalize(wind_direction);
	vec2 drift = wind_dir * wind_speed * time / cloud_size;
	int noise_size = textureSize(noise_texture, 0).x;
	float boil = time * wind_speed * scud_speed_mult / cloud_size;
	float jitter = fract(sin(dot(frag, vec2(12.9898, 78.233))) * 43758.5453); // structured patterns show; plain grain hides

	// Domain warp, once per pixel where the ray enters the layer: churns the shapes as they drift.
	float swirl = texture(noise_texture, (dir.xz * t_near) / cloud_size * 0.5 + drift * 0.3).r * 12.566;
	vec2 warp = vec2(cos(swirl), sin(swirl)) * warp_strength * 0.08 + drift;
	// Regional weather: the sky clumps into busier and clearer stretches, rather than
	// evenly spaced clouds everywhere.
	float region = textureLod(noise_texture, (dir.xz * t_near) / cloud_size * 0.11 + drift * 0.1 + vec2(0.43, 0.17), 2.0).r;
	float cov = clamp(coverage + (region - 0.5) * 0.6 * (1.0 - coverage), 0.0, 1.0);

	// Light: forward scatter toward the sun lights thin edges; a little back scatter keeps
	// the far side from going flat.
	float cos_light = dot(dir, to_light);
	vec3 sun_light = cloud_lit_color * light_color;
	// Multiple scattering in three octaves: each bounce is weaker, reaches deeper into
	// the cloud (see the march) and scatters less forward. The phases only depend on the
	// view, so they're worked out once here.
	vec3 scatter_phase;
	for (int k = 0; k < 3; k++) {
		float spread = exp2(-float(k));
		scatter_phase[k] = spread * mix(henyey_greenstein(cos_light, -0.15 * spread), henyey_greenstein(cos_light, 0.85 * spread), 0.3 * silver_lining);
	}
	// Looking toward the sun the bright single scatter through thin rims wins and the
	// deep, many-times-scattered glow fades: backlit clouds get dark cores and silver
	// edges. Away from the sun the deep glow stays.
	scatter_phase.yz *= mix(0.1, 1.0, smoothstep(0.96, 0.3, cos_light));
	// The direct light only gets through thin rims, so brightening it near the sun lights
	// those up (HDR: the tonemapper rolls it off) without touching the dark cores.
	scatter_phase.x *= 1.0 + 1.5 * silver_lining * pow(max(cos_light, 0.0), 4.0);
	vec3 sky_light = mix(horizon_color, zenith_color, 0.3) * 1.3;
	vec3 haze_color = horizon_color + light_color * sun_glow * 0.5 * pow(max(cos_light, 0.0), 8.0);
	float light_step = cloud_thickness * 0.3;

	// Distant lightning: brief random flashes from a random horizon direction, lighting
	// the cloud undersides.
	float flash = 0.0;
	if (lightning_strength > 0.0) {
		float cell = floor(time * 0.35); // one chance roughly every 3 seconds
		float rnd = fract(sin(cell * 127.1) * 43758.5453);
		float phase_t = fract(time * 0.35);
		flash = rnd > 0.8 ? exp(-40.0 * phase_t) + 0.6 * exp(-40.0 * abs(phase_t - 0.12)) : 0.0;
		float flash_dir = rnd * 6.2831;
		flash *= lightning_strength * (0.5 + 0.5 * dot(normalize(dir.xz + 1e-5), vec2(cos(flash_dir), sin(flash_dir))));
	}

	vec3 light = vec3(0.0);
	float transmittance = 1.0;

	// Rain shafts: grey curtains between the sea and the cloud base wherever the cloud
	// above is heavy. Rain stands in columns, so it is looked up on a few curtains at
	// set distances: each screen column then meets the same rain all the way up, which
	// draws streaks rather than speckle, and each curtain ends where it meets the base.
	if (rain_shafts > 0.0) {
		// Rain scatters the daylight: a pale veil against the dark cloud bases behind it.
		vec3 rain_color = mix(horizon_color, cloud_lit_color * light_color, 0.5);
		for (int i = 0; i < RAIN_CURTAINS; i++) {
			float t = 3.0 * exp2(float(i)); // 3, 6, 12, 24 km
			if (t > t_near) {
				break;
			}
			vec3 p = vec3(normalize(dir.xz).x, dir.y, normalize(dir.xz).y) * t;
			// Rain falls slanted a little downwind: look up-wind for the cloud it fell from.
			vec2 above = (p.xz - wind_dir * (cloud_base - p.y) * 0.03) / cloud_size + drift;
			float heavy = smoothstep(0.5, 1.0, cloud_cover(above, 3.0, coverage));
			// Finer streaks up close, broader far away (where the near ones would shimmer).
			float streaks = textureLod(noise_texture, above * 16.0 + vec2(0.0, boil), float(i)).r;
			float sigma = rain_shafts * heavy * smoothstep(0.38, 0.62, streaks) * 0.3;
			sigma *= smoothstep(0.0, 0.6, (cloud_base - p.y) / cloud_base); // melts into the base
			if (sigma > 0.0) {
				float haze = 1.0 - exp(-t / haze_distance);
				float a = 1.0 - exp(-sigma * t * 0.5);
				light += transmittance * a * mix(rain_color, haze_color, haze);
				transmittance *= 1.0 - a;
			}
		}
	}

	float near_end = min(t_far, t_near + cloud_thickness * 3.0);
	// Steep rays cross the layer quickly and need fewer steps.
	int near_steps = int(mix(float(CLOUD_STEPS) * 0.75, float(CLOUD_STEPS), smoothstep(0.6, 0.15, dir.y)));
	float dt = (near_end - t_near) / float(near_steps);
	float lod = max(log2(dt / cloud_size * float(noise_size)) - 1.0, 0.0);
	float t = t_near + jitter * dt;
	bool inside = false;
	int fine_steps = 0; // short steps left after entering a cloud
	for (int i = 0; i < near_steps + FAR_STEPS; i++) {
		bool far = i >= near_steps;
		if (i == near_steps) {
			if (near_end >= t_far) {
				break;
			}
			dt = (t_far - near_end) / float(FAR_STEPS);
			lod += 3.0;
			t = near_end + jitter * dt;
		}
		float h;
		float top;
		float lumps;
		float crease;
		float d = cloud_density(dir * t, warp, boil, lod, far, cov, h, top, lumps, crease);
		if (d > SURFACE && !inside && !far) {
			// Just stepped into a cloud: find its surface between here and the last step,
			// and carry on from there. Sampling the surface itself, not wherever a step
			// happened to land, is what keeps the edges and lit sides smooth.
			float lo = max(t - dt, t_near);
			float hi = t;
			for (int j = 0; j < 2; j++) {
				float mid = (lo + hi) * 0.5;
				float mh;
				float mtop;
				float ml;
				float mc;
				if (cloud_density(dir * mid, warp, boil, lod, false, cov, mh, mtop, ml, mc) > SURFACE) {
					hi = mid;
				} else {
					lo = mid;
				}
			}
			t = hi;
			// Thin rims get a few short steps, so they gather opacity smoothly instead of
			// being hit by one step or missed (which reads as grain).
			fine_steps = 3;
			d = cloud_density(dir * t, warp, boil, lod, false, cov, h, top, lumps, crease);
		}
		float step_len = fine_steps > 0 && !far ? dt * 0.35 : dt;
		inside = d > SURFACE;
		// The faintest wisps would only be caught by the odd step, as specks: let them fade.
		d *= smoothstep(0.0, SURFACE * 4.0, d);
		if (d > 0.001) {
			vec3 p = dir * t;
			// One look toward the light: how much cloud stands between this point and it.
			// Two looks toward the light, near and far, plus the column's own depth (the
			// base has the whole cloud above it): how much cloud stands in the light's way.
			float height_in_cloud = clamp(h / max(top, 0.05), 0.0, 1.0);
			float optical = (1.0 - smoothstep(0.0, 0.8, height_in_cloud)) * 1.5;
			if (!far) {
				float l_top;
				vec3 lp = p + to_light * light_step;
				float lh = h + to_light.y * light_step / cloud_thickness;
				optical += cloud_profile(cloud_cover(lp.xz / cloud_size + warp, lod + 1.0, cov), lh, lumps, l_top) * light_step;
				lp = p + to_light * light_step * 3.0;
				lh = h + to_light.y * light_step * 3.0 / cloud_thickness;
				optical += cloud_profile(cloud_cover(lp.xz / cloud_size + warp, lod + 2.0, cov), lh, 0.0, l_top) * light_step * 2.0;
			}
			optical *= density * 1.2;
			// Multiple scattering: the deeper-reaching bounces keep shaded parts glowing
			// softly instead of going flat grey.
			float scatter = scatter_phase.x * exp(-optical) + scatter_phase.y * exp(-optical * 0.3)
					+ scatter_phase.z * exp(-optical * 0.09);
			// Powder: thin rims facing away from the sun haven't gathered light yet and read
			// darker, which is what makes cumulus edges look solid.
			float powder = 1.0 - exp(-d * density * 0.6);
			scatter *= mix(powder, 1.0, 0.5 + 0.5 * cos_light);
			if (!far) {
				// Round puffs over the surface (the noise cut into islands), each in its
				// neighbours' shadow. Shading only: the density and surface search skip it.
				vec2 q = (p.xz / cloud_size + warp) * 26.0 + vec2(h * 1.9, -h * 1.3) + vec2(-boil * 4.0, boil * 2.5);
				crease *= mix(0.45, 1.0, smoothstep(0.4, 0.62, textureLod(noise_texture, q * 0.37, lod).r));
			}
			scatter *= mix(0.35, 1.0, crease);
			// Sky light from above, through whatever cloud is over this point, fading to the
			// darker bounce from the sea at the base.
			float above = max(top - h, 0.0) * cloud_thickness;
			float sky_reach = mix(exp(-above * d * density * 0.35), height_in_cloud, 0.4);
			vec3 ambient = mix(cloud_dark_color, sky_light, sky_reach) * mix(0.7, 1.0, crease);
			vec3 c = ambient + sun_light * scatter + vec3(0.7, 0.75, 0.9) * flash * (1.0 - height_in_cloud);
			// Aerial perspective: distant cloud loses its contrast into the haze.
			float haze = 1.0 - exp(-pow(t / haze_distance, 1.3));
			c = mix(c, haze_color, haze);

			float a = 1.0 - exp(-d * density * step_len * (far ? 0.5 : 1.0));
			light += transmittance * a * c;
			transmittance *= 1.0 - a;
			if (transmittance < 0.01) {
				break;
			}
		}
		t += step_len;
		fine_steps -= 1;
	}
	return vec4(light, transmittance);
}

// The radiance cubemap (ambient light) only needs the sky's overall tone: one tap
// where the view crosses the cloud base, no march.
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

	vec4 clouds = AT_CUBEMAP_PASS ? cheap_clouds(dir, light_color)
			: march_clouds(dir, to_light, light_color, FRAGCOORD.xy, TIME);
	vec3 col = sky_col * clouds.a + clouds.rgb;
	// A thin band of haze right on the horizon.
	col = mix(col, horizon_color, pow(1.0 - dir.y, 40.0) * 0.6);

	// The sunset band burns through the haze itself.
	col = mix(col, sunset_color, clamp(sunset, 0.0, 1.0) * 0.7);

	COLOR = col * exposure;
	}
}

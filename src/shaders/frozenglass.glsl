// Frozen-glass backdrop, ported from a standalone GLSL shader (written against
// an EffectContext-style DSL) onto this project's real KWin shader pipeline.
//
// How the coordinate systems line up with the original shader:
//   effect.content_rect_px.zw  -> blurSize                (window content size, px)
//   effect_content_px(effect)  -> uv * blurSize            ("frag", px, top-left origin)
//   tex / effect.texture_uv    -> texUnit / uv              (this pass's backdrop sampler)
// texUnit here is the same dual-Kawase-blurred backdrop the rest of this file
// already refracts through, so the ice sits on top of the existing blur instead
// of the raw compositor backdrop -- this reads better at typical crystal_px sizes
// and avoids a second full-res texture fetch per pixel.
//
// Frozen-glass tuning is now contained entirely in this shader.
// The visible appearance of the ice is governed by constants below,
// making this effect easier to reuse as a drop-in glass shader.

const float ICE_REFRACTION_STRENGTH = 1.0; // effect-specific refraction strength
const float ICE_EDGE_SIZE_PX = 20.0;      // refraction edge width, px
const int ICE_QUALITY_MODE = 1;           // 0=balanced, 1=high quality, 2=legacy pre-optimization
const float ICE_TINT_AMOUNT = 0.28;       // blue grading amount
const vec3 ICE_TINT_COLOR = vec3(0.82, 0.93, 1.08);
const vec3 ICE_CRACK_COLOR = vec3(0.85, 0.95, 1.0);
const float ICE_CRACK_INTENSITY = 0.06;

// ---- Ice look tuning (edit these, then rebuild) ----------------------------
const float ICE_crystal_px    = 77.0;  // voronoi cell size, px
const float ICE_crack_width   = 0.03;  // seam width, F2-F1 units
const float ICE_frost_amount  = 0.32;  // base frost coverage, 0..1
const float ICE_frost_scale         = 1.6;   // vein-field frequency vs crystal grid
const float ICE_texture_scale1      = 1.0;   // first ice texture layer frequency vs crystal grid
const float ICE_texture_scale2      = 2.0;   // second ice texture layer frequency vs crystal grid
const float ICE_texture_refraction1 = 0.67;  // refraction strength for layer 1
const float ICE_texture_refraction2 = 0.57;  // refraction strength for layer 2
const float ICE_edge_frost          = 0.4;  // extra frost creeping from window edges
const float ICE_edge_frost_px       = 40.0;  // creep depth, px
const float ICE_opacity             = 0.85;  // 0 = clear glass, 1 = fully frozen
const float REFRACTION_PX_SCALE     = 90.0; // px of bend per unit of refractionStrength
// -----------------------------------------------------------------------------

float roundedRectangleDist(vec2 p, vec2 b, vec4 cornerRadius)
{
    float r = p.x > 0.0
    ? (p.y > 0.0 ? cornerRadius.y : cornerRadius.w)
    : (p.y > 0.0 ? cornerRadius.x : cornerRadius.z);
    vec2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

vec4 roundedRectangle(vec2 fragCoord, vec3 color, vec4 cornerRadius)
{
    vec2 halfblurSize = blurSize * 0.5;
    vec2 p = fragCoord - halfblurSize;
    float dist = roundedRectangleDist(p, halfblurSize, cornerRadius);

    if (dist <= 0.0) {
        return vec4(color, 1.0);
    }

    float s = smoothstep(0.0, 1.0, dist);
    return vec4(color, mix(1.0, 0.0, s));
}

// ---- noise / voronoi helpers, ported as-is ---------------------------------
const float HASHSCALE1 = 0.1031;
const vec3 HASHSCALE3 = vec3(0.1031, 0.1030, 0.0973);

float hash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * HASHSCALE1);
    p3 += dot(p3, p3.yzx + 19.19);
    return fract((p3.x + p3.y) * p3.z);
}

vec2 hash22(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * HASHSCALE3);
    p3 += dot(p3, p3.yzx + 19.19);
    return fract((p3.xx + p3.yz) * p3.zy);
}

float value_noise(vec2 p) {
    vec2 cell = floor(p);
    vec2 f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    float a = hash12(cell);
    float b = hash12(cell + vec2(1.0, 0.0));
    float c = hash12(cell + vec2(0.0, 1.0));
    float d = hash12(cell + vec2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float ridge(vec2 p) {
    return 1.0 - abs(2.0 * value_noise(p) - 1.0);
}

float fbm(vec2 p) {
    float sum = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++) {
        sum += value_noise(p) * amp;
        p = p * 2.17 + vec2(11.31, 7.77);
        amp *= 0.5;
    }
    return sum;
}

// Lightweight FBM for non-critical details (fewer iterations)
float fbm_lite(vec2 p) {
    float sum = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 2; i++) {
        sum += value_noise(p) * amp;
        p = p * 2.17 + vec2(11.31, 7.77);
        amp *= 0.5;
    }
    return sum;
}

// Analytical gradient approximation for "melty" look (fast but less detailed)
vec2 fbm_gradient_analytical(vec2 p) {
    vec2 grad = vec2(0.0);
    float amp = 0.5;
    for (int i = 0; i < 3; i++) {
        vec2 cell = floor(p);
        vec2 f = fract(p);

        float a = hash12(cell);
        float b = hash12(cell + vec2(1.0, 0.0));
        float c = hash12(cell + vec2(0.0, 1.0));
        float d = hash12(cell + vec2(1.0, 1.0));

        // Simple gradient approximation
        grad += vec2(
            (b + d) - (a + c),
                     (c + d) - (a + b)
        ) * amp * 0.25;

        p = p * 2.17;
        amp *= 0.5;
    }
    return grad;
}

// Compute FBM + gradient in one pass for better melty effect
vec3 fbm_with_grad(vec2 p) {
    float sum = 0.0;
    vec2 grad = vec2(0.0);
    float amp = 0.5;

    for (int i = 0; i < 4; i++) {
        vec2 cell = floor(p);
        vec2 f = fract(p);

        float a = hash12(cell);
        float b = hash12(cell + vec2(1.0, 0.0));
        float c = hash12(cell + vec2(0.0, 1.0));
        float d = hash12(cell + vec2(1.0, 1.0));

        vec2 u = f * f * (3.0 - 2.0 * f);
        vec2 du = 6.0 * f * (1.0 - f);

        float val = mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
        sum += val * amp;

        // Gradient computation
        grad += vec2(
            mix(b - a, d - c, u.y) * du.x,
                     mix(c - a, d - b, u.x) * du.y
        ) * amp;

        p = p * 2.17 + vec2(11.31, 7.77);
        amp *= 0.5;
    }

    return vec3(grad, sum);
}

// xy = (F1, F2) distances, zw = winning cell id (used to seed the facet bend).
vec4 voronoi(vec2 p) {
    vec2 cell = floor(p);
    vec2 f = fract(p);
    float f1 = 8.0;
    float f2 = 8.0;
    vec2 facet_seed = vec2(0.0);

    for (int y = -1; y <= 1; y++) {
        for (int x = -1; x <= 1; x++) {
            vec2 offset = vec2(float(x), float(y));
            vec2 site = offset + hash22(cell + offset) - f;
            float d = dot(site, site);
            if (d < f1) {
                f2 = f1;
                f1 = d;
                facet_seed = cell + offset;
            } else if (d < f2) {
                f2 = d;
            }
        }
    }

    return vec4(sqrt(f1), sqrt(f2), facet_seed);
}

// ---- main entry point, called from onscreen_rounded.glsl -------------------
// `sum` is this pass's cheap 8-tap smoothed sample at `uv` -- used here as the
// "clear_backdrop" (undistorted) reference, exactly like the original shader
// used effect.texture_uv for its clear_backdrop.
vec4 glass(vec4 sum, vec4 cornerRadius)
{
    vec2 halfBlurSize = blurSize * 0.5;
    vec2 position = uv * blurSize - halfBlurSize;
    float dist = roundedRectangleDist(position, halfBlurSize, cornerRadius);
    if (dist >= 0.0) {
        return sum;
    }

    vec2 frag = uv * blurSize;
    vec2 safe_size = max(blurSize, vec2(1.0));
    vec2 ice_uv = frag / max(ICE_crystal_px, 1.0);
    vec2 ice_texture_uv1 = ice_uv * max(ICE_texture_scale1, 0.001);
    vec2 ice_texture_uv2 = ice_uv * max(ICE_texture_scale2, 0.001);
    vec2 ice_texture_uv = 0.5 * (ice_texture_uv1 + ice_texture_uv2);

    vec4 crystal = voronoi(ice_uv);
    float seam_dist = crystal.y - crystal.x;
    float seam_width = max(ICE_crack_width, 0.001);
    float crack = 1.0 - smoothstep(0.0, seam_width, seam_dist);
    float crack_glow = 1.0 - smoothstep(0.0, seam_width * 5.0, seam_dist);

    vec2 facet_dir = hash22(crystal.zw) * 2.0 - 1.0;
    float bump = 0.035;

    vec2 surface_grad;

    if (ICE_QUALITY_MODE == 0) {
        // Balanced: current mode 1 behavior
        vec3 fbm1 = fbm_with_grad(ice_texture_uv1 * 1.7);
        vec3 fbm2 = fbm_with_grad(ice_texture_uv2 * 1.7);
        surface_grad = fbm1.xy * ICE_texture_refraction1 + fbm2.xy * ICE_texture_refraction2;
    } else if (ICE_QUALITY_MODE == 1) {
        // High quality: current mode 3 behavior
        float height1 = fbm(ice_texture_uv1 * 1.7);
        float height2 = fbm(ice_texture_uv2 * 1.7);
        vec2 surface_grad1 = vec2(
            fbm(ice_texture_uv1 * 1.7 + vec2(bump, 0.0)) - height1,
                                  fbm(ice_texture_uv1 * 1.7 + vec2(0.0, bump)) - height1
        ) / bump;
        vec2 surface_grad2 = vec2(
            fbm_lite(ice_texture_uv2 * 1.7 + vec2(bump, 0.0)) - height2,
                                  fbm_lite(ice_texture_uv2 * 1.7 + vec2(0.0, bump)) - height2
        ) / bump;
        surface_grad = surface_grad1 * ICE_texture_refraction1 + surface_grad2 * ICE_texture_refraction2;
    } else {
        // Legacy pre-optimization: full FBM and equal displacement per cell edges
        float height1 = fbm(ice_texture_uv1 * 1.7);
        float height2 = fbm(ice_texture_uv2 * 1.7);
        vec2 surface_grad1 = vec2(
            fbm(ice_texture_uv1 * 1.7 + vec2(bump, 0.0)) - height1,
                                  fbm(ice_texture_uv1 * 1.7 + vec2(0.0, bump)) - height1
        ) / bump;
        vec2 surface_grad2 = vec2(
            fbm(ice_texture_uv2 * 1.7 + vec2(bump, 0.0)) - height2,
                                  fbm(ice_texture_uv2 * 1.7 + vec2(0.0, bump)) - height2
        ) / bump;
        surface_grad = surface_grad1 * ICE_texture_refraction1 + surface_grad2 * ICE_texture_refraction2;
        // Reduce legacy-mode gradient amplitude to better match newer modes
        float legacy_grad_scale = 0.55;
        surface_grad *= legacy_grad_scale;
    }

    vec2 bend = facet_dir * 0.6 + surface_grad * 0.4;

    float refraction_px = ICE_REFRACTION_STRENGTH * REFRACTION_PX_SCALE;
    float edgeScale = (ICE_QUALITY_MODE == 2) ? 1.0 : (0.35 + 0.65 * crack_glow);
    vec2 sample_px = frag + bend * refraction_px * edgeScale;
    vec2 sample_uv = sample_px / safe_size;

    vec4 backdrop = texture(texUnit, sample_uv);
    vec4 clear_backdrop = sum;

    vec2 frost_uv = ice_texture_uv * max(ICE_frost_scale, 0.001);
    float veins =
    0.55 * ridge(frost_uv + vec2(19.19, 33.33)) +
    0.30 * ridge(frost_uv * 2.53 + vec2(7.31, 3.71)) +
    0.15 * value_noise(frost_uv * 5.1);

    vec2 edge_dist_px = min(frag, safe_size - frag);
    float border = 1.0 - smoothstep(
        0.0,
        max(ICE_edge_frost_px, 1.0),
                                    min(edge_dist_px.x, edge_dist_px.y)
    );

    float coverage = clamp(
        ICE_frost_amount * 0.45 + ICE_edge_frost * border * (0.7 + 0.3 * veins),
                           0.0,
                           1.0
    );
    float frost = smoothstep(1.0 - coverage, 1.16 - coverage, veins);
    float clump = fbm(frost_uv * 5.7 + vec2(3.1, 27.7));

    float ice_tint_amount = clamp(ICE_TINT_AMOUNT, 0.0, 1.0);
    vec3 ice_color = mix(
        backdrop.rgb,
        backdrop.rgb * ICE_TINT_COLOR,
        ice_tint_amount
    );
    vec3 frost_color = mix(
        vec3(0.72, 0.82, 0.94),
                           vec3(0.97, 1.0, 1.04),
                           clamp(clump * 0.8 + veins * 0.35, 0.0, 1.0)
    );
    ice_color = mix(ice_color, frost_color, frost * (0.50 + 0.22 * clump));

    float crack_intensity = ICE_CRACK_INTENSITY;
    vec3 crack_color = ICE_CRACK_COLOR;
    ice_color += crack_color * crack * crack_intensity;
    ice_color += crack_color * crack_glow * crack_intensity * 0.3;

    vec3 final_color = mix(clear_backdrop.rgb, ice_color, ICE_opacity);

    return roundedRectangle(uv * blurSize, final_color, cornerRadius);
}

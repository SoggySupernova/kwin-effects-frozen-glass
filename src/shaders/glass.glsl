// Uniforms passed from KWin C++ host
uniform float uAngleRad;
uniform float uFovStrength;         // Base FOV strength
uniform float refractionStrength;    // Re-purposed as FOV multiplier/scaler (0.0 to 1.0)
uniform float edgeSizePixels;    // Re-purposed as bottom bezel pixel control (0.0 to 1.0)

const float GOLDEN_ANGLE = 2.39996323;

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

vec4 getSample(vec2 sampleUv)
{
    if (sampleUv.x < 0.0 || sampleUv.x > 1.0 || sampleUv.y < 0.0 || sampleUv.y > 1.0) {
        return vec4(0.0, 0.0, 0.0, 1.0);
    }
    return texture(texUnit, sampleUv);
}

// Main entry point called by KWin's onscreen pass
vec4 glass(vec4 sum, vec4 cornerRadius)
{
    vec2 halfBlurSize = blurSize * 0.5;
    vec2 position = uv * blurSize - halfBlurSize;
    float dist = roundedRectangleDist(position, halfBlurSize, cornerRadius);

    // Return untreated backdrop outside the window borders
    if (dist >= 0.0) {
        return sum;
    }

    vec2 safe_size = max(blurSize, vec2(1.0));

    // Map bogus slider 1: refractionEdgeSize (0.0 to 1.0) -> Bezel size in pixels (0px to 100px)
    float bezelPx = edgeSizePixels * 20.0;
    float bezelUV = bezelPx / safe_size.y;

    // Map bogus slider 2: refractionStrength (0.0 to 1.0) -> Effective FOV Multiplier
    // Scales the base uFovStrength up to 0.50
    float effectiveFov = uFovStrength * refractionStrength * 2.0;

    // Shift Y origin so that Y = 0.0 sits at the hinge pivot
    float y_screen = uv.y + bezelUV;
    float x_screen = uv.x - 0.5;

    float sinT = sin(uAngleRad);
    float cosT = cos(uAngleRad);

    // 1. Calculate projection mapping onto static UI plane
    float uiY = (y_screen * sinT) - bezelUV;
    float distToUI = y_screen * cosT; // Distance from hinge increases along bezel + screen

    // 2. Keystone contraction calculation using effective FOV
    float keystoneFactor = 1.0 - (distToUI * effectiveFov);
    float uiX = (x_screen / max(keystoneFactor, 0.001)) + 0.5;

    vec2 baseUV = vec2(uiX, uiY);

    // 3. Distance-based Progressive Blur
    float blurRadius = distToUI * 0.04;
    vec4 colorSum = getSample(baseUV);
    float totalWeight = 1.0;

    for (int i = 1; i <= 15; i++) {
        float fi = float(i);
        float r = sqrt(fi / 15.0) * blurRadius;
        float theta = fi * GOLDEN_ANGLE;

        vec2 offset = vec2(cos(theta), sin(theta)) * r;
        float weight = 1.0 - (fi / 16.0);

        colorSum += getSample(baseUV + offset) * weight;
        totalWeight += weight;
    }

    vec3 finalColor = (colorSum / totalWeight).rgb * vec3(1.0 - distToUI, 1.0 - distToUI, 1.0 - distToUI);

    // Clip to rounded rectangle
    return roundedRectangle(uv * blurSize, finalColor, cornerRadius);
}

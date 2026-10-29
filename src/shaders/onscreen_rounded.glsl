#include "sdf.glsl"

uniform sampler2D texUnit;
uniform mat4 colorMatrix;
uniform float offset;
uniform vec2 halfpixel;
uniform vec4 box;
uniform vec4 cornerRadius;
uniform float opacity;
uniform vec2 blurSize;

in vec2 uv;
in vec2 vertex;

uniform int meshMode;
uniform vec2 bgSize;

vec2 backdropUv()
{
    if (meshMode == 1) {
        // deformed screen position -> background texture coordinate (y flipped like uv)
        return vec2(vertex.x / bgSize.x, 1.0 - vertex.y / bgSize.y);
    }
    return uv;
}

#include "oklab.glsl"
#include "glass.glsl"

void main(void)
{
    vec2 buv = backdropUv();
    vec2 halfBlurSize = blurSize * 0.5;
    float minHalfSize = min(halfBlurSize.x, halfBlurSize.y);

    vec2 position = uv * blurSize - halfBlurSize.xy;
    float dist = roundedRectangleDist(position, halfBlurSize, cornerRadius);

    vec4 sum = vec4(0);
    if (dist <= 0.0) {
        sum = texture(texUnit, buv + vec2(-halfpixel.x * 2.0, 0.0) * offset);
        sum += texture(texUnit, buv + vec2(-halfpixel.x, halfpixel.y) * offset) * 2.0;
        sum += texture(texUnit, buv + vec2(0.0, halfpixel.y * 2.0) * offset);
        sum += texture(texUnit, buv + vec2(halfpixel.x, halfpixel.y) * offset) * 2.0;
        sum += texture(texUnit, buv + vec2(halfpixel.x * 2.0, 0.0) * offset);
        sum += texture(texUnit, buv + vec2(halfpixel.x, -halfpixel.y) * offset) * 2.0;
        sum += texture(texUnit, buv + vec2(0.0, -halfpixel.y * 2.0) * offset);
        sum += texture(texUnit, buv + vec2(-halfpixel.x, -halfpixel.y) * offset) * 2.0;
        sum /= 12.0;
    }

    sum = glass(sum, cornerRadius);


    vec2 maskVertex = vertex;
    if (meshMode == 1) {
        // rest position in the same space as `box`
        maskVertex = (box.xy - box.zw) + vec2(uv.x, 1.0 - uv.y) * blurSize;
    }
    float f = sdfRoundedBox(maskVertex, box.xy, box.zw, cornerRadius);
    float df = fwidth(f);


    sum *= 1.0 - clamp(0.5 + f / df, 0.0, 1.0);

    if (useOklabSaturation == 1) {
        sum.rgb = oklabSaturate(sum.rgb, saturation);
    }

    fragColor = sum * colorMatrix * opacity;
}

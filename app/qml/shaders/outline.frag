#version 440

// Text outline. Grows the glyphs' alpha outward by `radius` pixels (a
// dilation: each pixel takes the strongest glyph alpha found within the
// radius) and paints that shape in `outlineColor`. NodeRenderer draws the
// result underneath the text, so it reads as a stroke wrapped around every
// letter, the way EasyWorship's outline does.
//
// `softness` 0 is a crisp stroke. Raising it fades the stroke's outer part,
// from a hard edge to a soft halo that falls off across the whole radius.
//
// Sampling: the centre plus RINGS rings of STEPS points, odd rings rotated
// half a step so the rings interleave. NodeRenderer caches the output in a
// layer, so this runs when the text changes, not every frame.

layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

// qt_Matrix and qt_Opacity MUST come first (default ShaderEffect vertex
// shader). The rest match ShaderEffect properties by name.
layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec4  outlineColor;   // straight (not premultiplied) RGBA
    vec2  texel;          // 1 / source texture size
    float radius;         // stroke width, texture pixels
    float softness;       // 0 crisp .. 1 fully feathered
};

layout(binding = 1) uniform sampler2D source;

const int   RINGS = 3;
const int   STEPS = 24;
const float TAU   = 6.28318530718;

void main() {
    float r     = max(radius, 0.0);
    float inner = r * (1.0 - clamp(softness, 0.0, 1.0));
    float a     = texture(source, qt_TexCoord0).a;

    for (int i = 1; i <= RINGS; ++i) {
        float d = r * float(i) / float(RINGS);
        // Full strength inside `inner`, easing to zero at the outer edge.
        float w = d <= inner ? 1.0 : 1.0 - smoothstep(inner, r + 1e-4, d);
        float stagger = (i % 2 == 1) ? 0.5 : 0.0;
        for (int j = 0; j < STEPS; ++j) {
            float ang = TAU * (float(j) + stagger) / float(STEPS);
            vec2  off = vec2(cos(ang), sin(ang)) * d * texel;
            a = max(a, texture(source, qt_TexCoord0 + off).a * w);
        }
    }

    // Premultiplied output.
    fragColor = vec4(outlineColor.rgb * outlineColor.a, outlineColor.a) * a * qt_Opacity;
}

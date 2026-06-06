#version 440

// Animated multi-style gradient for container backgrounds. One shader covers
// linear / radial / conic / mesh, selected by `gradientType`. Colors, count,
// angle and time arrive as uniforms set from GradientFill.qml. `time` is
// already pre-scaled by the editor's speed setting and frozen when animation
// is off, so the motion here just reads it directly.

layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

// std140 block shared with the default ShaderEffect vertex shader. qt_Matrix
// and qt_Opacity MUST come first (the built-in vertex stage expects them);
// every other member is matched to a ShaderEffect property of the same name.
layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec4  color0;
    vec4  color1;
    vec4  color2;
    vec4  color3;
    vec4  color4;
    vec4  color5;
    int   colorCount;    // 2..6 active stops
    int   gradientType;  // 0 linear, 1 radial, 2 conic, 3 mesh
    float angle;         // radians: linear direction / conic offset
    float time;          // seconds * speed; frozen when animation is off
};

const float PI = 3.14159265359;

// GLSL can't dynamically index a set of separate uniforms — branch instead.
vec3 colorAt(int i) {
    if (i <= 0) return color0.rgb;
    if (i == 1) return color1.rgb;
    if (i == 2) return color2.rgb;
    if (i == 3) return color3.rgb;
    if (i == 4) return color4.rgb;
    return color5.rgb;
}

// Evenly-spaced color ramp across the active stops, sampled at t in 0..1.
vec3 rampColor(float t) {
    int   n      = max(colorCount, 2);
    float scaled = clamp(t, 0.0, 1.0) * float(n - 1);
    int   i      = int(floor(scaled));
    float f      = fract(scaled);
    return mix(colorAt(i), colorAt(min(i + 1, n - 1)), f);
}

// Mesh: each active color orbits a golden-angle base position; the pixel color
// is an inverse-distance-weighted blend, giving a soft, seam-free flow.
vec3 meshColor(vec2 uv) {
    vec3  acc  = vec3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 6; ++i) {
        if (i >= colorCount) break;
        float fi   = float(i);
        // Golden-angle (2.39996 rad) spread keeps points apart at any count.
        vec2  base = vec2(0.5 + 0.34 * cos(fi * 2.39996),
                          0.5 + 0.34 * sin(fi * 2.39996));
        vec2  p    = base + 0.16 * vec2(sin(time * 0.7 + fi * 1.7),
                                        cos(time * 0.6 + fi * 2.3));
        float d    = distance(uv, p);
        float w    = 1.0 / (d * d + 0.02);   // +0.02 softens the singularity
        acc  += colorAt(i) * w;
        wsum += w;
    }
    return acc / max(wsum, 0.0001);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec3 rgb;

    if (gradientType == 0) {
        // Linear: project onto the angle direction, drifting slowly with time.
        vec2  dir = vec2(cos(angle), sin(angle));
        float t   = dot(uv - 0.5, dir) + 0.5;
        rgb = rampColor(fract(t - time * 0.05));
    } else if (gradientType == 1) {
        // Radial: distance from center, with a gentle breathing offset.
        float t = length(uv - 0.5) * 1.41421356;   // 0..1 out to the corners
        rgb = rampColor(fract(t - time * 0.05));
    } else if (gradientType == 2) {
        // Conic: angle around center, rotating with time.
        vec2  d = uv - 0.5;
        float a = atan(d.y, d.x) + angle + time * 0.3;
        rgb = rampColor(fract(a / (2.0 * PI) + 1.0));
    } else {
        // Mesh: flowing aurora blend.
        rgb = meshColor(uv);
    }

    // Premultiplied output so the scene-graph compositor blends correctly at
    // partial item opacity (container fade on go-live / clear, theme tiles).
    fragColor = vec4(rgb * qt_Opacity, qt_Opacity);
}

#version 440

// Animated multi-style gradient for container backgrounds. One shader covers
// linear / radial / conic / mesh, selected by `gradientType`. Stops carry full
// RGBA, so a transparent->opaque ramp (e.g. a lower-third fade-to-black scrim)
// composites over whatever sits behind the node. Colors, count, angle and time
// arrive as uniforms set from GradientFill.qml; `time` is pre-scaled by the
// editor's speed setting.
//
// Linear and radial are CLAMPED static ramps (their endpoints are exact, which
// a scrim needs). Conic and mesh are the animated styles — both periodic, so
// they flow seam-free; `time` does nothing for linear/radial.

layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

// std140 block shared with the default ShaderEffect vertex shader. qt_Matrix
// and qt_Opacity MUST come first; every other member is matched to a
// ShaderEffect property of the same name.
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
    float time;          // seconds * speed (conic / mesh only)
};

const float PI = 3.14159265359;

// GLSL can't dynamically index a set of separate uniforms — branch instead.
// Returns the full RGBA stop so per-stop alpha survives.
vec4 colorAt(int i) {
    if (i <= 0) return color0;
    if (i == 1) return color1;
    if (i == 2) return color2;
    if (i == 3) return color3;
    if (i == 4) return color4;
    return color5;
}

// Evenly-spaced color ramp across the active stops, sampled at t in 0..1.
// t is clamped, so passing a raw (un-wrapped) coordinate gives exact endpoints.
vec4 rampColor(float t) {
    int   n      = max(colorCount, 2);
    float scaled = clamp(t, 0.0, 1.0) * float(n - 1);
    int   i      = int(floor(scaled));
    float f      = fract(scaled);
    return mix(colorAt(i), colorAt(min(i + 1, n - 1)), f);
}

// Mesh: each active color orbits a golden-angle base position; the pixel color
// is an inverse-distance-weighted blend (including alpha), giving a soft,
// seam-free flow.
vec4 meshColor(vec2 uv) {
    vec4  acc  = vec4(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 6; ++i) {
        if (i >= colorCount) break;
        float fi   = float(i);
        vec2  base = vec2(0.5 + 0.34 * cos(fi * 2.39996),
                          0.5 + 0.34 * sin(fi * 2.39996));
        vec2  p    = base + 0.16 * vec2(sin(time * 0.7 + fi * 1.7),
                                        cos(time * 0.6 + fi * 2.3));
        float d    = distance(uv, p);
        float w    = 1.0 / (d * d + 0.02);
        acc  += colorAt(i) * w;
        wsum += w;
    }
    return acc / max(wsum, 0.0001);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec4 c;

    if (gradientType == 0) {
        // Linear: clamped directional ramp (static — use conic/mesh to animate).
        vec2  dir = vec2(cos(angle), sin(angle));
        float t   = dot(uv - 0.5, dir) + 0.5;
        c = rampColor(t);
    } else if (gradientType == 1) {
        // Radial: clamped center-out ramp (static).
        float t = length(uv - 0.5) * 1.41421356;   // 0..1 out to the corners
        c = rampColor(t);
    } else if (gradientType == 2) {
        // Conic: angle around center, rotating with time. Periodic, so the
        // fract() wrap is seam-correct here (the ramp closes the circle).
        vec2  d = uv - 0.5;
        float a = atan(d.y, d.x) + angle + time * 0.3;
        c = rampColor(fract(a / (2.0 * PI) + 1.0));
    } else {
        // Mesh: flowing aurora blend.
        c = meshColor(uv);
    }

    // Straight-alpha stops -> premultiplied output, then the node's own
    // opacity. Transparent stops therefore reveal whatever is composited
    // behind this node (background image / lower theme nodes).
    float a = c.a * qt_Opacity;
    fragColor = vec4(c.rgb * a, a);
}

#version 440

// Animated multi-style gradient. One shader covers linear / radial / conic /
// mesh / reflected / diamond, selected by `gradientType`. Stops carry full
// RGBA *and* a normalized position (offsetN), so professional non-even ramps
// (e.g. a glossy highlight bunched near the top, or a fade-to-black scrim)
// render exactly. A `finish` pass adds a glossy specular sheen or a matte
// softening on top of whatever colors are chosen. Colors, count, offsets,
// angle, time and finish arrive as uniforms set from GradientFill.qml; `time`
// is pre-scaled by the editor's speed setting.
//
// Linear / radial / reflected / diamond are CLAMPED static ramps (their
// endpoints are exact, which a scrim needs). Conic and mesh are the animated
// styles — both periodic, so they flow seam-free; `time` is inert otherwise.

layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

// std140 block shared with the default ShaderEffect vertex shader. qt_Matrix
// and qt_Opacity MUST come first; every other member is matched to a
// ShaderEffect property of the same name. Scalars pack in declaration order.
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
    int   gradientType;  // 0 linear, 1 radial, 2 conic, 3 mesh, 4 reflected, 5 diamond
    float angle;         // radians: linear/reflected direction, conic offset
    float time;          // seconds * speed (conic / mesh only)
    float offset0;       // per-stop positions, 0..1, ascending
    float offset1;
    float offset2;
    float offset3;
    float offset4;
    float offset5;
    int   finish;        // 0 none, 1 glossy, 2 matte
};

const float PI = 3.14159265359;

// GLSL can't dynamically index a set of separate uniforms — branch instead.
vec4 colorAt(int i) {
    if (i <= 0) return color0;
    if (i == 1) return color1;
    if (i == 2) return color2;
    if (i == 3) return color3;
    if (i == 4) return color4;
    return color5;
}
float offsetAt(int i) {
    if (i <= 0) return offset0;
    if (i == 1) return offset1;
    if (i == 2) return offset2;
    if (i == 3) return offset3;
    if (i == 4) return offset4;
    return offset5;
}

// Position-aware color ramp: interpolate between the two stops bracketing t,
// using each stop's own offset. t is clamped, so a raw (un-wrapped) coordinate
// gives exact endpoints. Evenly-spaced offsets reproduce a classic even ramp.
vec4 rampColor(float t) {
    int n = max(colorCount, 2);
    t = clamp(t, 0.0, 1.0);
    if (t <= offsetAt(0)) return colorAt(0);
    for (int i = 0; i < 5; ++i) {
        if (i + 1 >= n) break;
        float a = offsetAt(i);
        float b = offsetAt(i + 1);
        if (t <= b) {
            float f = (b > a) ? (t - a) / (b - a) : 0.0;
            return mix(colorAt(i), colorAt(i + 1), clamp(f, 0.0, 1.0));
        }
    }
    return colorAt(n - 1);
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

// Finish pass — applied to rgb after the base fill. Glossy adds a top-lit
// specular sheen (the "glass" look) independent of the chosen colors; matte
// removes any sheen and softens with a gentle desaturation + vignette.
vec3 applyFinish(vec3 col, vec2 uv) {
    if (finish == 1) {
        float g = smoothstep(0.5, 0.0, uv.y);          // 1 at top → 0 at mid
        col += pow(g, 1.5) * 0.16;                      // upper brightening
        float band = exp(-pow((uv.y - 0.12) / 0.07, 2.0)) * 0.12;  // sheen line
        col += band;
        col -= smoothstep(0.62, 1.0, uv.y) * 0.06;      // slight lower shade
    } else if (finish == 2) {
        float luma = dot(col, vec3(0.299, 0.587, 0.114));
        col = mix(col, vec3(luma), 0.10);               // gentle desaturation
        col *= 1.0 - 0.10 * length(uv - 0.5);           // soft vignette
    }
    return clamp(col, 0.0, 1.0);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec4 c;

    if (gradientType == 0) {
        // Linear: clamped directional ramp.
        vec2  dir = vec2(cos(angle), sin(angle));
        float t   = dot(uv - 0.5, dir) + 0.5;
        c = rampColor(t);
    } else if (gradientType == 1) {
        // Radial: clamped center-out ramp.
        float t = length(uv - 0.5) * 1.41421356;   // 0..1 out to the corners
        c = rampColor(t);
    } else if (gradientType == 2) {
        // Conic: angle around center, rotating with time. Periodic → the
        // fract() wrap is seam-correct (the ramp closes the circle).
        vec2  d = uv - 0.5;
        float a = atan(d.y, d.x) + angle + time * 0.3;
        c = rampColor(fract(a / (2.0 * PI) + 1.0));
    } else if (gradientType == 4) {
        // Reflected: mirror the linear ramp around the center line.
        vec2  dir = vec2(cos(angle), sin(angle));
        float t   = abs(dot(uv - 0.5, dir)) * 2.0;
        c = rampColor(t);
    } else if (gradientType == 5) {
        // Diamond: Manhattan distance → rhombus isolines.
        float t = (abs(uv.x - 0.5) + abs(uv.y - 0.5)) * 1.41421356;
        c = rampColor(t);
    } else {
        // Mesh: flowing aurora blend.
        c = meshColor(uv);
    }

    c.rgb = applyFinish(c.rgb, uv);

    // Straight-alpha stops -> premultiplied output, then the node's own
    // opacity. Transparent stops therefore reveal whatever is composited
    // behind this node (background image / lower theme nodes).
    float a = c.a * qt_Opacity;
    fragColor = vec4(c.rgb * a, a);
}

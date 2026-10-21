#version 440

// Draws a video with an alpha channel over whatever is behind it.
//
// VideoOutput draws its frames with blending off and straight (not
// premultiplied) colour, so a transparent pixel replaces what's under it
// instead of letting it show through. MediaBackgroundLoader and MediaMonitor
// render such a video into a layer (where that replace is exactly what's
// wanted: the layer starts transparent) and draw the layer through this,
// which premultiplies so the scene graph blends it properly.
//
// Only used when MediaPlaybackService.hasAlpha() says the frames carry
// alpha, so ordinary video never pays for the extra pass.

layout(location = 0) in  vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec4 c = texture(source, qt_TexCoord0);
    fragColor = vec4(c.rgb * c.a, c.a) * qt_Opacity;
}

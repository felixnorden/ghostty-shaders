// cursor_lavender.glsl
//
// A lavender cursor settle for Catppuccin Macchiato.
//
// Draws a short comet trail from the previous cursor cell to the current one,
// then retracts it into the cursor. Glyphs under the trail stay readable: the
// effect only tints the composited frame, it never samples or blanks text.
//
// Design rules, in priority order:
//
//   1. Silent for small moves. Typing one character must not animate anything,
//      because the trail would land in the exact spot your eye tracks. The
//      threshold is one cell *height* times MIN_MOVE; with a typical monospace
//      advance of about half the line height, that silences one character and
//      lets two or more through.
//   2. Silent for long jumps. Enter, page jumps and pane switches must not
//      paint a full-screen smear.
//   3. Nothing is computed outside the trail bounding box. Cost tracks trail
//      size, not screen size.
//   4. The cursor itself is never repainted. cursor-color, cursor-text and
//      cursor-style in the config stay authoritative, so block, bar,
//      underline and hollow cursors all keep working.
//   5. Only the uniforms the previously working shader proved in this build are
//      touched: iChannel0, iResolution, iTime, iTimeCursorChange,
//      iCurrentCursor, iPreviousCursor. iCursorVisible and iFocus are declared
//      differently than the docs describe and fail to compile (spirv error:
//      "vector swizzle selection out of range"), which silently disables the
//      whole effect. Do not add them back without checking the log.

// Catppuccin Macchiato lavender, #b7bdf8. A constant on purpose: reading
// iCurrentCursorColor would couple the effect to whatever an application
// reports, and that uniform is one of the ones that break this build.
const vec3 LAVENDER = vec3(0.717647, 0.741176, 0.972549);

const float DURATION = 0.24; // seconds until the streak has vanished
const float MIN_MOVE = 0.6; // line heights; one character advance is ~0.5
const float MAX_TRAIL = 12.0; // line heights; above this, no trail at all

// A one-cell vertical move leaves no room for a trail: the two cells touch, so
// the trail is hidden under the cursor block. A brief glow around the target
// cell gives vertical moves and Enter the feedback the trail cannot.
const float PULSE_DURATION = 0.13; // seconds until the glow is gone
const float PULSE_ALPHA = 0.34; // glow opacity at the moment of landing
const float PULSE_SCALE = 0.95; // glow radius, as a multiple of the cell size
const float HEAD_ALPHA = 1.0; // streak opacity at the cursor end
const float TAIL_ALPHA = 0.55; // streak opacity at the far end
const float HALO_SCALE = 1.9; // glow radius, as a multiple of the streak radius
const float HALO_ALPHA = 0.22; // glow opacity
const float FEATHER = 1.4; // edge softness in pixels

// The blaze look: a solid streak with a pale edge, the way cursor_blaze drew an
// accent border around a filled parallelogram. The rim is the same lavender
// pushed toward white, so the effect stays one hue.
const float RIM_WIDTH = 2.2; // px, half band centred on the streak outline
const float RIM_ALPHA = 1.0; // rim opacity at full life
const float RIM_WHITEN = 0.65; // how far the rim moves toward white

float fxSdSegment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
    return length(pa - ba * h);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
#if !defined(WEB)
    fragColor = texture(iChannel0, fragCoord.xy / iResolution.xy);
#endif
    vec4 base = fragColor;

    // Cursor rectangles in pixel space: .xy is the top-left corner, .zw the
    // width and height, +Y up.
    float cellWidth = max(iCurrentCursor.z, 1.0);
    float cellHeight = max(iCurrentCursor.w, 1.0);

    vec2 curCenter = iCurrentCursor.xy + vec2(cellWidth, -cellHeight) * 0.5;
    vec2 prevCenter = iPreviousCursor.xy + vec2(iPreviousCursor.z, -iPreviousCursor.w) * 0.5;

    // Match the trail thickness to the cursor: a full cell for a block cursor,
    // a hairline for a bar cursor.
    float radius = max(min(cellWidth, cellHeight) * 0.5, 1.5);

    // Length limits scale with the larger cursor dimension, which is the line
    // height for a block or bar cursor and the advance for an underline. That
    // keeps the thresholds identical across cursor styles. Raise MIN_MOVE to
    // 1.0 if a trail on every two-character edit still feels busy.
    float cell = max(cellWidth, cellHeight);

    float dist = length(curCenter - prevCenter);
    if (dist <= MIN_MOVE * cell) return;
    if (dist > MAX_TRAIL * cell) return;

    float progress = clamp((iTime - iTimeCursorChange) / DURATION, 0.0, 1.0);
    float pulseProgress = clamp((iTime - iTimeCursorChange) / PULSE_DURATION, 0.0, 1.0);
    if (progress >= 1.0 && pulseProgress >= 1.0) return;

    float ease = 1.0 - pow(1.0 - progress, 3.0);

    // The tail is pulled forward into the cursor. Falling back toward the old
    // cell instead would read as a second cursor.
    vec2 tail = mix(prevCenter, curCenter, ease);

    // Cheap rejection before any square root: most of the screen dies here.
    // The box has to cover the glow around the cursor as well as the trail.
    float pulseRadius = cell * PULSE_SCALE;
    float pad = max(radius * HALO_SCALE + FEATHER, pulseRadius + FEATHER);
    vec2 lo = min(tail, curCenter) - vec2(pad);
    vec2 hi = max(tail, curCenter) + vec2(pad);
    if (fragCoord.x < lo.x || fragCoord.x > hi.x) return;
    if (fragCoord.y < lo.y || fragCoord.y > hi.y) return;

    vec3 tint = LAVENDER;
    float alpha = 0.0;

    // Landing glow. Drawn before the streak so the two add up where they overlap.
    if (pulseProgress < 1.0) {
        float pulseDist = length(fragCoord - curCenter);
        float ring = 1.0 - smoothstep(pulseRadius * 0.5, pulseRadius, pulseDist);
        alpha = ring * PULSE_ALPHA * (1.0 - pulseProgress);
    }

    float haloWidth = radius * (HALO_SCALE - 1.0) + FEATHER;
    float dTrail = fxSdSegment(fragCoord, tail, curCenter) - radius;
    if (dTrail <= haloWidth) {
        // Brightest at the cursor end, dimmest where the streak was born.
        vec2 span = curCenter - tail;
        float along = clamp(dot(fragCoord - tail, span) / max(dot(span, span), 1e-6), 0.0, 1.0);
        float alive = (1.0 - ease) * mix(TAIL_ALPHA / HEAD_ALPHA, 1.0, smoothstep(0.0, 1.0, along));

        float core = 1.0 - smoothstep(0.0, FEATHER, dTrail);
        float halo = 1.0 - smoothstep(0.0, haloWidth, dTrail);
        float fill = (core * HEAD_ALPHA + halo * HALO_ALPHA) * alive;

        // Pale edge on the streak outline: this is what reads as a streak
        // rather than a wash, and it survives being drawn over busy text.
        float rim = 1.0 - smoothstep(0.0, RIM_WIDTH, abs(dTrail));
        tint = mix(LAVENDER, vec3(1.0), rim * RIM_WHITEN);

        alpha += max(fill, rim * RIM_ALPHA * alive);
    }

    alpha = clamp(alpha, 0.0, 1.0);
    if (alpha <= 0.0) return;

    fragColor = vec4(mix(base.rgb, tint, alpha), base.a);
}

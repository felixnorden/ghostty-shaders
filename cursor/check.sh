#!/usr/bin/env bash
# Compile-check the custom Ghostty shaders in this directory.
#
# Ghostty only reports GLSL errors in its log, and a shader that fails to
# compile is silently ignored. This script compiles each shader against a
# preamble that mirrors Ghostty's Shadertoy wrapper, so a typo fails here
# instead of looking like a shader that "just does not do much".
#
# Requires glslangValidator: brew install glslang
# Usage: ./check.sh [shader.glsl ...]

set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! command -v glslangValidator >/dev/null 2>&1; then
    echo "error: glslangValidator not found. Install it with: brew install glslang" >&2
    exit 1
fi

# Every uniform Ghostty documents for custom shaders, plus the main() that
# calls mainImage. Plain form: OpenGL SPIR-V and plain GLSL checks.
cat >"$tmp/plain.tmpl" <<'PREAMBLE'
#version VER
layout(location = 0) out vec4 fragColor;
uniform sampler2D iChannel0;
uniform vec3 iResolution;
uniform vec3 iChannelResolution[4];
uniform float iTime;
uniform float iTimeDelta;
uniform float iChannelTime[4];
uniform int iFrame;
uniform vec4 iMouse;
uniform vec4 iDate;
uniform float iSampleRate;
uniform vec4 iCurrentCursor;
uniform vec4 iPreviousCursor;
uniform vec4 iCurrentCursorColor;
uniform vec4 iPreviousCursorColor;
uniform vec4 iCurrentCursorStyle;
uniform vec4 iPreviousCursorStyle;
uniform vec4 iCursorVisible;
uniform float iTimeCursorChange;
uniform float iTimeFocus;
uniform int iFocus;
uniform vec3 iPalette[256];
uniform vec3 iBackgroundColor;
uniform vec3 iForegroundColor;
uniform vec3 iCursorColor;
uniform vec3 iCursorText;
uniform vec3 iSelectionBackgroundColor;
uniform vec3 iSelectionForegroundColor;
#define CURSORSTYLE_BLOCK 0
#define CURSORSTYLE_BLOCK_HOLLOW 1
#define CURSORSTYLE_BAR 2
#define CURSORSTYLE_UNDERLINE 3
#define CURSORSTYLE_LOCK 4
void mainImage(out vec4, in vec2);
void main() { mainImage(fragColor, gl_FragCoord.xy); }
PREAMBLE

# Vulkan requires non-opaque uniforms inside a block.
cat >"$tmp/vulkan.tmpl" <<'PREAMBLE'
#version VER
layout(location = 0) out vec4 fragColor;
layout(set = 0, binding = 0) uniform sampler2D iChannel0;
layout(set = 0, binding = 1) uniform GhosttyUniforms {
    vec3 iResolution;
    vec3 iChannelResolution[4];
    float iTime;
    float iTimeDelta;
    float iChannelTime[4];
    vec4 iMouse;
    vec4 iDate;
    vec4 iCurrentCursor;
    vec4 iPreviousCursor;
    vec4 iCurrentCursorColor;
    vec4 iPreviousCursorColor;
    vec4 iCurrentCursorStyle;
    vec4 iPreviousCursorStyle;
    vec4 iCursorVisible;
    float iTimeCursorChange;
    float iTimeFocus;
    int iFrame;
    int iFocus;
    float iSampleRate;
    vec3 iPalette[256];
    vec3 iBackgroundColor;
    vec3 iForegroundColor;
    vec3 iCursorColor;
    vec3 iCursorText;
    vec3 iSelectionBackgroundColor;
    vec3 iSelectionForegroundColor;
};
void mainImage(out vec4, in vec2);
void main() { mainImage(fragColor, gl_FragCoord.xy); }
PREAMBLE

failures=0

# Uniforms proven to work in this Ghostty build, taken from the shader that was
# running before this work: iChannel0, iResolution, iTime, iTimeCursorChange,
# iCurrentCursor, iPreviousCursor. Anything outside this set must be verified
# against the real app, because the docs' declared types can differ from the
# wrapper's: iCursorVisible/iFocus break compilation with "vector swizzle
# selection out of range", which this harness cannot reproduce.
PROVEN_UNIFORMS="iChannel0 iCurrentCursor iPreviousCursor iResolution iTime iTimeCursorChange"

warn_unproven_uniforms() {
    local shader=$1 u
    for u in $(sed 's|//.*||' "$shader" | rg -o '\bi[A-Z][A-Za-z0-9]*' | sort -u); do
        case " $PROVEN_UNIFORMS " in
            *" $u "*) ;;
            *)
                printf '  NOTE  %-13s %s uses unproven uniform %s\n' "" "$(basename "$shader")" "$u"
                ;;
        esac
    done
}

# --live: ask Ghostty itself. The app logs the only verdict that counts.
live_check() {
    local window=${1:-15m} bad=0
    echo "Ghostty log, last $window:"
    while IFS= read -r line; do
        bad=1
        printf '  LIVE FAIL  %s\n' "$line"
    done < <(log show --last "$window" --style compact --predicate 'process == "ghostty"' 2>/dev/null \
        | rg -i 'spirv error|GlslangFailed|error loading custom shaders' | tail -5)
    if [ "$bad" -eq 0 ]; then
        echo "  no shader errors logged"
        return 0
    fi
    return 1
}

if [ "${1:-}" = "--live" ]; then
    live_check "${2:-15m}"
    exit $?
fi

# run_glslang <frag> <flags...>: validates one assembled file. Output goes to
# $tmp so nothing is ever written into the config directory.
run_glslang() {
    local frag=$1
    shift
    local -a args=(-S frag)
    case " $* " in
        *" -G "* | *" -V "*) args+=(-o "$tmp/${frag##*/}.spv") ;;
    esac
    glslangValidator "${args[@]}" "$@" "$frag"
}

# assemble <template> <version> <shader> [defines] -> prints the path of the .frag
assemble() {
    local tmpl=$1 ver=$2 shader=$3 defines=${4:-} out suffix
    suffix=""
    [ -n "$defines" ] && suffix="-defined"
    out="$tmp/$(basename "$shader" .glsl)-$ver$suffix.frag"
    sed "s/VER/$ver/" "$tmp/$tmpl" >"$out"
    if [ -n "$defines" ]; then
        printf '%s\n' "$defines" >>"$out"
    fi
    cat "$shader" >>"$out"
    printf '%s' "$out"
}

# compile <label> <template> <version> <flags> <shader> [defines]
compile() {
    local label=$1 tmpl=$2 ver=$3 flags=$4 shader=$5 defines=${6:-} frag out
    frag=$(assemble "$tmpl" "$ver" "$shader" "$defines")
    # shellcheck disable=SC2086
    if out=$(run_glslang "$frag" $flags 2>&1); then
        printf '  ok    %-13s %s\n' "$label" "$(basename "$shader")"
    else
        printf '  FAIL  %-13s %s\n' "$label" "$(basename "$shader")"
        printf '%s\n' "$out" | rg -v -e '^\s*$' -e "^$frag$" | sed 's/^/          /'
        failures=$((failures + 1))
    fi
    if printf '%s' "$out" | rg -qi 'warning'; then
        printf '  WARN  %-13s %s\n' "$label" "$(basename "$shader")"
        printf '%s\n' "$out" | rg -i 'warning' | head -5 | sed 's/^/          /'
    fi
}

# Self-test: a broken shader must fail, or this harness proves nothing.
printf 'void mainImage(out vec4 fragColor, in vec2 fragCoord) {\n    fragColor = nonsense_symbol(fragCoord);\n}\n' >"$tmp/broken.glsl"
if run_glslang "$(assemble plain.tmpl 450 "$tmp/broken.glsl")" -G --aml --amb >/dev/null 2>&1; then
    echo "harness self-test failed: a broken shader compiled cleanly" >&2
    exit 1
fi

shaders=("$@")
if [ ${#shaders[@]} -eq 0 ]; then
    shopt -s nullglob
    shaders=("$here"/*.glsl)
    shopt -u nullglob
fi

if [ ${#shaders[@]} -eq 0 ]; then
    echo "no shaders to check in $here" >&2
    exit 1
fi

for shader in "${shaders[@]}"; do
    echo "$(basename "$shader")"
    warn_unproven_uniforms "$shader"
    compile "opengl-spirv" plain.tmpl 450 "-G --aml --amb" "$shader"
    compile "vulkan1.0" vulkan.tmpl 450 "-V --target-env vulkan1.0" "$shader"
    compile "glsl330" plain.tmpl 330 "" "$shader"
    compile "glsl330-WEB" plain.tmpl 330 "" "$shader" "#define WEB"
done

if [ "$failures" -gt 0 ]; then
    echo "FAILED: $failures target(s) did not compile"
    exit 1
fi

echo "all shaders compile; harness self-test passed"
echo "note: the harness preamble is an approximation. Reload Ghostty, then run"
echo "      './check.sh --live' to read the app's own verdict."
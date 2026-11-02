# Glass + Wobbly Windows: Maintenance Guide

Oct 29, 2026 · @Person

## Overview

The glass effect follows Wobbly Windows' deformed mesh while its backdrop stays pinned to the screen. Two plugins cooperate through window data roles: `glass` (chain position 20) and `glass_wobbly` (a fork of KWin's Wobbly Windows, position 70).

- **`glass`** blurs the real screen behind a window. When the fork has published a mesh for that window, it draws the glass pattern on the deformed triangles and samples the backdrop at the deformed screen positions.
- **`glass_wobbly`** behaves like stock Wobbly Windows and also publishes the deformed and rest-pose mesh of each wobbling window.

Two designs failed and should not come back. Running glass after Wobbly (positions 71 or 150) puts it inside Wobbly's offscreen pass, where the render target is the padded window texture and the backdrop copy comes out black. Drawing the glass into that texture from the real screen instead pastes the backdrop onto the window like a sticker, so it moves with the mesh. The fork exists because stock Wobbly keeps its mesh private and hands its quads only to `apply()` as a local list.

Without the fork loaded, glass falls back to upstream behaviour: transformed windows are not blurred.

## Changes versus upstream

Every divergence from upstream KWin blur and stock Wobbly Windows, as built in this conversation.

| File | Change | Why |
| --- | --- | --- |
| `src/glassmesh.h` (new) | Three window data roles shared by both plugins | The contract between glass and the fork |
| `src/CMakeLists.txt` | `add_subdirectory(wobbly)` inside `if(GLASS_WAYLAND)` | Builds the fork |
| `src/blur.h` | `meshModeLocation`, `bgSizeLocation`, `postPaintScreen()` override, `m_meshRepaint` | Mesh uniforms; repaint of last frame's glass |
| `src/blur.cpp` | `shouldBlur` exemption keyed on the tracked role; mesh read and quad culling at the top of `blur()`; `backgroundRect` united with the mesh bounds and snapped to 64 px; vertex upload rewritten with `pushVertex`/`pushRect`; two new uniforms; `postPaintScreen()` | Draw glass on the deformed mesh |
| `src/shaders/onscreen_rounded.glsl` | `meshMode`, `bgSize`, `backdropUv()`; blur taps use `buv`; mask uses the rest position | `uv` carries the rest position, `vertex` the deformed screen position |
| `src/shaders/glass.glsl` | Backdrop sample coordinate branches on `meshMode` | Same reason |
| `src/wobbly/` (new) | Fork of Wobbly Windows, built as `glass_wobbly.so` | Publishes the mesh |

`blur.h` keeps `requestedEffectChainPosition()` at 20, as upstream. Do not move it.

### Fork changes versus stock Wobbly

- Classes renamed to `GlassWobblyEffect` and `GlassWobblyConfig`, to avoid clashing with the built-in effect.
- `main.cpp` refers to `metadata.json`, not `metadata.json.stripped`, because the fork uses a plain `add_library` instead of `kwin_add_builtin_effect`.
- `metadata.json` has no `X-KDE-ConfigModule`, no `Id`, and `EnabledByDefault` false. The effect id comes from the file name.
- `wobblywindows.kcfg` is unchanged, so the fork reads the stock `Effect-wobblywindows` group. The KCM files are not copied; the stock settings page edits the same group.
- `prePaintWindow` and `apply()` publish and clear the data roles (see the data contract).

### Upstream bug fixed on the way

Upstream counted frame vertices whenever `splitRenderRegions` was true but appended them only when `splitBlurSettings` was true, so `excludeDecorations` alone drew uninitialised vertices. The rewritten upload appends frame geometry whenever it counts it. You can commit this fix on its own.

## Data contract between the plugins

Both plugins include `src/glassmesh.h` and exchange data with `EffectWindow::setData` and `data`. The values are ASCII bytes spelled in hex ("GLMS", "GLRS", "GLWT"), chosen to make a collision with KWin's own roles unlikely.

| Role | Value | Payload | Space | Cleared when |
| --- | --- | --- | --- | --- |
| `GlassMeshRole` | `0x474C4D53` | `QPolygonF`, 4 points per quad in the order TL, TR, BR, BL | Deformed positions, global logical pixels (frame origin already added) | Wobble ends or the window leaves Wobbly's hash |
| `GlassMeshRestRole` | `0x474C5253` | Same layout, index-matched to the mesh | Undeformed positions, frame-relative logical pixels (negative values are the shadow margin) | Same as above |
| `GlassWobbleTrackedRole` | `0x474C5754` | `true` | Set while the fork has the window in its `windows` hash | When the window is removed from that hash |

Rules that cost time to learn:

- Clear a role with `QVariant()`. Storing an empty `QPolygonF` leaves a valid variant, which made glass see `rv=1` with zero points.
- Glass accepts a mesh only if both polygons have equal size and the size is a multiple of 4. Otherwise it takes the normal rectangle path.
- `shouldBlur` keys on the tracked role, not on the mesh. A window being held without moving has no mesh but is still marked transformed, and keying on the mesh made its blur disappear.
- The mesh is global and the rest polygon is frame-relative on purpose. Glass reads the mesh from the frame being painted, and `w->pos()` may have moved since it was written.
- The mesh covers the expanded geometry (frame plus shadow), so its bounds extend past the frame at rest.

## Frame timing and chain order

Lower chain positions run first. Stock blur is 20, Wobbly Windows is 70. Glass must stay before Wobbly: after it, the render target is Wobbly's padded offscreen texture and the backdrop blit returns black.

One frame runs in this order:

1. **`prePaintWindow`.** The fork steps its physics, marks the window transformed and sets the tracked role. With the lag fix below, it also publishes the mesh here. Glass's own `prePaintWindow` calls down the chain first, so every `prePaintWindow` finishes before any `drawWindow`.
2. **`drawWindow`.** Glass (20) runs `blur()`: it blits the backdrop from the real screen, blurs it and draws the glass on the mesh. Then it calls down the chain. Wobbly (70) renders the window into its offscreen texture through `apply()` and composites it deformed.
3. **`postPaintScreen`.** Wobbly repaints its dirty region. Glass repaints the area it painted in mesh mode (`m_meshRepaint`), which removes leftover glass edges after the window leaves.

### The one-frame lag and its fix

Originally the fork published the mesh from `apply()`, which runs in step 2 after glass has already drawn. Glass therefore used the previous frame's mesh and trailed the window. The fix is to publish from `prePaintWindow`, after the physics step, using a helper `publishGlassMesh(w)` that rebuilds the same grid `apply()` builds. Physics state does not change between the two calls within a frame. Mark this as pending until it has been checked on real hardware.

### Facts about the render pipeline found while debugging

- `blitFromRenderTarget` depends on the framebuffer that is currently bound, not only on the target passed in. Inside a nested pass, wrapping the call in a push and pop of the screen framebuffer fixed it. At position 20 this is not needed.
- `OffscreenEffect` builds one quad from the expanded geometry, hands it to `apply()` as a local list and never stores it. `windowItem()->quads()` is empty for this reason.
- KWin loads plugins once. Changing a chain position or a binary needs a full re-login.

## Syncing glass with upstream

The glass diff is deliberately small, so merging upstream blur changes is mostly mechanical.

1. Merge or rebase onto the new upstream `blur.cpp` and `blur.h`.
2. Expect conflicts in three places: `shouldBlur`, the `backgroundRect` definition, and the vertex upload block in `blur()`. Re-apply the mesh logic on top of upstream's version; do not paste the old block over a changed one.
3. Run `grep -rn "GlassMesh\|GlassWobbleTracked\|meshMode" src/` and confirm every hit from the changes table is still present.
4. After shader edits, force the generated shaders to rebuild: `touch src/CMakeLists.txt`, then re-run `cmake` and `make`. The shaders are written with `file(WRITE ...)` at configure time and the `.glsl` sources are not tracked as dependencies, so a plain `make` leaves stale output and uniform locations of -1.
5. Install, then do a full log out and log in.
6. Test a static window first (it must look exactly as before), then a wobbling window.

Watch for API drift when upstream changes. `drawWindow` returns `bool` from KWin 6.8, and `Region`, `Rect` and `RenderView` types changed between releases; the existing `GLASS_KWIN_67` and `GLASS_KWIN_68` blocks handle that.

## Rebuilding the Wobbly fork after a KWin update

The fork compiles KWin internals, so it must match the installed KWin exactly. A mismatch fails to compile (for example `AnimationClock::tickMs` existed on master but not in 6.8) or, worse, builds and misbehaves. Rebuild after every Plasma upgrade.

1. Find the installed version with `pacman -Q kwin` (or your distro's equivalent).
2. Check out the matching tag in a KWin clone, never master.
3. Copy the stock files over the fork and redo the renames. This script is untested, so read it before running it:

```bash
#!/bin/sh
set -e
SRC="$1/src/plugins/wobblywindows"   # a KWin checkout at the right tag
DST="src/wobbly"
for f in main.cpp wobblywindows.cpp wobblywindows.h wobblywindows.kcfg wobblywindowsconfig.kcfgc; do
    cp "$SRC/$f" "$DST/$f"
done
sed -i 's/WobblyWindowsEffect/GlassWobblyEffect/g; s/WobblyWindowsConfig/GlassWobblyConfig/g' \
    "$DST"/*.cpp "$DST"/*.h "$DST"/wobblywindowsconfig.kcfgc
sed -i 's/metadata.json.stripped/metadata.json/' "$DST/main.cpp"
```

4. Do not overwrite the fork's `metadata.json` (no `X-KDE-ConfigModule`, no `Id`, `EnabledByDefault` false) or its `CMakeLists.txt`.
5. Re-apply the publish changes, which the script cannot do:
   - `#include "glassmesh.h"` in `wobblywindows.cpp`
   - declare and define `publishGlassMesh(EffectWindow *)` (declaration in the header)
   - in `prePaintWindow`: set `GlassWobbleTrackedRole`, call `publishGlassMesh`, and clear all three roles when the window is not in `windows`
   - in `apply()`: clear the mesh roles on the `!wobblying` early return
   - clear all three roles where the code calls `windows.remove(w)`
6. Rebuild, install, log out and in, then check that stock `wobblywindows` is off and `glass_wobbly` is on.

To make step 5 cheap, keep a pristine copy of each KWin tag's Wobbly files in git and generate a patch with `git diff` against it. A patch applies in one command and shows exactly where upstream moved.

## Known limitations

- **Only one Wobbly at a time.** With stock Wobbly and `glass_wobbly` both enabled, windows wobble twice. Keep stock off.
- **Mesh lag** until the `prePaintWindow` publish is in and verified (see the timing section).
- **Non-rectangular blur regions** are approximated by culling whole quads against the region's bounding rectangle. The rounded-corner mask and the glass pattern are exact.
- **Screen edges.** While wobbling, the background rectangle can extend off screen. Behaviour of the backdrop blit for out-of-range pixels has not been checked.
- **Settings.** The fork has no settings page of its own. The stock page edits the shared `Effect-wobblywindows` group, and whether a change reaches the fork without a re-login has not been verified.
- **Unused shader features.** Rim, Snell's-law refraction and most refraction settings do nothing, because the fork's `glass()` does not call them. That predates the mesh work.
- **Version coupling.** The fork breaks across KWin updates and must be rebuilt (see the rebuild section). A mismatched build can crash KWin, not only fail to compile.
- **Corner radius.** `originalCornerRadius` is cached on the first `blur()` call, which may explain Breeze's radius not being detected. Not investigated.

## Troubleshooting and diagnostics

| Symptom | Likely cause | Check |
| --- | --- | --- |
| A change has no effect | KWin loads plugins once | Log out and in. Put a `glassLog` line in the constructor to prove the new binary runs |
| Shader edit has no effect, uniform locations are -1 | Stale generated shaders | `touch src/CMakeLists.txt`, re-run `cmake`, confirm `generated/onscreen_rounded.frag` contains `meshMode` |
| Window background black while dragging | Glass runs after Wobbly, or the blit reads Wobbly's offscreen texture | Log `renderTarget.size()`; it should be the screen size, not the window plus 20 px |
| Glass stays a straight rectangle while wobbling | Mesh not accepted | Log `mv`, `rv`, polygon sizes and quad count in `blur()`. `rest=0` means the fork stored an empty rest polygon |
| Blur vanishes when a window is held without moving | `shouldBlur` keyed on the mesh | It must key on `GlassWobbleTrackedRole` |
| Glass edges flash after the window leaves | Last frame's glass is not repainted | Check `postPaintScreen()` and `m_meshRepaint` |
| Glass trails the window | Mesh published a frame late | Publish from `prePaintWindow`, not `apply()` |
| `AutoMoc` warning about `main.moc` | The factory macro hides the Q\_OBJECT from moc | Harmless; the stock `glass` target shows it too |
| Fork fails to compile after an update | API drift | Use the Wobbly files from the tag that matches the installed KWin |

### Logging when the journal shows nothing

Append to a file in the home directory. This is how every result in this project was read.

```cpp
#include <QDir>
#include <QFile>
#include <QTextStream>

static void glassLog(const QString &msg)
{
    QFile f(QDir::homePath() + QStringLiteral("/glass.log"));
    if (f.open(QIODevice::Append | QIODevice::Text)) {
        QTextStream(&f) << msg << "\n";
    }
}
```

Throttle it inside paint code (for example `static int n; if ((n++ % 30) == 0)`), because `blur()` runs every frame. Remove the log calls before shipping.

### A quick health check

1. `qdbus org.kde.KWin /Effects loadedEffects | grep -i "glass\|wobbl"` shows `glass` and `glass_wobbly`, and not `wobblywindows`.
2. A static window looks identical to upstream blur.
3. Dragging a window deforms the glass and the backdrop stays fixed to the screen.
4. Releasing the window leaves no glass edges behind.

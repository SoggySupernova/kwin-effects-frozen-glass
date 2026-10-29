#pragma once
#include <QPolygonF>
#include <QVariant>

namespace KWin
{
    // Window data role. Value is arbitrary, just unlikely to collide with KWin's own roles.
    static constexpr int GlassMeshRole = 0x474C4D53;
    // Payload: QPolygonF, 4 points per quad (TL, TR, BR, BL), frame-relative logical pixels.


    static constexpr int GlassMeshRestRole = 0x474C5253; // same layout as GlassMeshRole, undeformed
}

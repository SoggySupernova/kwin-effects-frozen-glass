/*
 SPDX-FileCopyrightText: 2021 Vlad Zahorodnii <vlad.zahorodnii@kde.org>

 SPDX-License-Identifier: GPL-2.0-or-later
 */

#include "wobblywindows.h"

namespace KWin
{

    KWIN_EFFECT_FACTORY_SUPPORTED(GlassWobblyEffect,
                                  "metadata.json",
                                  return GlassWobblyEffect::supported();)

} // namespace KWin

#include "main.moc"

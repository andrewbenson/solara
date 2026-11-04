// Copyright 2026 Solara. Apache-2.0.

#ifndef CHROME_BROWSER_SOLARA_PIP_AC_PIP_MAC_H_
#define CHROME_BROWSER_SOLARA_PIP_AC_PIP_MAC_H_

#include <optional>

#include "base/time/time.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/native_ui_types.h"

std::optional<gfx::Rect> LoadSolaraPictureInPictureBounds();
void SaveSolaraPictureInPictureBounds(const gfx::Rect& bounds);

void FadeOutSolaraPictureInPicture(gfx::NativeWindow window,
                                      base::TimeDelta duration);
void ResetSolaraPictureInPictureFade(gfx::NativeWindow window);
void ShowSolaraPictureInPictureInFullScreenSpaces(gfx::NativeWindow window);

#endif

// Copyright 2026 Solara. Apache-2.0.

#include "chrome/browser/solara/pip/ac_pip_controls.h"

#include <algorithm>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/strings/stringprintf.h"
#include "base/strings/utf_string_conversions.h"
#include "cc/paint/paint_flags.h"
#include "chrome/browser/ui/views/overlay/video_overlay_window_views.h"
#include "third_party/skia/include/core/SkPath.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "ui/base/cursor/cursor.h"
#include "ui/base/cursor/mojom/cursor_type.mojom-shared.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/models/image_model.h"
#include "ui/events/event.h"
#include "ui/gfx/animation/tween.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/font_list.h"
#include "ui/gfx/geometry/point_f.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/views/animation/ink_drop.h"

namespace {

void PaintCornerButtonBackground(const views::Button& button,
                                 gfx::Canvas* canvas) {
  const bool active = button.GetState() == views::Button::STATE_HOVERED ||
                      button.GetState() == views::Button::STATE_PRESSED;
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(SkColorSetA(SK_ColorWHITE, active ? 0x21 : 0x17));
  canvas->DrawRoundRect(gfx::RectF(button.GetLocalBounds()), 6, flags);
}

cc::PaintFlags GlyphFlags() {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(SK_ColorWHITE);
  flags.setStyle(cc::PaintFlags::kStroke_Style);
  flags.setStrokeWidth(1);
  return flags;
}

void TurnOffInkDrop(views::Button* button) {
  views::InkDrop::Get(button)->SetMode(views::InkDropHost::InkDropMode::OFF);
}

bool IsActive(const views::Button& button) {
  return button.GetState() == views::Button::STATE_HOVERED ||
         button.GetState() == views::Button::STATE_PRESSED;
}

std::u16string FormatTime(base::TimeDelta time) {
  const int64_t total = std::max<int64_t>(0, time.InSeconds());
  const int64_t hours = total / 3600;
  const int64_t minutes = (total % 3600) / 60;
  const int64_t seconds = total % 60;
  return base::UTF8ToUTF16(
      hours > 0 ? base::StringPrintf("%lld:%02lld:%02lld",
                                     static_cast<long long>(hours),
                                     static_cast<long long>(minutes),
                                     static_cast<long long>(seconds))
                : base::StringPrintf("%lld:%02lld",
                                     static_cast<long long>(minutes),
                                     static_cast<long long>(seconds)));
}

}

SolaraPipTier SolaraPipTierForWidth(int width) {
  if (width >= kSolaraPipLargeWidth) {
    return SolaraPipTier::kLarge;
  }
  return width >= kSolaraPipMediumWidth ? SolaraPipTier::kMedium
                                        : SolaraPipTier::kSmall;
}

int SolaraPipMargin(SolaraPipTier tier) {
  switch (tier) {
    case SolaraPipTier::kLarge:
      return kSolaraPipButtonMargin;
    case SolaraPipTier::kMedium:
      return 10;
    case SolaraPipTier::kSmall:
      return 8;
  }
}

SolaraBackToTabButton::SolaraBackToTabButton(PressedCallback callback)
    : OverlayWindowBackToTabButton(std::move(callback)) {
  SetSize(gfx::Size(kSolaraPipButtonSize, kSolaraPipButtonSize));
  TurnOffInkDrop(this);
}

SolaraBackToTabButton::~SolaraBackToTabButton() = default;

void SolaraBackToTabButton::Place(const gfx::Size& window_size, int margin) {
  views::View::SetPosition(gfx::Point(margin, margin));
}

void SolaraBackToTabButton::OnPaintBackground(gfx::Canvas* canvas) {
  PaintCornerButtonBackground(*this, canvas);
}

void SolaraBackToTabButton::PaintButtonContents(gfx::Canvas* canvas) {
  const cc::PaintFlags flags = GlyphFlags();
  const gfx::PointF corner(11, 11);
  canvas->DrawLine(gfx::PointF(10.5f, 11), gfx::PointF(18.3f, 11), flags);
  canvas->DrawLine(gfx::PointF(11, 10.5f), gfx::PointF(11, 18.3f), flags);
  canvas->DrawLine(corner, gfx::PointF(18.3f, 18.3f), flags);
}

BEGIN_METADATA(SolaraBackToTabButton)
END_METADATA

SolaraCloseButton::SolaraCloseButton(PressedCallback callback)
    : CloseImageButton(std::move(callback)) {
  SetSize(gfx::Size(kWidth, kSolaraPipButtonSize));
  TurnOffInkDrop(this);
}

SolaraCloseButton::~SolaraCloseButton() = default;

void SolaraCloseButton::Place(const gfx::Size& window_size, int margin) {
  views::View::SetPosition(
      gfx::Point(window_size.width() - kWidth - margin, margin));
}

void SolaraCloseButton::OnPaintBackground(gfx::Canvas* canvas) {
  PaintCornerButtonBackground(*this, canvas);
}

void SolaraCloseButton::PaintButtonContents(gfx::Canvas* canvas) {
  const cc::PaintFlags flags = GlyphFlags();
  canvas->DrawLine(gfx::PointF(9.85f, 9.85f), gfx::PointF(18.65f, 18.65f),
                   flags);
  canvas->DrawLine(gfx::PointF(18.65f, 9.85f), gfx::PointF(9.85f, 18.65f),
                   flags);
}

BEGIN_METADATA(SolaraCloseButton)
END_METADATA

SolaraMinimizeButton::SolaraMinimizeButton(PressedCallback callback)
    : OverlayWindowMinimizeButton(std::move(callback)) {
  SetSize(gfx::Size(kSolaraPipButtonSize, kSolaraPipButtonSize));
  TurnOffInkDrop(this);
}

SolaraMinimizeButton::~SolaraMinimizeButton() = default;

void SolaraMinimizeButton::Place(const gfx::Size& window_size, int margin) {
  views::View::SetPosition(
      gfx::Point(window_size.width() - margin - SolaraCloseButton::kWidth -
                     kSolaraPipButtonGap - kSolaraPipButtonSize,
                 margin));
}

void SolaraMinimizeButton::OnPaintBackground(gfx::Canvas* canvas) {
  PaintCornerButtonBackground(*this, canvas);
}

void SolaraMinimizeButton::PaintButtonContents(gfx::Canvas* canvas) {
  cc::PaintFlags flags = GlyphFlags();
  canvas->DrawRoundRect(gfx::RectF(8.5f, 9.5f, 11, 9), 1.5f, flags);
  cc::PaintFlags fill;
  fill.setAntiAlias(true);
  fill.setColor(SK_ColorWHITE);
  canvas->DrawRoundRect(gfx::RectF(9.5f, 14, 4.5f, 3.5f), 0.75f, fill);
  canvas->DrawLine(gfx::PointF(17.5f, 11.5f), gfx::PointF(14.8f, 14.2f), flags);
  canvas->DrawLine(gfx::PointF(14.8f, 12.2f), gfx::PointF(14.8f, 14.2f), flags);
  canvas->DrawLine(gfx::PointF(14.8f, 14.2f), gfx::PointF(16.8f, 14.2f), flags);
}

BEGIN_METADATA(SolaraMinimizeButton)
END_METADATA

SolaraMuteButton::SolaraMuteButton(PressedCallback callback)
    : views::Button(std::move(callback)) {
  SetSize(gfx::Size(kSolaraPipButtonSize, kSolaraPipButtonSize));
  TurnOffInkDrop(this);
  SetTooltipText(u"Mute");
}

SolaraMuteButton::~SolaraMuteButton() = default;

void SolaraMuteButton::SetMuted(bool muted) {
  if (muted_ == muted) {
    return;
  }
  muted_ = muted;
  SetTooltipText(muted ? u"Unmute" : u"Mute");
  SchedulePaint();
}

void SolaraMuteButton::OnPaintBackground(gfx::Canvas* canvas) {
  if (IsActive(*this)) {
    PaintCornerButtonBackground(*this, canvas);
  }
}

void SolaraMuteButton::PaintButtonContents(gfx::Canvas* canvas) {
  cc::PaintFlags fill;
  fill.setAntiAlias(true);
  fill.setColor(SK_ColorWHITE);
  canvas->DrawPath(SkPathBuilder()
                       .moveTo(7, 12)
                       .lineTo(9.5f, 12)
                       .lineTo(13, 9)
                       .lineTo(13, 19)
                       .lineTo(9.5f, 16)
                       .lineTo(7, 16)
                       .close()
                       .detach(),
                   fill);
  cc::PaintFlags flags = GlyphFlags();
  flags.setStrokeWidth(1.4f);
  flags.setStrokeCap(cc::PaintFlags::kRound_Cap);
  if (muted_) {
    canvas->DrawLine(gfx::PointF(16, 12), gfx::PointF(20, 16), flags);
    canvas->DrawLine(gfx::PointF(20, 12), gfx::PointF(16, 16), flags);
    return;
  }
  canvas->DrawPath(SkPathBuilder()
                       .arcTo(SkRect::MakeLTRB(11, 10.5f, 17, 17.5f), -50, 100,
                              true)
                       .detach(),
                   flags);
  canvas->DrawPath(SkPathBuilder()
                       .arcTo(SkRect::MakeLTRB(9.5f, 8, 20.5f, 20), -50, 100,
                              true)
                       .detach(),
                   flags);
}

BEGIN_METADATA(SolaraMuteButton)
END_METADATA

SolaraPlaybackButton::SolaraPlaybackButton(PressedCallback callback)
    : PlaybackImageButton(std::move(callback)) {
  TurnOffInkDrop(this);
  const ui::VectorIconModel replay = replay_image_.GetVectorIcon();
  replay_image_ = ui::ImageModel::FromVectorIcon(*replay.vector_icon(),
                                                 replay.color(), 36);
  UpdateImageAndText();
}

SolaraPlaybackButton::~SolaraPlaybackButton() = default;

void SolaraPlaybackButton::OnPaintBackground(gfx::Canvas* canvas) {}

void SolaraPlaybackButton::PaintButtonContents(gfx::Canvas* canvas) {
  if (playback_state_ == VideoOverlayWindowViews::kEndOfVideo) {
    views::ImageButton::PaintButtonContents(canvas);
    return;
  }
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(SK_ColorWHITE);
  const gfx::PointF center = gfx::RectF(GetLocalBounds()).CenterPoint();
  if (playback_state_ == VideoOverlayWindowViews::kPlaying) {
    for (float x : {center.x() - 12, center.x() + 5}) {
      canvas->DrawRoundRect(gfx::RectF(x, center.y() - 21, 7, 42), 3.5f,
                            flags);
    }
    return;
  }
  const float left = center.x() - 12, top = center.y() - 18.5f;
  const SkPath triangle = SkPathBuilder()
                              .moveTo(left, top)
                              .lineTo(left + 31, center.y())
                              .lineTo(left, top + 37)
                              .close()
                              .detach();
  canvas->DrawPath(triangle, flags);
  flags.setStyle(cc::PaintFlags::kStroke_Style);
  flags.setStrokeWidth(5);
  flags.setStrokeJoin(cc::PaintFlags::kRound_Join);
  canvas->DrawPath(triangle, flags);
}

BEGIN_METADATA(SolaraPlaybackButton)
END_METADATA

SolaraProgressBar::SolaraProgressBar(
    base::RepeatingCallback<void(double)> seek)
    : seek_(std::move(seek)) {}

SolaraProgressBar::~SolaraProgressBar() = default;

void SolaraProgressBar::SetMediaPosition(
    const media_session::MediaPosition& position) {
  position_ = position;
  if (!dragging_) {
    drag_fraction_.reset();
  }
  SchedulePaint();
  if (position_.playback_rate() == 0 || position_.duration().is_zero()) {
    timer_.Stop();
  } else if (!timer_.IsRunning()) {
    timer_.Start(FROM_HERE, base::Milliseconds(100),
                 base::BindRepeating(&SolaraProgressBar::RepaintIfDrawn,
                                     base::Unretained(this)));
  }
}

void SolaraProgressBar::Place(const gfx::Size& window_size,
                              SolaraPipTier tier,
                              int right_reserved) {
  const bool show_times = tier == SolaraPipTier::kLarge;
  const bool thin = tier == SolaraPipTier::kSmall;
  if (show_times != show_times_ || thin != thin_) {
    show_times_ = show_times;
    thin_ = thin;
    SchedulePaint();
  }
  const int margin = SolaraPipMargin(tier);
  const int bottom_margin = thin ? 6 : 9;
  const int inset = margin - kSlopX;
  const int height = static_cast<int>(thin ? kThinBarHeight : kBarHeight);
  SetBoundsRect(
      {inset, window_size.height() - bottom_margin - height - kSlopY,
       std::max(0, window_size.width() - 2 * inset - right_reserved),
       height + 2 * kSlopY});
}

gfx::RectF SolaraProgressBar::TrackBounds() const {
  const float height = thin_ ? kThinBarHeight : kBarHeight;
  const float times = show_times_ ? kTimeWidth : 0;
  return gfx::RectF(kSlopX + times, kSlopY,
                    std::max(0.0f, width() - 2.0f * kSlopX - 2 * times),
                    height);
}

void SolaraProgressBar::RepaintIfDrawn() {
  if (IsDrawn()) {
    SchedulePaint();
  }
}

void SolaraProgressBar::OnPaint(gfx::Canvas* canvas) {
  const base::TimeDelta duration = position_.duration();
  if (!duration.is_positive() || duration.is_max()) {
    return;
  }
  const gfx::RectF track = TrackBounds();
  const float radius = track.height() / 2;
  const double fraction = std::clamp(
      drag_fraction_.value_or(position_.GetPosition() / duration), 0.0, 1.0);
  if (show_times_) {
    const gfx::FontList font = gfx::FontList().DeriveWithSizeDelta(
        11 - gfx::FontList().GetFontSize());
    const base::TimeDelta elapsed = duration * fraction;
    const int text_top = static_cast<int>(track.CenterPoint().y()) - 8;
    canvas->DrawStringRectWithFlags(
        FormatTime(elapsed), font, SkColorSetA(SK_ColorWHITE, 0xE6),
        gfx::Rect(kSlopX, text_top, kTimeWidth - 6, 16), gfx::Canvas::TEXT_ALIGN_LEFT);
    canvas->DrawStringRectWithFlags(
        u"\u2212" + FormatTime(duration - elapsed), font,
        SkColorSetA(SK_ColorWHITE, 0xE6),
        gfx::Rect(width() - kSlopX - kTimeWidth + 6, text_top, kTimeWidth - 6,
                  16),
        gfx::Canvas::TEXT_ALIGN_RIGHT);
  }
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(SkColorSetA(SK_ColorWHITE, 0x44));
  canvas->DrawRoundRect(track, radius, flags);
  if (fraction <= 0) {
    return;
  }
  gfx::RectF played = track;
  played.set_width(std::max(track.height(),
                            static_cast<float>(track.width() * fraction)));
  flags.setColor(SK_ColorWHITE);
  canvas->DrawRoundRect(played, radius, flags);
}

bool SolaraProgressBar::OnMousePressed(const ui::MouseEvent& event) {
  if (!event.IsOnlyLeftMouseButton()) {
    return false;
  }
  dragging_ = true;
  drag_fraction_ = FractionAt(event.x());
  SchedulePaint();
  return true;
}

bool SolaraProgressBar::OnMouseDragged(const ui::MouseEvent& event) {
  drag_fraction_ = FractionAt(event.x());
  SchedulePaint();
  return true;
}

void SolaraProgressBar::OnMouseReleased(const ui::MouseEvent& event) {
  dragging_ = false;
  if (drag_fraction_) {
    seek_.Run(*drag_fraction_);
  }
}

void SolaraProgressBar::OnMouseCaptureLost() {
  dragging_ = false;
  drag_fraction_.reset();
  SchedulePaint();
}

ui::Cursor SolaraProgressBar::GetCursor(const ui::MouseEvent& event) {
  return ui::mojom::CursorType::kHand;
}

double SolaraProgressBar::FractionAt(int x) const {
  const gfx::RectF track = TrackBounds();
  return std::clamp((x - track.x()) / std::max(1.0f, track.width()), 0.0f,
                    1.0f);
}

BEGIN_METADATA(SolaraProgressBar)
END_METADATA

SolaraControlsFadeAnimation::SolaraControlsFadeAnimation(
    const std::vector<raw_ptr<views::View>>& controls,
    Type type)
    : OverlayControlsFadeAnimation(controls, type) {
  SetDuration(base::Milliseconds(120));
}

SolaraControlsFadeAnimation::~SolaraControlsFadeAnimation() = default;

void SolaraControlsFadeAnimation::AnimateToState(double state) {
  OverlayControlsFadeAnimation::AnimateToState(
      gfx::Tween::CalculateValue(gfx::Tween::EASE_IN_OUT, state));
}

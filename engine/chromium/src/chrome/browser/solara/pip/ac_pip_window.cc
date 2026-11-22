// Copyright 2026 Solara. Apache-2.0.

#include "chrome/browser/solara/pip/ac_pip_window.h"

#include <algorithm>
#include <cmath>
#include <optional>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/strings/string_util.h"
#include "chrome/browser/solara/pip/ac_pip_controls.h"
#include "chrome/browser/solara/pip/ac_pip_geometry.h"
#include "chrome/browser/solara/pip/ac_pip_mac.h"
#include "chrome/browser/picture_in_picture/picture_in_picture_widget_fade_animator.h"
#include "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
#include "chrome/browser/ui/color/chrome_color_id.h"
#include "chrome/browser/ui/views/overlay/constants.h"
#include "chrome/browser/ui/views/overlay/minimize_button.h"
#include "chrome/browser/ui/views/overlay/overlay_window_live_caption_button.h"
#include "chrome/browser/ui/views/overlay/simple_overlay_window_image_button.h"
#include "chrome/browser/ui/views/overlay/toggle_mute_button.h"
#include "cc/paint/paint_flags.h"
#include "cc/paint/paint_shader.h"
#include "content/public/browser/media_session.h"
#include "content/public/browser/video_picture_in_picture_window_controller.h"
#include "content/public/browser/web_contents.h"
#include "services/media_session/public/cpp/media_metadata.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/skia_conversions.h"
#include "ui/display/display.h"
#include "ui/display/screen.h"
#include "ui/gfx/font_list.h"
#include "ui/gfx/geometry/resize_utils.h"
#include "ui/gfx/text_constants.h"
#include "ui/views/animation/ink_drop.h"
#include "ui/views/background.h"
#include "ui/views/controls/image_view.h"
#include "ui/views/controls/label.h"

namespace {

constexpr base::TimeDelta kCloseFade = base::Milliseconds(100);
constexpr base::TimeDelta kHideFade = base::Milliseconds(70);
constexpr base::TimeDelta kIdleControlsHide = base::Milliseconds(1500);
constexpr int kSeekButtonSize = 40;
constexpr int kSeekButtonCenterOffset = 76;
constexpr int kMediumSeekButtonCenterOffset = 60;
constexpr float kTopScrimShare = 0.34f;
constexpr float kBottomScrimShare = 0.38f;

class SolaraEdgeScrim : public views::Background {
 public:
  explicit SolaraEdgeScrim(bool dark_at_top) : dark_at_top_(dark_at_top) {}
  SolaraEdgeScrim(const SolaraEdgeScrim&) = delete;
  SolaraEdgeScrim& operator=(const SolaraEdgeScrim&) = delete;
  ~SolaraEdgeScrim() override = default;

  void Paint(gfx::Canvas* canvas, views::View* view) const override {
    const gfx::Rect bounds = view->GetContentsBounds();
    const SkColor4f dark = SkColor4f::FromColor(
        SkColorSetA(SK_ColorBLACK, dark_at_top_ ? 0x8C : 0x99));
    const SkColor4f clear = SkColor4f::FromColor(SK_ColorTRANSPARENT);
    const SkColor4f colors[2] = {dark_at_top_ ? dark : clear,
                                 dark_at_top_ ? clear : dark};
    const SkPoint points[2] = {gfx::PointToSkPoint(bounds.top_center()),
                               gfx::PointToSkPoint(bounds.bottom_center())};
    cc::PaintFlags flags;
    flags.setShader(cc::PaintShader::MakeLinearGradient(points, colors, nullptr,
                                                        2, SkTileMode::kClamp));
    canvas->DrawRect(bounds, flags);
  }

 private:
  const bool dark_at_top_;
};

void StyleSeekButton(SimpleOverlayWindowImageButton* button) {
  views::InkDrop::Get(button)->SetMode(views::InkDropHost::InkDropMode::OFF);
  button->SetSize({kSeekButtonSize, kSeekButtonSize});
}

SolaraVideoOverlayWindow* g_shown_overlay = nullptr;

template <typename T, typename U>
T* ReplaceView(raw_ptr<U>& view, std::unique_ptr<T> replacement) {
  U* old_view = std::exchange(view, nullptr);
  views::View* parent = old_view->parent();
  const size_t index = parent->GetIndexOf(old_view).value();
  parent->RemoveChildViewT(old_view);
  return parent->AddChildViewAt(std::move(replacement), index);
}

}

SolaraVideoOverlayWindow::SolaraVideoOverlayWindow(
    content::VideoPictureInPictureWindowController* controller)
    : VideoOverlayWindowViews(controller), ac_hide_fade_(kHideFade) {
  hide_controls_timer_.Start(
      FROM_HERE, kIdleControlsHide,
      base::BindRepeating(
          &SolaraVideoOverlayWindow::HideIdleControlsUnlessPointerOnControl,
          base::Unretained(this)));
  hide_controls_timer_.Stop();
}

SolaraVideoOverlayWindow::~SolaraVideoOverlayWindow() {
  if (g_shown_overlay == this) {
    g_shown_overlay = nullptr;
  }
}

bool SkipSolaraPictureInPicture(bool forward) {
  return g_shown_overlay && g_shown_overlay->Skip(forward);
}

bool SolaraVideoOverlayWindow::Skip(bool forward) {
  if (is_live_ || !position_.duration().is_positive() ||
      position_.duration().is_max()) {
    return false;
  }
  if (forward) {
    Forward10Seconds();
  } else {
    Replay10Seconds();
  }
  UpdateControlsVisibility(true, true);
  hide_controls_timer_.Reset();
  return true;
}

void SolaraVideoOverlayWindow::SetUpViews() {
  VideoOverlayWindowViews::SetUpViews();

  controls_scrim_view_->SetBackground(nullptr);
  controls_top_scrim_view_->SetBackground(
      std::make_unique<SolaraEdgeScrim>(true));
  controls_bottom_scrim_view_->SetBackground(
      std::make_unique<SolaraEdgeScrim>(false));

  origin_->SetFontList(gfx::FontList().DeriveWithSizeDelta(
      13 - gfx::FontList().GetFontSize()));
  origin_->SetEnabledColor(kColorPipWindowForeground);
  origin_->SetHorizontalAlignment(gfx::ALIGN_LEFT);
  origin_->SetElideBehavior(gfx::ELIDE_TAIL);

  minimize_button_ = ReplaceView(
      minimize_button_,
      std::make_unique<SolaraMinimizeButton>(base::BindRepeating([] {
        PictureInPictureWindowManager::GetInstance()
            ->ExitPictureInPictureViaWindowUi(
                PictureInPictureWindowManager::UiBehavior::kCloseWindowOnly);
      })));
  ac_mute_button_ = controls_container_view_->AddChildView(
      std::make_unique<SolaraMuteButton>(base::BindRepeating(
          &SolaraVideoOverlayWindow::OnMuteButtonPressed,
          base::Unretained(this))));

  back_to_tab_button_ = ReplaceView(
      back_to_tab_button_,
      std::make_unique<SolaraBackToTabButton>(base::BindRepeating([] {
        PictureInPictureWindowManager::GetInstance()
            ->ExitPictureInPictureViaWindowUi(
                PictureInPictureWindowManager::UiBehavior::
                    kCloseWindowAndFocusOpener);
      })));
  close_controls_view_ = ReplaceView(
      close_controls_view_,
      std::make_unique<SolaraCloseButton>(base::BindRepeating(
          &SolaraVideoOverlayWindow::OnCloseButtonPressed,
          base::Unretained(this))));
  auto play_pause = std::make_unique<SolaraPlaybackButton>(
      base::BindRepeating(&VideoOverlayWindowViews::TogglePlayPause,
                          base::Unretained(this)));
  play_pause->SetSize({kCenterButtonSize, kCenterButtonSize});
  play_pause_controls_view_ =
      ReplaceView(play_pause_controls_view_, std::move(play_pause));
  StyleSeekButton(replay_10_seconds_button_.get());
  StyleSeekButton(forward_10_seconds_button_.get());

  ac_progress_bar_ = playback_controls_container_view_->AddChildViewAt(
      std::make_unique<SolaraProgressBar>(base::BindRepeating(
          &VideoOverlayWindowViews::SeekForProgressBarInteraction,
          base::Unretained(this))),
      playback_controls_container_view_->GetIndexOf(progress_view_).value() +
          1);
}

void SolaraVideoOverlayWindow::OnUpdateControlsBounds() {
  VideoOverlayWindowViews::OnUpdateControlsBounds();

  const gfx::Size size = GetBounds().size();
  const SolaraPipTier tier = SolaraPipTierForWidth(size.width());
  const int margin = SolaraPipMargin(tier);
  constexpr int kButton = kSolaraPipButtonSize;

  controls_top_scrim_view_->SetBoundsRect(
      {0, 0, size.width(), static_cast<int>(size.height() * kTopScrimShare)});
  const int bottom_scrim = static_cast<int>(size.height() * kBottomScrimShare);
  controls_bottom_scrim_view_->SetBoundsRect(
      {0, size.height() - bottom_scrim, size.width(), bottom_scrim});

  title_view_->SetBoundsRect({0, 0, size.width(), margin + kButton});
  favicon_view_->SetVisible(false);
  const int origin_x = margin + kButton + 10;
  const int origin_right = margin + SolaraCloseButton::kWidth +
                           kSolaraPipButtonGap + kButton + 10;
  origin_->SetBoundsRect({origin_x, margin - 1,
                          std::max(0, size.width() - origin_x - origin_right),
                          kButton});
  origin_->SetVisible(tier == SolaraPipTier::kLarge);

  static_cast<SolaraBackToTabButton*>(back_to_tab_button_.get())
      ->Place(size, margin);
  static_cast<SolaraCloseButton*>(close_controls_view_.get())
      ->Place(size, margin);
  static_cast<SolaraMinimizeButton*>(minimize_button_.get())
      ->Place(size, margin);
  minimize_button_->SetVisible(true);

  if (vc_controls_container_view_->GetVisible()) {
    ac_mute_button_->SetVisible(false);
    return;
  }

  const gfx::Point center(size.width() / 2, (size.height() + 1) / 2);
  play_pause_controls_view_->SetPosition(
      {center.x() - kCenterButtonSize / 2, center.y() - kCenterButtonSize / 2});
  const int seek_offset = tier == SolaraPipTier::kLarge
                              ? kSeekButtonCenterOffset
                              : kMediumSeekButtonCenterOffset;
  replay_10_seconds_button_->SetPosition(
      {center.x() - seek_offset - kSeekButtonSize / 2,
       center.y() - kSeekButtonSize / 2});
  forward_10_seconds_button_->SetPosition(
      {center.x() + seek_offset - kSeekButtonSize / 2,
       center.y() - kSeekButtonSize / 2});
  if (tier == SolaraPipTier::kSmall) {
    replay_10_seconds_button_->SetVisible(false);
    forward_10_seconds_button_->SetVisible(false);
  }
  const bool mute = tier != SolaraPipTier::kSmall;
  ac_mute_button_->SetVisible(mute);
  const int mute_reserved = mute ? kButton + 4 : 0;
  ac_progress_bar_->Place(size, tier, mute_reserved);
  ac_progress_bar_->SetVisible(!is_live_);
  if (mute) {
    const gfx::Rect bar = ac_progress_bar_->bounds();
    ac_mute_button_->SetPosition(
        {size.width() - margin - kButton + 4,
         bar.CenterPoint().y() - kButton / 2});
  }
  progress_view_->SetVisible(false);
  timestamp_->SetVisible(false);
  live_status_->SetVisible(false);
  live_caption_button_->SetVisible(false);
  if (toggle_mute_button_) {
    toggle_mute_button_->SetVisible(false);
  }
  previous_track_controls_view_->SetVisible(false);
  next_track_controls_view_->SetVisible(false);
}

void SolaraVideoOverlayWindow::UpdateControlsVisibility(
    bool is_visible,
    bool should_animate) {
  force_title_and_scrim_visible_ =
      !IsOverlayViewShown() && force_controls_visible_.value_or(is_visible);

  const OverlayControlsFadeAnimation* title_fade =
      title_and_top_scrim_fade_animation_.get();
  const OverlayControlsFadeAnimation* controls_fade = fade_animation_.get();
  VideoOverlayWindowViews::UpdateControlsVisibility(is_visible,
                                                    should_animate);

  if (title_and_top_scrim_fade_animation_ &&
      title_and_top_scrim_fade_animation_.get() != title_fade) {
    title_and_top_scrim_fade_animation_ =
        std::make_unique<SolaraControlsFadeAnimation>(
            std::vector<raw_ptr<views::View>>{title_view_,
                                              controls_top_scrim_view_},
            title_and_top_scrim_fade_animation_->type());
    title_and_top_scrim_fade_animation_->Start();
  }
  if (fade_animation_ && fade_animation_.get() != controls_fade) {
    fade_animation_ = std::make_unique<SolaraControlsFadeAnimation>(
        std::vector<raw_ptr<views::View>>{controls_container_view_,
                                          controls_scrim_view_,
                                          controls_bottom_scrim_view_},
        fade_animation_->type());
    fade_animation_->Start();
  }
}

void SolaraVideoOverlayWindow::SetPlaybackState(PlaybackState playback_state) {
  VideoOverlayWindowViews::SetPlaybackState(playback_state);
  UpdateTitle();
}

void SolaraVideoOverlayWindow::SetMediaMuted(bool muted) {
  VideoOverlayWindowViews::SetMediaMuted(muted);
  ac_mute_button_->SetMuted(muted);
}

void SolaraVideoOverlayWindow::SetSourceTitle(
    const std::u16string& source_title) {
  ac_source_title_ = source_title;
  VideoOverlayWindowViews::SetSourceTitle(source_title);
  UpdateTitle();
}

void SolaraVideoOverlayWindow::OnMuteButtonPressed() {
  const bool muted = !controller_->GetMuteStatus();
  controller_->RequestMute(muted);
  ac_mute_button_->SetMuted(muted);
}

void SolaraVideoOverlayWindow::UpdateTitle() {
  std::u16string raw;
  if (content::WebContents* contents = controller_->GetWebContents()) {
    raw = content::MediaSession::Get(contents)->GetMediaSessionMetadata().title;
    if (raw.empty()) {
      raw = contents->GetTitle();
    }
  }
  std::u16string title;
  base::TrimWhitespace(raw, base::TRIM_ALL, &title);
  std::u16string text = title;
  if (!ac_source_title_.empty()) {
    text = title.empty() ? ac_source_title_
                         : title + u" \u00B7 " + ac_source_title_;
  }
  if (origin_->GetText() != text) {
    origin_->SetText(text);
  }
}

gfx::Rect SolaraVideoOverlayWindow::GetProgressViewBounds() {
  return ac_progress_bar_->GetVisible() ? ac_progress_bar_->GetMirroredBounds()
                                        : gfx::Rect();
}

void SolaraVideoOverlayWindow::SetMediaPosition(
    const media_session::MediaPosition& position) {
  VideoOverlayWindowViews::SetMediaPosition(position);
  ac_progress_bar_->SetMediaPosition(position);
  UpdateTitle();
}

gfx::Size SolaraVideoOverlayWindow::GetMinimumSize() const {
  const gfx::Size baseline = VideoOverlayWindowViews::GetMinimumSize();
  if (natural_size_.IsEmpty() || IsOverlayViewShown()) {
    return baseline;
  }
  const ACPiPSize minimum = ACPiPNativeMinimumSize(
      static_cast<double>(natural_size_.width()) / natural_size_.height(),
      {static_cast<double>(baseline.width()),
       static_cast<double>(baseline.height())},
      {static_cast<double>(max_size_.width()),
       static_cast<double>(max_size_.height())});
  return gfx::Size(static_cast<int>(minimum.width),
                   static_cast<int>(minimum.height));
}

void SolaraVideoOverlayWindow::UpdateNaturalSize(const gfx::Size& natural_size) {
  natural_size_ = natural_size;
  OnSizeConstraintsChanged();
  VideoOverlayWindowViews::UpdateNaturalSize(natural_size);
}

gfx::Rect SolaraVideoOverlayWindow::CalculateAndUpdateWindowBounds() {
  std::optional<gfx::Rect> saved;
  if (!has_been_shown_) {
    saved = LoadSolaraPictureInPictureBounds();
  }
  if (saved) {
    const gfx::Rect work_area =
        display::Screen::Get()->GetDisplayMatching(*saved).work_area();
    UpdateMaxSize(work_area);
    gfx::Rect rect = *saved;
    if (!natural_size_.IsEmpty()) {
      const gfx::Size minimum = GetMinimumSize();
      const ACPiPSize size = ACPiPRestoredSize(
          {static_cast<double>(rect.width()), static_cast<double>(rect.height())},
          static_cast<double>(natural_size_.width()) / natural_size_.height(),
          {static_cast<double>(minimum.width()),
           static_cast<double>(minimum.height())},
          {static_cast<double>(max_size_.width()),
           static_cast<double>(max_size_.height())});
      const gfx::Point center = saved->CenterPoint();
      const bool left = center.x() < work_area.CenterPoint().x();
      const bool top = center.y() < work_area.CenterPoint().y();
      rect.set_size(gfx::Size(static_cast<int>(std::round(size.width)),
                             static_cast<int>(std::round(size.height))));
      rect.set_x(left ? saved->x() : saved->right() - rect.width());
      rect.set_y(top ? saved->y() : saved->bottom() - rect.height());
      const gfx::ResizeEdge edge =
          top ? (left ? gfx::ResizeEdge::kBottomRight
                      : gfx::ResizeEdge::kBottomLeft)
              : (left ? gfx::ResizeEdge::kTopRight
                      : gfx::ResizeEdge::kTopLeft);
      gfx::SizeRectToAspectRatio(
          edge,
          static_cast<float>(natural_size_.width()) / natural_size_.height(),
          GetMinimumSize(), max_size_, &rect);
      UpdateLayerBoundsWithLetterboxing(rect.size());
    } else {
      gfx::Size size = rect.size();
      size.SetToMin(max_size_);
      size.SetToMax(GetMinimumSize());
      rect.set_size(size);
    }
    rect.AdjustToFit(work_area);
    return rect;
  }
  return VideoOverlayWindowViews::CalculateAndUpdateWindowBounds();
}

void SolaraVideoOverlayWindow::ShowInactive() {
  g_shown_overlay = this;
  ac_hide_timer_.Stop();
  ResetSolaraPictureInPictureFade(GetNativeWindow());
  SetVisibilityChangedAnimationsEnabled(false);
  SetOpacity(1.0f);
  ShowSolaraPictureInPictureInFullScreenSpaces(GetNativeWindow());
  LetSolaraPictureInPictureMoveFreely(GetNativeWindow());
  views::Widget::ShowInactive();
  VideoOverlayWindowViews::ShowInactive();
  ac_mute_button_->SetMuted(controller_->GetMuteStatus());
  UpdateTitle();
  if (fade_animator_) {
    fade_animator_->CancelAndReset();
  }
  SetOpacity(1.0f);
  ShowSolaraPictureInPictureInFullScreenSpaces(GetNativeWindow());
}

void SolaraVideoOverlayWindow::Hide() {
  if (g_shown_overlay == this) {
    g_shown_overlay = nullptr;
  }
  RemoveOverlayViewIfExists();
  if (fade_animator_) {
    fade_animator_->CancelAndReset();
  }
  const base::TimeDelta fade = std::exchange(ac_hide_fade_, kHideFade);
  if (views::Widget::IsVisible() && fade.is_positive()) {
    if (!ac_hide_timer_.IsRunning()) {
      FadeOutSolaraPictureInPicture(GetNativeWindow(), fade);
      ac_hide_timer_.Start(
          FROM_HERE, fade,
          base::BindOnce(&SolaraVideoOverlayWindow::FinishHide,
                         base::Unretained(this)));
    }
  } else {
    ac_hide_timer_.Stop();
    views::Widget::Hide();
  }
  MaybeUnregisterFrameSinkHierarchy();
  PictureInPictureWindowManager::GetInstance()->OnPictureInPictureWindowHidden(
      this);
}

void SolaraVideoOverlayWindow::FinishHide() {
  views::Widget::Hide();
}

void SolaraVideoOverlayWindow::OnCloseButtonPressed() {
  ac_hide_fade_ = kCloseFade;
  PictureInPictureWindowManager::GetInstance()->ExitPictureInPictureViaWindowUi(
      PictureInPictureWindowManager::UiBehavior::kCloseWindowAndPauseVideo);
}

void SolaraVideoOverlayWindow::HideIdleControlsUnlessPointerOnControl() {
  const gfx::Point pointer = display::Screen::Get()->GetCursorScreenPoint() -
                             GetBounds().OffsetFromOrigin();
  const views::View* controls[] = {
      back_to_tab_button_.get(),        close_controls_view_.get(),
      minimize_button_.get(),           ac_mute_button_.get(),
      play_pause_controls_view_.get(),  replay_10_seconds_button_.get(),
      forward_10_seconds_button_.get(), ac_progress_bar_.get()};
  for (const views::View* control : controls) {
    if (control->GetVisible() &&
        control->GetMirroredBounds().Contains(pointer)) {
      return;
    }
  }
  UpdateControlsVisibility(false, true);
}

void SolaraVideoOverlayWindow::OnNativeWidgetDestroyed() {
  views::Widget::OnNativeWidgetDestroyed();
  const bool should_pause_video = false;
  controller_->OnWindowDestroyed(should_pause_video);
}

void SolaraVideoOverlayWindow::OnNativeWidgetMove() {
  VideoOverlayWindowViews::OnNativeWidgetMove();
  MaybeSaveBounds();
}

void SolaraVideoOverlayWindow::OnNativeWidgetSizeChanged(
    const gfx::Size& new_size) {
  VideoOverlayWindowViews::OnNativeWidgetSizeChanged(new_size);
  MaybeSaveBounds();
}

void SolaraVideoOverlayWindow::MaybeSaveBounds() {
  if (has_been_shown_ && !is_tucking_forced_ && views::Widget::IsVisible() &&
      !ac_hide_timer_.IsRunning()) {
    SaveSolaraPictureInPictureBounds(GetBounds());
  }
}

std::unique_ptr<VideoOverlayWindowViews> NewSolaraVideoOverlayWindow(
    content::VideoPictureInPictureWindowController* controller) {
  return std::make_unique<SolaraVideoOverlayWindow>(controller);
}

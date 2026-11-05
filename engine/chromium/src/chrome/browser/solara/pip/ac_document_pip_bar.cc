// Copyright 2026 Solara. Apache-2.0.

#include "chrome/browser/solara/pip/ac_document_pip_bar.h"

#include <algorithm>
#include <memory>
#include <utility>

#include "cc/paint/paint_flags.h"
#include "chrome/browser/solara/pip/ac_pip_controls.h"
#include "chrome/grit/generated_resources.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/web_contents.h"
#include "ui/base/cursor/cursor.h"
#include "ui/base/cursor/mojom/cursor_type.mojom-shared.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/models/image_model.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/gfx/image/image.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/animation/ink_drop.h"
#include "ui/views/background.h"
#include "ui/views/border.h"
#include "ui/views/controls/image_view.h"
#include "ui/views/controls/label.h"

namespace {

constexpr int kBarInset = (kSolaraDocumentPipBarHeight - kSolaraPipButtonSize) / 2;
constexpr int kBarClearance = 8;

}

SolaraDocumentPipTitle::SolaraDocumentPipTitle(PressedCallback callback,
                                               bool goes_back)
    : views::Button(std::move(callback)) {
  SetEnabled(goes_back);
  views::InkDrop::Get(this)->SetMode(views::InkDropHost::InkDropMode::OFF);
  favicon_ = AddChildView(std::make_unique<views::ImageView>());
  favicon_->SetImageSize(gfx::Size(kFaviconSize, kFaviconSize));
  favicon_->SetCanProcessEventsWithinSubtree(false);
  label_ = AddChildView(std::make_unique<views::Label>());
  label_->SetHorizontalAlignment(gfx::ALIGN_LEFT);
  label_->SetElideBehavior(gfx::ELIDE_TAIL);
  label_->SetAutoColorReadabilityEnabled(false);
  label_->SetSubpixelRenderingEnabled(false);
  label_->SetCanProcessEventsWithinSubtree(false);
}

SolaraDocumentPipTitle::~SolaraDocumentPipTitle() = default;

void SolaraDocumentPipTitle::Show(content::WebContents* opener,
                                  const std::u16string& origin,
                                  gfx::ElideBehavior origin_elide) {
  origin_ = origin;
  origin_elide_ = origin_elide;
  if (web_contents() != opener) {
    Observe(opener);
    favicon_observation_.Reset();
    if (opener) {
      if (auto* driver =
              favicon::ContentFaviconDriver::FromWebContents(opener)) {
        favicon_observation_.Observe(driver);
      }
    }
  }
  Refresh();
}

void SolaraDocumentPipTitle::SetForegroundColor(SkColor color) {
  label_->SetEnabledColor(color);
}

gfx::Size SolaraDocumentPipTitle::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  return gfx::Size(kPadding + kFaviconSize + kFaviconGap +
                       label_->GetPreferredSize().width() + kPadding,
                   kSolaraPipButtonSize);
}

void SolaraDocumentPipTitle::Layout(PassKey) {
  const int height = this->height();
  favicon_->SetBounds(kPadding, (height - kFaviconSize) / 2, kFaviconSize,
                      kFaviconSize);
  const int label_x = kPadding + kFaviconSize + kFaviconGap;
  label_->SetBounds(label_x, 0, std::max(0, width() - label_x - kPadding),
                    height);
  LayoutSuperclass<views::Button>(this);
}

ui::Cursor SolaraDocumentPipTitle::GetCursor(const ui::MouseEvent& event) {
  return GetEnabled() ? ui::Cursor(ui::mojom::CursorType::kHand)
                      : ui::Cursor();
}

void SolaraDocumentPipTitle::OnPaintBackground(gfx::Canvas* canvas) {
  if (!GetEnabled() || (GetState() != STATE_HOVERED &&
                        GetState() != STATE_PRESSED)) {
    return;
  }
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(SkColorSetA(SK_ColorWHITE,
                             GetState() == STATE_PRESSED ? 0x21 : 0x17));
  canvas->DrawRoundRect(gfx::RectF(GetLocalBounds()), 6, flags);
}

void SolaraDocumentPipTitle::TitleWasSet(content::NavigationEntry* entry) {
  Refresh();
}

void SolaraDocumentPipTitle::WebContentsDestroyed() {
  favicon_observation_.Reset();
  Observe(nullptr);
}

void SolaraDocumentPipTitle::OnFaviconUpdated(
    favicon::FaviconDriver* favicon_driver,
    NotificationIconType notification_icon_type,
    const GURL& icon_url,
    bool icon_url_changed,
    const gfx::Image& image) {
  Refresh();
}

void SolaraDocumentPipTitle::Refresh() {
  content::WebContents* opener = web_contents();
  content::NavigationEntry* entry =
      opener ? opener->GetController().GetLastCommittedEntry() : nullptr;
  const std::u16string page_title =
      entry ? entry->GetTitle() : std::u16string();
  const bool shows_page_title =
      kSolaraDocumentPipTitleSource ==
          SolaraDocumentPipTitleSource::kPageTitle &&
      !page_title.empty();
  label_->SetDirectionalityMode(
      shows_page_title ? gfx::DirectionalityMode::DIRECTIONALITY_FROM_TEXT
                       : gfx::DirectionalityMode::DIRECTIONALITY_AS_URL);
  label_->SetElideBehavior(shows_page_title ? gfx::ELIDE_TAIL : origin_elide_);
  label_->SetText(shows_page_title ? page_title : origin_);

  gfx::Image icon;
  if (opener) {
    if (auto* driver = favicon::ContentFaviconDriver::FromWebContents(opener)) {
      icon = driver->GetFavicon();
    }
  }
  favicon_->SetImage(icon.IsEmpty() ? ui::ImageModel()
                                    : ui::ImageModel::FromImage(icon));
  favicon_->SetVisible(!icon.IsEmpty());

  std::u16string description = origin_;
  if (GetEnabled()) {
    description = l10n_util::GetStringUTF16(
        IDS_PICTURE_IN_PICTURE_BACK_TO_TAB_CONTROL_TEXT);
    if (!origin_.empty()) {
      description += u" – " + origin_;
    }
  }
  SetTooltipText(description);
  GetViewAccessibility().SetName(shows_page_title ? page_title + u", " + description
                                                  : description);
  PreferredSizeChanged();
}

BEGIN_METADATA(SolaraDocumentPipTitle)
END_METADATA

void StyleSolaraDocumentPipBar(views::View* bar) {
  bar->SetBackground(views::CreateSolidBackground(kSolaraDocumentPipBarColor));
  bar->SetBorder(views::CreateSolidSidedBorder(gfx::Insets::TLBR(0, 0, 1, 0),
                                               kSolaraDocumentPipHairlineColor));
}

std::unique_ptr<views::Button> NewSolaraDocumentPipBackToTab(
    views::Button::PressedCallback callback) {
  return std::make_unique<SolaraBackToTabButton>(std::move(callback));
}

std::unique_ptr<CloseImageButton> NewSolaraDocumentPipClose(
    views::Button::PressedCallback callback) {
  return std::make_unique<SolaraCloseButton>(std::move(callback));
}

std::unique_ptr<views::Button> NewSolaraDocumentPipTitle(
    views::Button::PressedCallback callback) {
  const bool goes_back = static_cast<bool>(callback);
  return std::make_unique<SolaraDocumentPipTitle>(std::move(callback),
                                                  goes_back);
}

void ShowSolaraDocumentPipTitle(views::Button* title,
                                content::WebContents* opener,
                                const std::u16string& origin,
                                gfx::ElideBehavior origin_elide) {
  static_cast<SolaraDocumentPipTitle*>(title)->Show(opener, origin,
                                                    origin_elide);
}

void SetSolaraDocumentPipTitleColor(views::Button* title, SkColor color) {
  static_cast<SolaraDocumentPipTitle*>(title)->SetForegroundColor(color);
}

void LayoutSolaraDocumentPipBar(const gfx::Size& bar,
                                views::View* back_to_tab,
                                views::View* title,
                                views::View* indicators,
                                views::View* close) {
  int left = kBarInset;
  if (back_to_tab) {
    back_to_tab->SetBounds(kBarInset, kBarInset, kSolaraPipButtonSize,
                           kSolaraPipButtonSize);
    left = back_to_tab->bounds().right() + kBarClearance;
  }
  close->SetBounds(bar.width() - kBarInset - SolaraCloseButton::kWidth,
                   kBarInset, SolaraCloseButton::kWidth, kSolaraPipButtonSize);
  int right = close->x() - kBarClearance;
  if (indicators) {
    const gfx::Size size = indicators->GetPreferredSize();
    indicators->SetBounds(right - size.width(),
                          (bar.height() - size.height()) / 2,
                          close->bounds().right() - (right - size.width()),
                          size.height());
    if (size.width() > 0) {
      right = indicators->x() - kBarClearance;
    }
  }
  const int available = std::max(0, right - left);
  const int width = std::min(title->GetPreferredSize().width(), available);
  const int centered = (bar.width() - width) / 2;
  title->SetBounds(std::clamp(centered, left, std::max(left, right - width)),
                   kBarInset, width, kSolaraPipButtonSize);
}

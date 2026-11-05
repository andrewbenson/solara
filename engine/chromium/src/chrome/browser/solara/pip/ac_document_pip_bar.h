// Copyright 2026 Solara. Apache-2.0.

#ifndef CHROME_BROWSER_SOLARA_PIP_AC_DOCUMENT_PIP_BAR_H_
#define CHROME_BROWSER_SOLARA_PIP_AC_DOCUMENT_PIP_BAR_H_

#include <string>

#include "base/memory/raw_ptr.h"
#include "base/scoped_observation.h"
#include "components/favicon/core/favicon_driver.h"
#include "components/favicon/core/favicon_driver_observer.h"
#include "content/public/browser/web_contents_observer.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/gfx/text_constants.h"
#include "ui/views/controls/button/button.h"

namespace views {
class ImageView;
class Label;
}

enum class SolaraDocumentPipTitleSource { kPageTitle, kOrigin };

inline constexpr SolaraDocumentPipTitleSource kSolaraDocumentPipTitleSource =
    SolaraDocumentPipTitleSource::kPageTitle;
inline constexpr int kSolaraDocumentPipBarHeight = 40;
inline constexpr SkColor kSolaraDocumentPipBarColor =
    SkColorSetRGB(0x21, 0x21, 0x23);
inline constexpr SkColor kSolaraDocumentPipHairlineColor =
    SkColorSetA(SK_ColorWHITE, 0x33);

class SolaraDocumentPipTitle : public views::Button,
                               public content::WebContentsObserver,
                               public favicon::FaviconDriverObserver {
  METADATA_HEADER(SolaraDocumentPipTitle, views::Button)

 public:
  static constexpr int kPadding = 8;
  static constexpr int kFaviconSize = 16;
  static constexpr int kFaviconGap = 6;

  SolaraDocumentPipTitle(PressedCallback callback, bool goes_back);
  SolaraDocumentPipTitle(const SolaraDocumentPipTitle&) = delete;
  SolaraDocumentPipTitle& operator=(const SolaraDocumentPipTitle&) = delete;
  ~SolaraDocumentPipTitle() override;

  void Show(content::WebContents* opener,
            const std::u16string& origin,
            gfx::ElideBehavior origin_elide);
  void SetForegroundColor(SkColor color);

  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;
  ui::Cursor GetCursor(const ui::MouseEvent& event) override;

 protected:
  void OnPaintBackground(gfx::Canvas* canvas) override;

 private:
  void TitleWasSet(content::NavigationEntry* entry) override;
  void WebContentsDestroyed() override;
  void OnFaviconUpdated(favicon::FaviconDriver* favicon_driver,
                        NotificationIconType notification_icon_type,
                        const GURL& icon_url,
                        bool icon_url_changed,
                        const gfx::Image& image) override;
  void Refresh();

  std::u16string origin_;
  gfx::ElideBehavior origin_elide_ = gfx::ELIDE_HEAD;
  raw_ptr<views::ImageView> favicon_ = nullptr;
  raw_ptr<views::Label> label_ = nullptr;
  base::ScopedObservation<favicon::FaviconDriver,
                          favicon::FaviconDriverObserver>
      favicon_observation_{this};
};

#endif

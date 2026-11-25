#include "solara/core/ac_context_menu.h"

#import <AppKit/AppKit.h>
#include <os/log.h>

#include <optional>
#include <string>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback_helpers.h"
#include "base/memory/ref_counted.h"
#include "base/memory/weak_ptr.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "base/strings/sys_string_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "chrome/common/chrome_render_frame.mojom.h"
#include "components/lens/lens_metadata.mojom.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "third_party/blink/public/mojom/context_menu/context_menu.mojom.h"
#include "chrome/browser/renderer_context_menu/render_view_context_menu.h"
#include "chrome/browser/ui/browser_window/public/global_browser_collection.h"
#include "chrome/browser/ui/cocoa/renderer_context_menu/render_view_context_menu_mac_cocoa.h"
#include "chrome/browser/ui/tab_contents/chrome_web_contents_menu_helper.h"
#include "chrome/browser/ui/tab_contents/chrome_web_contents_view_delegate.h"
#include "components/tabs/public/tab_interface.h"
#include "content/public/browser/browser_context.h"
#include "ui/base/clipboard/clipboard.h"
#include "ui/base/clipboard/clipboard_format_type.h"
#include "ui/base/data_transfer_policy/data_transfer_endpoint.h"
#include "chrome/browser/ui/views/tab_contents/chrome_web_contents_view_delegate_views_mac.h"
#include "chrome/app/chrome_command_ids.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "solara/core/ac_browser.h"
#import "solara/core/solaracore_internal.h"
#include "ui/events/event_constants.h"
#include "ui/gfx/geometry/size.h"
#include "ui/base/page_transition_types.h"
#include "ui/base/window_open_disposition.h"

namespace solaracore {

namespace {

constexpr int kHostFirst = IDC_CONTENT_CONTEXT_CUSTOM_FIRST + 900;
constexpr int kHostLast = IDC_CONTENT_CONTEXT_CUSTOM_FIRST + 999;
constexpr int kShareImageMaxSide = 4096;
constexpr int kShareImageQuality = 90;
constexpr size_t kShareImageMaxBytes = 64 * 1024 * 1024;
constexpr base::TimeDelta kShareImageTimeout = base::Seconds(10);
constexpr NSTimeInterval kShareImageKeptFor = 60 * 60;

struct HostItem {
  std::string id;
  bool needs_image = false;
};

NSString* MediaTypeName(blink::mojom::ContextMenuDataMediaType type) {
  switch (type) {
    case blink::mojom::ContextMenuDataMediaType::kImage:
      return @"image";
    case blink::mojom::ContextMenuDataMediaType::kVideo:
      return @"video";
    case blink::mojom::ContextMenuDataMediaType::kAudio:
      return @"audio";
    case blink::mojom::ContextMenuDataMediaType::kCanvas:
      return @"canvas";
    case blink::mojom::ContextMenuDataMediaType::kPlugin:
      return @"plugin";
    default:
      return @"";
  }
}

std::optional<int> AnchorCommand(NSString* name) {
  if ([name isEqualToString:@"copy"]) return IDC_CONTENT_CONTEXT_COPY;
  if ([name isEqualToString:@"copyLink"]) return IDC_CONTENT_CONTEXT_COPYLINKLOCATION;
  if ([name isEqualToString:@"copyImage"]) return IDC_CONTENT_CONTEXT_COPYIMAGE;
  if ([name isEqualToString:@"copyImageLink"]) return IDC_CONTENT_CONTEXT_COPYIMAGELOCATION;
  if ([name isEqualToString:@"copyMediaLink"]) return IDC_CONTENT_CONTEXT_COPYAVLOCATION;
  if ([name isEqualToString:@"print"]) return IDC_PRINT;
  return std::nullopt;
}

NSString* ImageExtension(const std::string& mime_type) {
  if (mime_type == "image/png") return @"png";
  if (mime_type == "image/gif") return @"gif";
  if (mime_type == "image/webp") return @"webp";
  return @"jpg";
}

SolaraCoreTab* TabOf(content::WebContents* contents) {
  BrowserWindowInterface* browser =
      contents ? GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(contents)
               : nullptr;
  return browser && WindowHost::ForBrowser(browser)
             ? TabBridge::GetOrCreate(contents)->tab()
             : nil;
}

std::string WriteShareImage(std::vector<uint8_t> bytes, std::string mime_type) {
  @autoreleasepool {
    NSString* root = [NSTemporaryDirectory() stringByAppendingPathComponent:@"SolaraShare"];
    NSFileManager* files = NSFileManager.defaultManager;
    NSDate* stale = [NSDate dateWithTimeIntervalSinceNow:-kShareImageKeptFor];
    for (NSString* name in [files contentsOfDirectoryAtPath:root error:nil]) {
      NSString* old = [root stringByAppendingPathComponent:name];
      NSDate* made = [files attributesOfItemAtPath:old error:nil].fileModificationDate;
      if (made && [made compare:stale] == NSOrderedAscending) {
        [files removeItemAtPath:old error:nil];
      }
    }
    NSString* folder = [root stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    if (![files createDirectoryAtPath:folder
            withIntermediateDirectories:YES
                             attributes:@{NSFilePosixPermissions : @0700}
                                  error:nil]) {
      return std::string();
    }
    NSString* path = [[folder stringByAppendingPathComponent:@"Image"]
        stringByAppendingPathExtension:ImageExtension(mime_type)];
    NSData* data = [NSData dataWithBytes:bytes.data() length:bytes.size()];
    return [data writeToFile:path atomically:YES] ? base::SysNSStringToUTF8(path) : std::string();
  }
}

void RunHostCommand(content::WebContents* contents,
                    NSString* item_id,
                    NSDictionary<NSString*, id>* context) {
  SolaraCoreTab* tab = TabOf(contents);
  id<SolaraCoreTabDelegate> delegate = tab.delegate;
  if ([delegate respondsToSelector:@selector(tab:contextMenuCommand:context:)]) {
    [delegate tab:tab contextMenuCommand:item_id context:context];
  } else if ([delegate respondsToSelector:@selector(tab:contextMenuCommand:text:modifiers:)]) {
    [delegate tab:tab
        contextMenuCommand:item_id
                      text:context[@"selection"]
                 modifiers:context[@"modifiers"]];
  }
}

class ShareImageRequest : public base::RefCounted<ShareImageRequest> {
 public:
  ShareImageRequest(base::WeakPtr<content::WebContents> contents,
                    NSString* item_id,
                    NSMutableDictionary<NSString*, id>* context)
      : contents_(contents), item_id_(item_id), context_(context) {}

  void Start(content::RenderFrameHost* frame) {
    frame->GetRemoteAssociatedInterfaces()->GetInterface(&remote_);
    remote_.set_disconnect_handler(base::BindOnce(&ShareImageRequest::GaveUp, base::WrapRefCounted(this)));
    static const bool stall = getenv("SOLARA_BACKGROUND") && getenv("SOLARA_TEST_SHARE_IMAGE_STALL");
    if (!stall) {
      remote_->RequestImageForContextNode(
          0, gfx::Size(kShareImageMaxSide, kShareImageMaxSide),
          chrome::mojom::ImageFormat::ORIGINAL, kShareImageQuality,
          base::BindOnce(&ShareImageRequest::Received, base::WrapRefCounted(this)));
    }
    content::GetUIThreadTaskRunner({})->PostDelayedTask(
        FROM_HERE, base::BindOnce(&ShareImageRequest::GaveUp, base::WrapRefCounted(this)), kShareImageTimeout);
  }

 private:
  friend class base::RefCounted<ShareImageRequest>;
  enum class State { kWaiting, kWriting, kDone };
  ~ShareImageRequest() = default;

  void GaveUp() { Done(std::string()); }

  void Received(const std::vector<uint8_t>& bytes,
                const gfx::Size& original_size,
                const gfx::Size& downscaled_size,
                const std::string& mime_type,
                std::vector<lens::mojom::LatencyLogPtr>) {
    if (state_ != State::kWaiting) {
      return;
    }
    remote_.reset();
    if (bytes.empty() || bytes.size() > kShareImageMaxBytes) {
      Done(std::string());
      return;
    }
    state_ = State::kWriting;
    context_[@"imageWidth"] = @(downscaled_size.width());
    context_[@"imageHeight"] = @(downscaled_size.height());
    base::ThreadPool::PostTaskAndReplyWithResult(
        FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
        base::BindOnce(&WriteShareImage, bytes, mime_type),
        base::BindOnce(&ShareImageRequest::Done, base::WrapRefCounted(this)));
  }

  void Done(std::string path) {
    if (state_ == State::kDone) {
      return;
    }
    state_ = State::kDone;
    remote_.reset();
    if (!path.empty()) {
      context_[@"imagePath"] = base::SysUTF8ToNSString(path);
    }
    if (contents_) {
      RunHostCommand(contents_.get(), item_id_, context_);
    }
  }

  base::WeakPtr<content::WebContents> contents_;
  NSString* item_id_;
  NSMutableDictionary<NSString*, id>* context_;
  mojo::AssociatedRemote<chrome::mojom::ChromeRenderFrame> remote_;
  State state_ = State::kWaiting;
};

NSArray* DescribeMenu(ui::MenuModel* model) {
  NSMutableArray* items = [NSMutableArray array];
  for (size_t i = 0; model && i < model->GetItemCount(); ++i) {
    const ui::MenuModel::ItemType type = model->GetTypeAt(i);
    NSMutableDictionary* item = [@{
      @"id" : @(model->GetCommandIdAt(i)),
      @"label" : base::SysUTF16ToNSString(model->GetLabelAt(i)),
      @"enabled" : @(model->IsEnabledAt(i)),
      @"visible" : @(model->IsVisibleAt(i)),
      @"separator" : @(type == ui::MenuModel::TYPE_SEPARATOR),
      @"type" : @(static_cast<int>(type)),
    } mutableCopy];
    if (type == ui::MenuModel::TYPE_SUBMENU ||
        type == ui::MenuModel::TYPE_ACTIONABLE_SUBMENU) {
      item[@"submenu"] = DescribeMenu(model->GetSubmenuModelAt(i));
    }
    [items addObject:item];
  }
  return items;
}

bool FindPicked(ui::MenuModel* model,
                NSArray* path,
                int command,
                ui::MenuModel** owner,
                size_t* index) {
  if (path) {
    for (NSUInteger depth = 0; model && depth < path.count; ++depth) {
      NSNumber* step = [path[depth] isKindOfClass:NSNumber.class] ? path[depth] : nil;
      if (!step || step.longLongValue < 0 ||
          static_cast<size_t>(step.longLongValue) >= model->GetItemCount()) {
        return false;
      }
      const size_t i = static_cast<size_t>(step.longLongValue);
      if (depth + 1 == path.count) {
        if (model->GetCommandIdAt(i) != command) {
          return false;
        }
        *owner = model;
        *index = i;
        return true;
      }
      model = model->GetSubmenuModelAt(i);
    }
    return false;
  }
  for (size_t i = 0; model && i < model->GetItemCount(); ++i) {
    if (model->GetCommandIdAt(i) == command) {
      *owner = model;
      *index = i;
      return true;
    }
    if (FindPicked(model->GetSubmenuModelAt(i), nil, command, owner, index)) {
      return true;
    }
  }
  return false;
}

class ACContextMenu : public RenderViewContextMenuMacCocoa {
 public:
  using RenderViewContextMenuMacCocoa::RenderViewContextMenuMacCocoa;

  void Show() override {
    if (!ShowThroughHost()) {
      RenderViewContextMenuMacCocoa::Show();
    }
  }

  void RemoveViewlessItems() {
    for (int command : {IDC_CONTENT_CONTEXT_OPEN_IN_READING_MODE,
                        IDC_CONTENT_CONTEXT_LISTEN_TO_THIS_PAGE,
                        IDC_CONTENT_CONTEXT_GENERATE_QR_CODE, IDC_SEND_TAB_TO_SELF,
                        IDC_CONTENT_CONTEXT_SEARCHLENSFORIMAGE,
                        IDC_CONTENT_CONTEXT_SEARCHLENSFORVIDEOFRAME,
                        IDC_CONTENT_CONTEXT_LENS_REGION_SEARCH}) {
      while (std::optional<size_t> index = menu_model_.GetIndexOfCommandId(command)) {
        menu_model_.RemoveItemAt(*index);
      }
    }
    const auto separator = [this](size_t i) {
      return menu_model_.GetTypeAt(i) == ui::MenuModel::TYPE_SEPARATOR;
    };
    for (size_t i = menu_model_.GetItemCount(); i-- > 0;) {
      const size_t count = menu_model_.GetItemCount();
      if (i < count && separator(i) &&
          (i == 0 || i + 1 == count || separator(i + 1))) {
        menu_model_.RemoveItemAt(i);
      }
    }
  }

  NSDictionary<NSString*, id>* Context() const {
    content::WebContents* contents = source_web_contents_;
    return @{
      @"selection" : base::SysUTF16ToNSString(params().selection_text),
      @"link" : base::SysUTF8ToNSString(params().link_url.spec()),
      @"source" : base::SysUTF8ToNSString(params().src_url.spec()),
      @"mediaType" : MediaTypeName(params().media_type),
      @"hasImage" : @(params().has_image_contents),
      @"page" : base::SysUTF8ToNSString(params().page_url.spec()),
      @"frame" : base::SysUTF8ToNSString(params().frame_url.spec()),
      @"title" : contents ? base::SysUTF16ToNSString(contents->GetTitle()) : @"",
      @"editable" : @(params().is_editable),
      @"x" : @(params().x),
      @"y" : @(params().y),
    };
  }

  void AddHostItems() {
    SolaraCoreTab* tab = TabOf(source_web_contents_);
    id<SolaraCoreTabDelegate> delegate = tab.delegate;
    NSArray<NSDictionary*>* items = nil;
    if ([delegate respondsToSelector:@selector(tab:contextMenuItemsForContext:)]) {
      items = [delegate tab:tab contextMenuItemsForContext:Context()];
    } else {
      const std::u16string& selection = params().selection_text;
      if (selection.empty() || params().is_editable ||
          ![delegate respondsToSelector:@selector(tab:contextMenuItemsForSelection:)]) {
        return;
      }
      items = [delegate tab:tab
          contextMenuItemsForSelection:base::SysUTF16ToNSString(selection)];
    }
    std::optional<size_t> copy =
        menu_model_.GetIndexOfCommandId(IDC_CONTENT_CONTEXT_COPY);
    size_t at = copy ? *copy + 1 : menu_model_.GetItemCount();
    for (NSDictionary* item in items) {
      if (![item isKindOfClass:NSDictionary.class]) {
        continue;
      }
      NSString* item_id = [item[@"id"] isKindOfClass:NSString.class] ? item[@"id"] : nil;
      NSString* title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : nil;
      const int command = kHostFirst + static_cast<int>(host_items_.size());
      if (!item_id || !title || command > kHostLast) {
        continue;
      }
      host_items_.push_back({base::SysNSStringToUTF8(item_id), [item[@"needs"] isEqual:@"image"]});
      NSArray* after = [item[@"after"] isKindOfClass:NSArray.class] ? item[@"after"] : nil;
      if (after) {
        std::optional<size_t> anchor;
        for (id name in after) {
          std::optional<int> anchor_command =
              [name isKindOfClass:NSString.class] ? AnchorCommand(name) : std::nullopt;
          if (anchor_command && (anchor = menu_model_.GetIndexOfCommandId(*anchor_command))) {
            break;
          }
        }
        const size_t place = anchor ? *anchor + 1 : menu_model_.GetItemCount();
        menu_model_.InsertItemAt(place, command, base::SysNSStringToUTF16(title));
        if (place <= at) {
          ++at;
        }
        continue;
      }
      size_t place = at;
      bool replaced = false;
      if ([item[@"replaces"] isEqual:@"search"]) {
        for (int chrome_id : {IDC_CONTENT_CONTEXT_SEARCHWEBFOR,
                              IDC_CONTENT_CONTEXT_SEARCHWEBFORNEWTAB}) {
          if (std::optional<size_t> index = menu_model_.GetIndexOfCommandId(chrome_id)) {
            if (!replaced) {
              place = *index;
            }
            menu_model_.RemoveItemAt(*index);
            replaced = true;
            if (*index < at) {
              --at;
            }
          }
        }
      }
      menu_model_.InsertItemAt(place, command, base::SysNSStringToUTF16(title));
      if (!replaced || place < at) {
        ++at;
      }
    }
  }

 protected:
  bool IsCommandIdEnabled(int command_id) const override {
    if (command_id >= kHostFirst && command_id <= kHostLast) {
      return true;
    }
    return RenderViewContextMenuMacCocoa::IsCommandIdEnabled(command_id);
  }

  void ExecuteCommand(int command_id, int event_flags) override {
    if (command_id == IDC_CONTENT_CONTEXT_OPENLINKSPLITVIEW && TabOf(source_web_contents_)) {
      OpenURLWithExtraHeaders(params_.link_url, params_.frame_url, params_.frame_origin,
                              WindowOpenDisposition::NEW_SPLIT_VIEW, ui::PAGE_TRANSITION_LINK,
                              std::string(), true, base::DoNothing());
      return;
    }
    const size_t index = command_id - kHostFirst;
    if (command_id < kHostFirst || command_id > kHostLast ||
        index >= host_items_.size()) {
      RenderViewContextMenuMacCocoa::ExecuteCommand(command_id, event_flags);
      return;
    }
    const HostItem& item = host_items_[index];
    NSMutableDictionary<NSString*, id>* context = [Context() mutableCopy];
    context[@"modifiers"] = @{
      @"metaKey" : @((event_flags & ui::EF_COMMAND_DOWN) != 0),
      @"shiftKey" : @((event_flags & ui::EF_SHIFT_DOWN) != 0),
      @"altKey" : @((event_flags & ui::EF_ALT_DOWN) != 0),
    };
    NSString* item_id = base::SysUTF8ToNSString(item.id);
    if (item.needs_image) {
      RequestImageThenRun(item_id, context);
      return;
    }
    RunHostCommand(source_web_contents_, item_id, context);
  }

  void RequestImageThenRun(NSString* item_id, NSMutableDictionary<NSString*, id>* context) {
    content::RenderFrameHost* frame = GetRenderFrameHost();
    if (!frame || !source_web_contents_) {
      RunHostCommand(source_web_contents_, item_id, context);
      return;
    }
    base::MakeRefCounted<ShareImageRequest>(source_web_contents_->GetWeakPtr(), item_id, context)
        ->Start(frame);
  }

 private:
  bool ShowThroughHost() {
    static const bool to_host =
        getenv("SOLARA_BACKGROUND") || getenv("SOLARA_CONTEXT_MENU_LOG");
    if (!to_host) {
      return false;
    }
    SolaraCoreTab* tab = TabOf(GetWebContents());
    id<SolaraCoreTabDelegate> delegate = tab.delegate;
    const bool runs = [delegate respondsToSelector:@selector(tab:runContextMenu:)];
    if (!runs && ![delegate respondsToSelector:@selector(tab:didShowContextMenu:)]) {
      return false;
    }
    base::WeakPtr<ACContextMenu> weak = weak_factory_.GetWeakPtr();
    ui::SimpleMenuModel* model = &menu_model_;
    NSNumber* command = nil;
    NSNumber* flags = nil;
    NSArray* path = nil;
    if (runs) {
      NSDictionary* picked = [delegate tab:tab
                            runContextMenu:@{
                              @"items" : DescribeMenu(model),
                              @"url" : base::SysUTF8ToNSString(params().page_url.spec()),
                              @"link" : base::SysUTF8ToNSString(params().link_url.spec()),
                            }];
      command = [picked[@"command"] isKindOfClass:NSNumber.class] ? picked[@"command"] : nil;
      flags = [picked[@"flags"] isKindOfClass:NSNumber.class] ? picked[@"flags"] : nil;
      path = [picked[@"path"] isKindOfClass:NSArray.class] ? picked[@"path"] : nil;
    } else {
      [delegate tab:tab didShowContextMenu:DescribeMenu(model)];
    }
    if (!weak) {
      return true;
    }
    ui::MenuModel* owner = nullptr;
    size_t index = 0;
    const bool found = command && FindPicked(model, path, command.intValue, &owner, &index);
    if (command && getenv("SOLARA_CONTEXT_MENU_LOG")) {
      const std::string where =
          !found            ? "not found"
          : owner == model ? "top level"
                           : "submenu [" + base::UTF16ToUTF8(owner->GetLabelAt(0)) + ", …]";
      os_log(OS_LOG_DEFAULT, "[solaracore-menu] pick %d: %{public}s", command.intValue,
             where.c_str());
    }
    if (found && owner->IsEnabledAt(index)) {
      owner->ActivatedAt(index, flags.intValue);
    }
    if (weak) {
      MenuClosed(model);
    }
    return true;
  }

  std::vector<HostItem> host_items_;
  base::WeakPtrFactory<ACContextMenu> weak_factory_{this};
};

class ACViewDelegate : public ChromeWebContentsViewDelegateViewsMac {
 public:
  explicit ACViewDelegate(content::WebContents* contents)
      : ChromeWebContentsViewDelegateViewsMac(contents), contents_(contents) {}

  std::unique_ptr<RenderViewContextMenuBase> BuildMenu(
      content::RenderFrameHost& render_frame_host,
      const content::ContextMenuParams& params) override {
    content::RenderWidgetHostView* view = contents_->GetRenderWidgetHostView();
    if (!TabOf(contents_) || !view) {
      return ChromeWebContentsViewDelegateViewsMac::BuildMenu(render_frame_host,
                                                              params);
    }
    auto menu = std::make_unique<ACContextMenu>(
        render_frame_host, params, paste_enabled_, paste_and_match_style_enabled_,
        view->GetNativeView().GetNativeNSView());
    menu->Init();
    menu->RemoveViewlessItems();
    menu->AddHostItems();
    return menu;
  }

  void BuildMenuAsync(
      content::RenderFrameHost& render_frame_host,
      const content::ContextMenuParams& params,
      base::OnceCallback<void(std::unique_ptr<RenderViewContextMenuBase>)> callback)
      override {
    if (!TabOf(contents_)) {
      ChromeWebContentsViewDelegateViewsMac::BuildMenuAsync(render_frame_host, params,
                                                            std::move(callback));
      return;
    }
    tabs::TabInterface* tab_interface = tabs::TabInterface::MaybeGetFromContents(contents_);
    if (tab_interface && !tab_interface->IsActivated()) {
      contents_->Focus();
    }
    std::optional<ui::DataTransferEndpoint> data_dst;
    if (params.page_url.is_valid()) {
      data_dst.emplace(params.page_url,
                       ui::DataTransferEndpointOptions{
                           .notify_if_restricted = false,
                           .off_the_record =
                               contents_->GetBrowserContext()->IsOffTheRecord(),
                       });
    }
    ui::Clipboard::GetForCurrentThread()->ReadAvailableTypes(
        ui::ClipboardBuffer::kCopyPaste, data_dst,
        base::BindOnce(&ACViewDelegate::OnReadAvailableTypes, weak_factory_.GetWeakPtr(),
                       render_frame_host.GetGlobalId(),
                       AddContextMenuParamsPropertiesFromPreferences(contents_, params),
                       data_dst, std::move(callback)));
  }

 private:
  void OnReadAvailableTypes(
      content::GlobalRenderFrameHostId frame_id,
      const content::ContextMenuParams& params,
      std::optional<ui::DataTransferEndpoint> data_dst,
      base::OnceCallback<void(std::unique_ptr<RenderViewContextMenuBase>)> callback,
      std::vector<std::u16string> types) {
    paste_enabled_ = !types.empty();
    ui::Clipboard::GetForCurrentThread()->GetAllAvailableFormats(
        ui::ClipboardBuffer::kCopyPaste, std::move(data_dst),
        base::BindOnce(&ACViewDelegate::OnGetAllAvailableFormats,
                       weak_factory_.GetWeakPtr(), frame_id, params, std::move(callback)));
  }

  void OnGetAllAvailableFormats(
      content::GlobalRenderFrameHostId frame_id,
      const content::ContextMenuParams& params,
      base::OnceCallback<void(std::unique_ptr<RenderViewContextMenuBase>)> callback,
      base::flat_set<ui::ClipboardFormatType> formats) {
    paste_and_match_style_enabled_ =
        formats.contains(ui::ClipboardFormatType::PlainTextType());
    content::RenderFrameHost* frame = content::RenderFrameHost::FromID(frame_id);
    if (!frame) {
      std::move(callback).Run(nullptr);
      return;
    }
    std::move(callback).Run(BuildMenu(*frame, params));
  }

  raw_ptr<content::WebContents> contents_;
  bool paste_enabled_ = false;
  bool paste_and_match_style_enabled_ = false;
  base::WeakPtrFactory<ACViewDelegate> weak_factory_{this};
};

}

std::unique_ptr<content::WebContentsViewDelegate> CreateViewDelegate(
    content::WebContents* contents) {
  return std::make_unique<ACViewDelegate>(contents);
}

}

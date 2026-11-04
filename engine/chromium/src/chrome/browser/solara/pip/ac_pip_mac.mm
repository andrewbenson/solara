// Copyright 2026 Solara. Apache-2.0.

#include "chrome/browser/solara/pip/ac_pip_mac.h"

#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#include "base/apple/foundation_util.h"
#include "base/files/file_path.h"
#include "base/path_service.h"
#include "chrome/common/chrome_paths.h"
#include "components/remote_cocoa/app_shim/native_widget_mac_nswindow.h"

namespace {

NSURL* BoundsFile() {
  base::FilePath dir;
  if (!base::PathService::Get(chrome::DIR_USER_DATA, &dir)) {
    return nil;
  }
  return base::apple::FilePathToNSURL(
      dir.Append("SolaraPictureInPicture.plist"));
}

NSString* const kFadeKey = @"solaraFadeOut";

CALayer* FadeLayer(NSWindow* window) {
  return window.contentView.superview.layer ?: window.contentView.layer;
}

}

std::optional<gfx::Rect> LoadSolaraPictureInPictureBounds() {
  NSURL* file = BoundsFile();
  NSArray* values = file ? [NSArray arrayWithContentsOfURL:file] : nil;
  if (values.count != 4) {
    return std::nullopt;
  }
  for (id value in values) {
    if (![value isKindOfClass:NSNumber.class]) {
      return std::nullopt;
    }
  }
  gfx::Rect bounds([values[0] intValue], [values[1] intValue],
                   [values[2] intValue], [values[3] intValue]);
  if (bounds.IsEmpty()) {
    return std::nullopt;
  }
  return bounds;
}

void SaveSolaraPictureInPictureBounds(const gfx::Rect& bounds) {
  static gfx::Rect last;
  NSURL* file = BoundsFile();
  if (!file || bounds.IsEmpty() || bounds == last) {
    return;
  }
  last = bounds;
  [@[ @(bounds.x()), @(bounds.y()), @(bounds.width()), @(bounds.height()) ]
      writeToURL:file
           error:nil];
}

void FadeOutSolaraPictureInPicture(gfx::NativeWindow window,
                                      base::TimeDelta duration) {
  NSWindow* ns_window = window.GetNativeNSWindow();
  CALayer* layer = FadeLayer(ns_window);
  if (!layer) {
    return;
  }
  CABasicAnimation* fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
  fade.fromValue = @1;
  fade.toValue = @0;
  fade.duration = duration.InSecondsF();
  fade.timingFunction =
      [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  layer.opacity = 0;
  [layer addAnimation:fade forKey:kFadeKey];
  [CATransaction commit];
  [CATransaction flush];
  ns_window.hasShadow = NO;
}

void ResetSolaraPictureInPictureFade(gfx::NativeWindow window) {
  NSWindow* ns_window = window.GetNativeNSWindow();
  CALayer* layer = FadeLayer(ns_window);
  if (!layer || layer.opacity == 1) {
    return;
  }
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  [layer removeAnimationForKey:kFadeKey];
  layer.opacity = 1;
  [CATransaction commit];
  ns_window.hasShadow = YES;
}

void ShowSolaraPictureInPictureInFullScreenSpaces(gfx::NativeWindow native) {
  NSWindow* window = native.GetNativeNSWindow();
  if (!window) {
    return;
  }
  NSWindowCollectionBehavior behavior = window.collectionBehavior;
  behavior &= ~(NSWindowCollectionBehaviorPrimary |
                NSWindowCollectionBehaviorFullScreenPrimary);
  behavior |= NSWindowCollectionBehaviorFullScreenAuxiliary;
  if (behavior != window.collectionBehavior) {
    window.collectionBehavior = behavior;
  }
  NativeWidgetMacNSWindow* widget_window =
      base::apple::ObjCCast<NativeWidgetMacNSWindow>(window);
  [widget_window
      setActivationIndependence:window.level >= NSFloatingWindowLevel];
}

void LetSolaraPictureInPictureMoveFreely(gfx::NativeWindow native) {
  base::apple::ObjCCast<NativeWidgetMacNSWindow>(native.GetNativeNSWindow())
      .movesFreelyAcrossDisplays = YES;
}

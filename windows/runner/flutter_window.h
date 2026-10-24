#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The `nrs/screen` channel: the screen eyedropper in the custom-colour
  // editor reads the pixel under the cursor through it, along with the current
  // state of the left button and Escape.
  void RegisterScreenChannel();

  // The `nrs/clipboard` channel: returns a clipboard bitmap as PNG bytes, or
  // as raw RGBA that Dart encodes itself when only a DIB is available.
  void RegisterClipboardChannel();

  // Shrinks the window to a slim bar at the bottom of the work area while the
  // eyedropper is live, so the screen being sampled is actually visible.
  void CollapseForSampling();

  // Puts the window back exactly where it was, maximised state included.
  void RestoreAfterSampling();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Kept alive for the lifetime of the window; the engine holds a weak
  // reference to the handler inside it.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      screen_channel_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      clipboard_channel_;

  // The geometry to come back to after an eyedropper pick. Captured before the
  // collapse; SetWindowPlacement restores the normal rect and the maximised
  // state in one go.
  WINDOWPLACEMENT saved_placement_{};
  bool has_saved_placement_ = false;

  // True while the window is squeezed into the sampling bar. `window_manager`
  // enforces the app's 900x580 minimum through WM_GETMINMAXINFO, which would
  // otherwise clamp the bar back to full size; this flag lifts that floor for
  // the duration of the pick only.
  bool collapsed_for_sampling_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_

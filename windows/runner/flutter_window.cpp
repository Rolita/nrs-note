#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// One-shot timer that raises the editor after a pick.
//
// The confirming click belongs to whichever window is under the pointer, and
// that window is activated by it. Raising the editor in the very same frame
// would hide the application the user was aiming at before they ever saw it
// come forward, so the raise waits a beat.
constexpr UINT_PTR kRaiseTimerId = 0x4E525331;  // 'NRS1'
constexpr UINT kRaiseDelayMs = 220;

// Reads the one physical pixel under the cursor.
//
// BitBlt into a 1x1 memory bitmap first, then GetPixel: reading straight from
// the screen DC is unreliable once the window is composited by the DWM, while
// a 1x1 copy costs nothing. An empty result means this frame could not be read
// (an exclusive-fullscreen app owning the display, for instance).
std::optional<COLORREF> SampleScreenPixel(POINT cursor) {
  HDC screen = ::GetDC(nullptr);
  if (screen == nullptr) {
    return std::nullopt;
  }

  std::optional<COLORREF> sample;
  HDC memory = ::CreateCompatibleDC(screen);
  if (memory != nullptr) {
    HBITMAP bitmap = ::CreateCompatibleBitmap(screen, 1, 1);
    if (bitmap != nullptr) {
      HGDIOBJ previous = ::SelectObject(memory, bitmap);
      if (::BitBlt(memory, 0, 0, 1, 1, screen, cursor.x, cursor.y, SRCCOPY)) {
        const COLORREF pixel = ::GetPixel(memory, 0, 0);
        if (pixel != CLR_INVALID) {
          sample = pixel;
        }
      }
      ::SelectObject(memory, previous);
      ::DeleteObject(bitmap);
    }
    ::DeleteDC(memory);
  }
  ::ReleaseDC(nullptr, screen);
  return sample;
}

// Whether a key is down *right now*. The eyedropper uses it to tell "confirm"
// from "cancel": it never receives the click itself.
bool IsKeyDown(int key) { return (::GetAsyncKeyState(key) & 0x8000) != 0; }

// Puts the window back in front and gives it the keyboard.
//
// The confirming click lands on whatever is under the pointer -- usually another
// application, because that is the colour being sampled. Activating that window
// also takes the foreground, and Windows then refuses SetForegroundWindow from
// anyone else (FOREGROUNDLOCKTIMEOUT): the editor would restore its geometry but
// stay behind the window it sampled, which reads as "the window never came
// back". Briefly sharing the foreground thread's input queue is the documented
// way around that refusal; the queues are detached immediately afterwards.
void ActivateWindow(HWND hwnd) {
  if (hwnd == nullptr) {
    return;
  }
  const HWND foreground = ::GetForegroundWindow();
  if (foreground == hwnd) {
    return;
  }

  DWORD foreground_thread = 0;
  if (foreground != nullptr) {
    foreground_thread = ::GetWindowThreadProcessId(foreground, nullptr);
  }
  const DWORD current_thread = ::GetCurrentThreadId();

  bool attached = false;
  if (foreground_thread != 0 && foreground_thread != current_thread) {
    attached =
        ::AttachThreadInput(current_thread, foreground_thread, TRUE) != FALSE;
  }
  ::BringWindowToTop(hwnd);
  ::SetForegroundWindow(hwnd);
  if (attached) {
    ::AttachThreadInput(current_thread, foreground_thread, FALSE);
  }
  if (::GetForegroundWindow() != hwnd) {
    // Still not ours: the window that took the foreground may be elevated, and
    // an input queue cannot be shared across integrity levels. At least lift the
    // editor above the normal Z-order, so the restore is visible even though the
    // keyboard stays where the click put it.
    ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    ::SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  // Hangs the eyedropper's channel off the engine, so it has to come after.
  RegisterScreenChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    screen_channel_ = nullptr;
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::CollapseForSampling() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }

  // A raise from the previous pick may still be pending; this session owns the
  // window now, so cancel it.
  ::KillTimer(hwnd, kRaiseTimerId);

  // Remember exactly where it was. GetWindowPlacement reports the *restored*
  // rect even when the window is maximised, which is what makes the two-step
  // restore possible later. If it ever fails, fall back to the plain window
  // rect: leaving without a snapshot would strand the window in its collapsed
  // shape, which is far worse than losing the maximised flag.
  if (!has_saved_placement_) {
    WINDOWPLACEMENT placement;
    placement.length = sizeof(WINDOWPLACEMENT);
    if (::GetWindowPlacement(hwnd, &placement)) {
      saved_placement_ = placement;
      has_saved_placement_ = true;
    } else {
      RECT rect{};
      if (::GetWindowRect(hwnd, &rect)) {
        saved_placement_ = WINDOWPLACEMENT{};
        saved_placement_.length = sizeof(WINDOWPLACEMENT);
        saved_placement_.showCmd =
            ::IsZoomed(hwnd) ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL;
        saved_placement_.rcNormalPosition = rect;
        has_saved_placement_ = true;
      }
    }
  }

  // SetWindowPos alone would leave a maximised window "maximised" over its new
  // small rect, so normalise the show state first.
  if (::IsZoomed(hwnd) || ::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  }

  HMONITOR monitor = ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info;
  info.cbSize = sizeof(MONITORINFO);
  if (!::GetMonitorInfo(monitor, &info)) {
    return;
  }

  // A slim bar along the bottom of the work area: everything being sampled
  // stays in view, and the hint still has a place to sit.
  const LONG work_width = info.rcWork.right - info.rcWork.left;
  const LONG work_height = info.rcWork.bottom - info.rcWork.top;
  const LONG width = work_width > 568 ? 520 : work_width - 48;
  const LONG height = work_height > 300 ? 148 : work_height - 40;
  const LONG x = info.rcWork.left + (work_width - width) / 2;
  const LONG y = info.rcWork.bottom - height - 16;

  // Lift the app's minimum size first: WM_GETMINMAXINFO is consulted while
  // resizing, and the plugin would otherwise refuse anything below 900x580.
  collapsed_for_sampling_ = true;
  ::SetWindowPos(hwnd, HWND_TOP, x, y, width, height,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

void FlutterWindow::RestoreAfterSampling() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || !has_saved_placement_) {
    return;
  }

  // Geometry and show state are restored in two explicit steps rather than one
  // SetWindowPlacement: with the plugin policing WM_GETMINMAXINFO, asking for
  // "restore to normal, then maximise" in a single call is the part that kept
  // failing to take effect.
  const RECT& normal = saved_placement_.rcNormalPosition;
  const bool was_maximized = saved_placement_.showCmd == SW_SHOWMAXIMIZED;

  ::SetWindowPos(hwnd, HWND_TOP, normal.left, normal.top,
                 normal.right - normal.left, normal.bottom - normal.top,
                 SWP_NOACTIVATE | SWP_SHOWWINDOW);
  // Only now does the app's minimum size apply again.
  collapsed_for_sampling_ = false;
  if (was_maximized) {
    ::ShowWindow(hwnd, SW_MAXIMIZE);
  }
  has_saved_placement_ = false;
  // The pick may have ended over another application -- that window took the
  // foreground as the click landed. Take it back, but not instantly: see
  // kRaiseDelayMs. Geometry is already back, so the editor is visibly waiting
  // behind whatever was clicked until the raise lands.
  ::SetTimer(hwnd, kRaiseTimerId, kRaiseDelayMs, nullptr);
}

void FlutterWindow::RegisterScreenChannel() {
  screen_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "nrs/screen",
          &flutter::StandardMethodCodec::GetInstance());

  screen_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "start") {
          // Shrink first, capture second: resizing is the one thing here that
          // could disturb the mouse capture, and nothing can slip in between
          // the two calls.
          CollapseForSampling();
          // Take the mouse for the duration of the pick. The confirming click
          // then lands on this window rather than on whatever sits under the
          // cursor, so the target window is neither activated nor pushed in
          // front of the editor -- that is what made a pick *look* like it had
          // done nothing.
          //
          // It also means we never disturb the other application: the click is
          // swallowed by the overlay and the colour comes from the global
          // mouse position, not from that application.
          ::SetCapture(GetHandle());
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (call.method_name() == "stop") {
          ::ReleaseCapture();
          RestoreAfterSampling();
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (call.method_name() != "sample") {
          result->NotImplemented();
          return;
        }

        POINT cursor;
        std::optional<COLORREF> pixel =
            ::GetCursorPos(&cursor) ? SampleScreenPixel(cursor) : std::nullopt;
        if (!pixel) {
          // Nothing to read this frame: a null reply, which Dart treats as a
          // failed sample and gives up on.
          result->Success();
          return;
        }

        const COLORREF color = *pixel;
        // GetRValue/GetGValue/GetBValue are macros, so no `::` in front of them.
        const uint32_t rgb = static_cast<uint32_t>(GetRValue(color)) << 16 |
                             static_cast<uint32_t>(GetGValue(color)) << 8 |
                             static_cast<uint32_t>(GetBValue(color));
        // A screen pixel is always opaque, so the alpha byte is filled in.
        const int64_t argb = static_cast<int64_t>(0xFF000000u | rgb);

        flutter::EncodableMap sample;
        sample[flutter::EncodableValue("color")] = flutter::EncodableValue(argb);
        sample[flutter::EncodableValue("down")] =
            flutter::EncodableValue(IsKeyDown(VK_LBUTTON));
        sample[flutter::EncodableValue("escape")] =
            flutter::EncodableValue(IsKeyDown(VK_ESCAPE));
        result->Success(flutter::EncodableValue(sample));
      });
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // While the eyedropper is up, drop the minimum tracking size the plugin
  // installs. It has to happen before the plugin sees the message: delegates
  // are consulted first and answer WM_GETMINMAXINFO themselves, so anything
  // they write would win. DefWindowProc still runs, so the rest of the
  // structure keeps its usual values.
  if (collapsed_for_sampling_ && message == WM_GETMINMAXINFO) {
    const LRESULT result =
        Win32Window::MessageHandler(hwnd, message, wparam, lparam);
    MINMAXINFO* info = reinterpret_cast<MINMAXINFO*>(lparam);
    info->ptMinTrackSize.x = 0;
    info->ptMinTrackSize.y = 0;
    return result;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_TIMER:
      if (wparam == kRaiseTimerId) {
        ::KillTimer(hwnd, kRaiseTimerId);
        // A new pick may have started in the meantime; it owns the window.
        if (!collapsed_for_sampling_) {
          ActivateWindow(hwnd);
        }
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

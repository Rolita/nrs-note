#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <cstring>
#include <optional>
#include <vector>

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

// Fallback for the startup show.
//
// Showing the window is Dart's job (it is the only side that knows the final
// geometry). If that call never arrives -- a crash, a hung isolate -- the
// window would stay invisible forever, so after a few seconds it appears at
// whatever position it has. Generous on purpose: the normal path takes well
// under a second, and showing too early is exactly the glitch this avoids.
constexpr UINT_PTR kShowFallbackTimerId = 0x4E525332;  // 'NRS2'
constexpr UINT kShowFallbackMs = 4000;

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

// Keeps the clipboard open for exactly one read. Every branch -- success,
// unsupported format, or failure -- must hand it back, otherwise the next
// application that tries to paste waits forever.
class ClipboardSession {
 public:
  ClipboardSession() : opened_(::OpenClipboard(nullptr) != FALSE) {}
  ~ClipboardSession() {
    if (opened_) {
      ::CloseClipboard();
    }
  }
  ClipboardSession(const ClipboardSession&) = delete;
  ClipboardSession& operator=(const ClipboardSession&) = delete;

  bool opened() const { return opened_; }

 private:
  bool opened_;
};

// Copies one clipboard global-memory block into a byte vector.
bool CopyGlobalBytes(HANDLE handle, std::vector<uint8_t>* bytes) {
  if (handle == nullptr) {
    return false;
  }
  const SIZE_T size = ::GlobalSize(handle);
  if (size == 0) {
    return false;
  }
  const void* data = ::GlobalLock(handle);
  if (data == nullptr) {
    return false;
  }
  const uint8_t* begin = static_cast<const uint8_t*>(data);
  bytes->assign(begin, begin + size);
  ::GlobalUnlock(handle);
  return true;
}

// Turns a device-independent bitmap into top-down RGBA.
//
// Clipboard DIBs come in several dialects: 24 or 32 bits, with or without a
// BITFIELDS mask block, and with the rows stored bottom-up (positive height)
// or top-down (negative height). Only the standard BGRA / BGR layouts are
// accepted; anything else returns false so the Dart side simply does not paste
// rather than showing a scrambled picture.
bool DecodeDib(const std::vector<uint8_t>& dib,
               std::vector<uint8_t>* rgba,
               int* out_width,
               int* out_height) {
  if (dib.size() < sizeof(BITMAPINFOHEADER)) {
    return false;
  }
  BITMAPINFOHEADER header{};
  std::memcpy(&header, dib.data(), sizeof(header));
  if (header.biSize < sizeof(BITMAPINFOHEADER) ||
      header.biSize > dib.size()) {
    return false;
  }
  if (header.biPlanes != 1) {
    return false;
  }
  if (header.biBitCount != 24 && header.biBitCount != 32) {
    return false;
  }
  if (header.biCompression != BI_RGB &&
      header.biCompression != BI_BITFIELDS) {
    return false;
  }
  if (header.biWidth <= 0 || header.biHeight == 0) {
    return false;
  }

  const int64_t width = header.biWidth;
  const int64_t height =
      header.biHeight < 0 ? -static_cast<int64_t>(header.biHeight)
                          : static_cast<int64_t>(header.biHeight);
  if (width * height > 40000000) {
    return false;
  }

  size_t pixel_offset = header.biSize;
  if (header.biCompression == BI_BITFIELDS) {
    if (header.biBitCount != 32) {
      return false;
    }
    // BITMAPV4HEADER and later carry the masks in the header itself; a plain
    // BITMAPINFOHEADER is followed by three separate DWORDs.
    const size_t mask_offset =
        header.biSize >= 52 ? 40 : sizeof(BITMAPINFOHEADER);
    if (mask_offset + 3 * sizeof(DWORD) > dib.size()) {
      return false;
    }
    DWORD masks[3] = {0, 0, 0};
    std::memcpy(masks, dib.data() + mask_offset, sizeof(masks));
    if (masks[0] != 0x00FF0000 || masks[1] != 0x0000FF00 ||
        masks[2] != 0x000000FF) {
      return false;
    }
    if (header.biSize < 52) {
      pixel_offset += 3 * sizeof(DWORD);
    }
  }

  if (header.biClrUsed > 0) {
    const int64_t palette_bytes =
        static_cast<int64_t>(header.biClrUsed) * 4;
    if (palette_bytes >
        static_cast<int64_t>(dib.size()) -
            static_cast<int64_t>(pixel_offset)) {
      return false;
    }
    pixel_offset += static_cast<size_t>(palette_bytes);
  }
  if (pixel_offset > dib.size()) {
    return false;
  }

  const int64_t stride =
      ((width * header.biBitCount + 31) / 32) * 4;
  if (stride <= 0) {
    return false;
  }
  const int64_t image_bytes = stride * height;
  if (image_bytes >
      static_cast<int64_t>(dib.size()) -
          static_cast<int64_t>(pixel_offset)) {
    return false;
  }

  rgba->assign(static_cast<size_t>(width * height * 4), 0);
  const uint8_t* pixels = dib.data() + pixel_offset;
  const bool bottom_up = header.biHeight > 0;
  bool any_alpha = false;

  for (int64_t y = 0; y < height; ++y) {
    const uint8_t* row =
        pixels + (bottom_up ? (height - 1 - y) : y) * stride;
    uint8_t* out = rgba->data() + static_cast<size_t>(y * width * 4);
    if (header.biBitCount == 24) {
      for (int64_t x = 0; x < width; ++x) {
        out[x * 4 + 0] = row[x * 3 + 2];
        out[x * 4 + 1] = row[x * 3 + 1];
        out[x * 4 + 2] = row[x * 3 + 0];
        out[x * 4 + 3] = 255;
      }
    } else {
      for (int64_t x = 0; x < width; ++x) {
        out[x * 4 + 0] = row[x * 4 + 2];
        out[x * 4 + 1] = row[x * 4 + 1];
        out[x * 4 + 2] = row[x * 4 + 0];
        const uint8_t alpha = row[x * 4 + 3];
        out[x * 4 + 3] = alpha;
        if (alpha != 0) {
          any_alpha = true;
        }
      }
    }
  }

  // Screenshot tools often use 32bpp without ever filling the alpha byte.
  // Treating an all-zero alpha channel as opaque is what makes those pastes
  // visible instead of a fully transparent picture.
  if (header.biBitCount == 32 && !any_alpha) {
    for (size_t i = 3; i < rgba->size(); i += 4) {
      (*rgba)[i] = 255;
    }
  }

  *out_width = static_cast<int>(width);
  *out_height = static_cast<int>(height);
  return true;
}

// The clipboard image, as either `{png}` or `{rgba, width, height}`; an empty
// value when there is nothing usable. PNG wins because it needs no conversion.
flutter::EncodableValue ReadClipboardImage() {
  ClipboardSession clipboard;
  if (!clipboard.opened()) {
    return flutter::EncodableValue();
  }

  const UINT png_format = ::RegisterClipboardFormatW(L"PNG");
  if (png_format != 0 && ::IsClipboardFormatAvailable(png_format)) {
    std::vector<uint8_t> png;
    if (CopyGlobalBytes(::GetClipboardData(png_format), &png) &&
        !png.empty()) {
      flutter::EncodableMap reply;
      reply[flutter::EncodableValue("png")] = flutter::EncodableValue(png);
      return flutter::EncodableValue(reply);
    }
  }

  const UINT dib_formats[] = {CF_DIBV5, CF_DIB};
  for (UINT format : dib_formats) {
    if (!::IsClipboardFormatAvailable(format)) {
      continue;
    }
    std::vector<uint8_t> dib;
    if (!CopyGlobalBytes(::GetClipboardData(format), &dib)) {
      continue;
    }
    std::vector<uint8_t> rgba;
    int width = 0;
    int height = 0;
    if (!DecodeDib(dib, &rgba, &width, &height)) {
      continue;
    }
    flutter::EncodableMap reply;
    reply[flutter::EncodableValue("rgba")] = flutter::EncodableValue(rgba);
    reply[flutter::EncodableValue("width")] = flutter::EncodableValue(width);
    reply[flutter::EncodableValue("height")] = flutter::EncodableValue(height);
    return flutter::EncodableValue(reply);
  }

  return flutter::EncodableValue();
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
  RegisterClipboardChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Do not show the window here (the template does, via SetNextFrameCallback).
  // The window is still at the origin from main.cpp -- (10, 10) -- and its real
  // size and position are only known once Dart's setupWindow() has run
  // waitUntilReadyToShow (frameless, 1360x880, centred). Showing on the first
  // frame puts a window in the top left corner for a hundred milliseconds and
  // then teleports it to the middle, which reads as a glitch.
  //
  // Dart owns the moment of appearance now: window_setup_io.dart calls
  // windowManager.show() after the geometry is settled. This timer is only a
  // safety net for the case where that never happens (a Dart-side failure
  // before the call) -- an invisible-but-alive window is worse than a
  // misplaced one.
  ::SetTimer(GetHandle(), kShowFallbackTimerId, kShowFallbackMs, nullptr);

  // Flutter can complete the first frame before anything is registered to
  // observe it. Asking for a frame here keeps the startup path identical to
  // the template's: one frame is already rendered by the time the window
  // becomes visible.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    screen_channel_ = nullptr;
    clipboard_channel_ = nullptr;
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

void FlutterWindow::RegisterClipboardChannel() {
  clipboard_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "nrs/clipboard",
          &flutter::StandardMethodCodec::GetInstance());

  clipboard_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "readImage") {
          result->NotImplemented();
          return;
        }
        // Every failure path inside the helper answers null, never an error:
        // "the clipboard has no picture" is an ordinary outcome of Ctrl+V.
        result->Success(ReadClipboardImage());
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
      if (wparam == kShowFallbackTimerId) {
        ::KillTimer(hwnd, kShowFallbackTimerId);
        // Dart normally showed it long ago; this only fires when that path
        // never ran.
        if (!::IsWindowVisible(hwnd)) {
          ::ShowWindow(hwnd, SW_SHOWNORMAL);
        }
      }
      break;
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

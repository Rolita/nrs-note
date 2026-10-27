#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <cstdint>
#include <cstring>
#include <optional>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Fallback for the startup show.
//
// Showing the window is Dart's job (it is the only side that knows the final
// geometry). If that call never arrives -- a crash, a hung isolate -- the
// window would stay invisible forever, so after a few seconds it appears at
// whatever position it has. Generous on purpose: the normal path takes well
// under a second, and showing too early is exactly the glitch this avoids.
constexpr UINT_PTR kShowFallbackTimerId = 0x4E525332;  // 'NRS2'
constexpr UINT kShowFallbackMs = 4000;

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
    clipboard_channel_ = nullptr;
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
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

#include "flutter_window.h"

#include <optional>
#include <filesystem>
#include <cstring>
#include <cstdint>
#include <mutex>
#include <string>
#include <vector>

#include <flutter/standard_method_codec.h>
#include <gdiplus.h>

namespace {
HICON CreateIconFromPng(const std::vector<uint8_t>& bytes) {
  if (bytes.empty()) return nullptr;
  static std::once_flag startup_once;
  static ULONG_PTR gdiplus_token = 0;
  std::call_once(startup_once, [] {
    Gdiplus::GdiplusStartupInput startup;
    Gdiplus::GdiplusStartup(&gdiplus_token, &startup, nullptr);
  });
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes.size());
  if (memory == nullptr) return nullptr;
  void* destination = GlobalLock(memory);
  if (destination == nullptr) {
    GlobalFree(memory);
    return nullptr;
  }
  memcpy(destination, bytes.data(), bytes.size());
  GlobalUnlock(memory);
  IStream* stream = nullptr;
  if (CreateStreamOnHGlobal(memory, TRUE, &stream) != S_OK) {
    GlobalFree(memory);
    return nullptr;
  }
  Gdiplus::Bitmap bitmap(stream);
  HICON icon = nullptr;
  if (bitmap.GetLastStatus() == Gdiplus::Ok) bitmap.GetHICON(&icon);
  stream->Release();
  return icon;
}
}  // namespace

#include "flutter/generated_plugin_registrant.h"

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
  app_icon_channel_ = std::make_unique<
      flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(),
      "app.ghostbox.ghostbox/app_icon",
      &flutter::StandardMethodCodec::GetInstance());
  const HWND icon_window = GetHandle();
  app_icon_channel_->SetMethodCallHandler(
      [icon_window](const flutter::MethodCall<flutter::EncodableValue>& call,
                    std::unique_ptr<flutter::MethodResult<
                        flutter::EncodableValue>> result) {
        if (call.method_name() != "setAppIcon") {
          result->NotImplemented();
          return;
        }
        const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
        if (arguments == nullptr) {
          result->Success(flutter::EncodableValue(false));
          return;
        }
        const auto variant_entry = arguments->find(flutter::EncodableValue("variant"));
        if (variant_entry == arguments->end() ||
            !std::holds_alternative<std::string>(variant_entry->second)) {
          result->Success(flutter::EncodableValue(false));
          return;
        }
        const std::string variant = std::get<std::string>(variant_entry->second);
        HICON icon = nullptr;
        if (variant == "custom") {
          const auto png_entry = arguments->find(flutter::EncodableValue("customPng"));
          if (png_entry != arguments->end()) {
            const auto* png = std::get_if<std::vector<uint8_t>>(&png_entry->second);
            if (png != nullptr) icon = CreateIconFromPng(*png);
          }
        } else if (variant.find_first_not_of(
                       "abcdefghijklmnopqrstuvwxyz") == std::string::npos) {
          wchar_t executable[MAX_PATH];
          const DWORD length = GetModuleFileNameW(nullptr, executable, MAX_PATH);
          if (length > 0 && length < MAX_PATH) {
            std::filesystem::path icon_path(executable);
            icon_path = icon_path.parent_path() / L"data" / L"flutter_assets" /
                        L"assets" / L"icons" /
                        (std::wstring(variant.begin(), variant.end()) + L".ico");
            icon = static_cast<HICON>(LoadImageW(
                nullptr, icon_path.c_str(), IMAGE_ICON, 0, 0,
                LR_LOADFROMFILE | LR_DEFAULTSIZE));
          }
        }
        if (icon == nullptr) {
          result->Success(flutter::EncodableValue(false));
          return;
        }
        static std::vector<HICON> retained_icons;
        retained_icons.push_back(icon);
        SendMessageW(icon_window, WM_SETICON, ICON_BIG,
                     reinterpret_cast<LPARAM>(icon));
        SendMessageW(icon_window, WM_SETICON, ICON_SMALL,
                     reinterpret_cast<LPARAM>(icon));
        result->Success(flutter::EncodableValue(true));
      });
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
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

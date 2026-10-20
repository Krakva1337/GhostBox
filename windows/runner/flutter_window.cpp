#include "flutter_window.h"

#include <optional>
#include <filesystem>
#include <cstring>
#include <cstdint>
#include <fstream>
#include <iterator>
#include <mutex>
#include <string>
#include <vector>

#include <flutter/standard_method_codec.h>
#include <gdiplus.h>
#include <shlobj.h>
#include <shobjidl.h>

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

void AppendU16(std::vector<uint8_t>& output, uint16_t value) {
  output.push_back(static_cast<uint8_t>(value & 0xff));
  output.push_back(static_cast<uint8_t>((value >> 8) & 0xff));
}

void AppendU32(std::vector<uint8_t>& output, uint32_t value) {
  AppendU16(output, static_cast<uint16_t>(value & 0xffff));
  AppendU16(output, static_cast<uint16_t>((value >> 16) & 0xffff));
}

std::vector<uint8_t> WrapPngAsIco(const std::vector<uint8_t>& png) {
  if (png.size() < 8 || png.size() > UINT32_MAX ||
      png[0] != 0x89 || png[1] != 'P' || png[2] != 'N' || png[3] != 'G') {
    return {};
  }
  std::vector<uint8_t> ico;
  ico.reserve(22 + png.size());
  AppendU16(ico, 0);    // ICONDIR reserved
  AppendU16(ico, 1);    // ICONDIR type: icon
  AppendU16(ico, 1);    // ICONDIR count
  ico.insert(ico.end(), {0, 0, 0, 0}); // 256x256, default PNG frame
  AppendU16(ico, 1);    // planes
  AppendU16(ico, 32);   // bit depth
  AppendU32(ico, static_cast<uint32_t>(png.size()));
  AppendU32(ico, 22);   // image data offset
  ico.insert(ico.end(), png.begin(), png.end());
  return ico;
}

std::filesystem::path LauncherIconPath() {
  PWSTR local_app_data = nullptr;
  if (SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_CREATE, nullptr,
                           &local_app_data) != S_OK) {
    return {};
  }
  std::filesystem::path directory(local_app_data);
  CoTaskMemFree(local_app_data);
  directory /= L"GhostBox";
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  if (error) return {};
  return directory / L"ghostbox-current.ico";
}

void RefreshGhostBoxShortcuts(const std::filesystem::path& icon_path) {
  PWSTR desktop = nullptr;
  PWSTR programs = nullptr;
  if (SHGetKnownFolderPath(FOLDERID_Desktop, KF_FLAG_DEFAULT, nullptr,
                           &desktop) != S_OK ||
      SHGetKnownFolderPath(FOLDERID_Programs, KF_FLAG_DEFAULT, nullptr,
                           &programs) != S_OK) {
    if (desktop) CoTaskMemFree(desktop);
    if (programs) CoTaskMemFree(programs);
    return;
  }

  wchar_t executable[MAX_PATH];
  const DWORD length = GetModuleFileNameW(nullptr, executable, MAX_PATH);
  if (length == 0 || length >= MAX_PATH) {
    CoTaskMemFree(desktop);
    CoTaskMemFree(programs);
    return;
  }

  const HRESULT initialized = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  const bool uninitialize = initialized == S_OK || initialized == S_FALSE;
  if (SUCCEEDED(initialized) || initialized == RPC_E_CHANGED_MODE) {
    const std::filesystem::path roots[] = {desktop, programs};
    for (const auto& root : roots) {
      std::error_code error;
      if (!std::filesystem::is_directory(root, error)) continue;
      for (std::filesystem::recursive_directory_iterator it(
               root, std::filesystem::directory_options::skip_permission_denied,
               error), end;
           it != end; it.increment(error)) {
        if (error) { error.clear(); continue; }
        if (!it->is_regular_file(error) ||
            it->path().extension() != L".lnk") continue;

        IShellLinkW* link = nullptr;
        if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                    IID_IShellLinkW,
                                    reinterpret_cast<void**>(&link)))) continue;
        IPersistFile* persist = nullptr;
        if (SUCCEEDED(link->QueryInterface(IID_IPersistFile,
                                           reinterpret_cast<void**>(&persist))) &&
            SUCCEEDED(persist->Load(it->path().c_str(), STGM_READWRITE))) {
          wchar_t target[MAX_PATH] = {};
          WIN32_FIND_DATAW find_data = {};
          if (SUCCEEDED(link->GetPath(target, MAX_PATH, &find_data,
                                      SLGP_RAWPATH)) &&
              CompareStringOrdinal(target, -1, executable, -1, TRUE) == CSTR_EQUAL) {
            if (SUCCEEDED(link->SetIconLocation(icon_path.c_str(), 0)) &&
                SUCCEEDED(persist->Save(it->path().c_str(), TRUE))) {
              SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATHW,
                             it->path().c_str(), nullptr);
            }
          }
          persist->Release();
        }
        link->Release();
      }
    }
  }
  if (uninitialize) CoUninitialize();
  CoTaskMemFree(desktop);
  CoTaskMemFree(programs);
}

void PersistLauncherIcon(const std::vector<uint8_t>& icon_bytes) {
  if (icon_bytes.empty()) return;
  const auto path = LauncherIconPath();
  if (path.empty()) return;
  const auto temporary = path.wstring() + L".new";
  {
    std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
    if (!output) return;
    output.write(reinterpret_cast<const char*>(icon_bytes.data()),
                 static_cast<std::streamsize>(icon_bytes.size()));
    if (!output) return;
  }
  std::error_code error;
  std::filesystem::rename(temporary, path, error);
  if (error) {
    std::filesystem::remove(path, error);
    error.clear();
    std::filesystem::rename(temporary, path, error);
  }
  if (!error) RefreshGhostBoxShortcuts(path);
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

  // app_links forwards protocol activations to the existing Flutter window
  // with WM_COPYDATA. Windows UIPI blocks that message when GhostBox is running
  // elevated, which otherwise starts a second copy and loses the activation.
  CHANGEFILTERSTRUCT message_filter = {sizeof(CHANGEFILTERSTRUCT)};
  ChangeWindowMessageFilterEx(GetHandle(), WM_COPYDATA, MSGFLT_ALLOW,
                              &message_filter);

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
        std::vector<uint8_t> launcher_icon;
        if (variant == "custom") {
          const auto png_entry = arguments->find(flutter::EncodableValue("customPng"));
          if (png_entry != arguments->end()) {
            const auto* png = std::get_if<std::vector<uint8_t>>(&png_entry->second);
            if (png != nullptr) {
              icon = CreateIconFromPng(*png);
              launcher_icon = WrapPngAsIco(*png);
            }
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
            std::ifstream input(icon_path, std::ios::binary);
            launcher_icon.assign(std::istreambuf_iterator<char>(input),
                                 std::istreambuf_iterator<char>());
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
        PersistLauncherIcon(launcher_icon);
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

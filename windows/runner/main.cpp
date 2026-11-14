#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shlobj.h>
#include <windows.h>

#include <filesystem>
#include <string>
#include <system_error>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {
bool IsFile(const std::filesystem::path &path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

bool IsDirectory(const std::filesystem::path &path) {
  const DWORD attributes = GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0;
}

std::wstring ExecutableDirectory() {
  std::vector<wchar_t> path(32768);
  const DWORD length =
      GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size())
    return {};
  return std::filesystem::path(std::wstring(path.data(), length))
      .parent_path()
      .wstring();
}

std::wstring WriteStartupDiagnostic(const std::wstring &details) {
  PWSTR local_app_data = nullptr;
  if (SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr,
                           &local_app_data) != S_OK) {
    return {};
  }
  const std::filesystem::path log_path = std::filesystem::path(local_app_data) /
                                         L"GhostBox" / L"logs" / L"startup.log";
  CoTaskMemFree(local_app_data);

  std::error_code error;
  std::filesystem::create_directories(log_path.parent_path(), error);
  if (error)
    return {};

  HANDLE file = CreateFileW(log_path.c_str(), FILE_APPEND_DATA,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE)
    return {};

  SYSTEMTIME now{};
  GetLocalTime(&now);
  const std::wstring line =
      L"[" + std::to_wstring(now.wYear) + L"-" +
      (now.wMonth < 10 ? L"0" : L"") + std::to_wstring(now.wMonth) + L"-" +
      (now.wDay < 10 ? L"0" : L"") + std::to_wstring(now.wDay) + L" " +
      (now.wHour < 10 ? L"0" : L"") + std::to_wstring(now.wHour) + L":" +
      (now.wMinute < 10 ? L"0" : L"") + std::to_wstring(now.wMinute) + L":" +
      (now.wSecond < 10 ? L"0" : L"") + std::to_wstring(now.wSecond) + L"] " +
      details + L"\r\n";
  const int byte_count = WideCharToMultiByte(CP_UTF8, 0, line.data(),
                                             static_cast<int>(line.size()),
                                             nullptr, 0, nullptr, nullptr);
  if (byte_count > 0) {
    std::string utf8(static_cast<size_t>(byte_count), '\0');
    WideCharToMultiByte(CP_UTF8, 0, line.data(), static_cast<int>(line.size()),
                        utf8.data(), byte_count, nullptr, nullptr);
    DWORD written = 0;
    WriteFile(file, utf8.data(), static_cast<DWORD>(utf8.size()), &written,
              nullptr);
  }
  CloseHandle(file);
  return log_path.wstring();
}

void ShowStartupFailure(const std::wstring &reason) {
  const std::wstring log_path = WriteStartupDiagnostic(reason);
  std::wstring message =
      L"GhostBox could not start its Windows interface.\n\n" + reason +
      L"\n\nCheck the installation files and restart GhostBox.";
  if (!log_path.empty()) {
    message += L"\n\nStartup details were saved to:\n" + log_path;
  }
  MessageBoxW(nullptr, message.c_str(), L"GhostBox startup error",
              MB_OK | MB_ICONERROR | MB_SETFOREGROUND);
}
} // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  const std::wstring executable_directory = ExecutableDirectory();
  if (executable_directory.empty()) {
    ShowStartupFailure(
        L"Windows could not determine the GhostBox executable path.");
    ::CoUninitialize();
    return EXIT_FAILURE;
  }

  // DartProject accepts paths relative to the executable, but use an absolute
  // path so startup never depends on the shell/installer working directory.
  const std::filesystem::path data_directory =
      std::filesystem::path(executable_directory) / L"data";
  const auto icu_data = data_directory / L"icudtl.dat";
  const auto aot_library = data_directory / L"app.so";
  const auto flutter_assets = data_directory / L"flutter_assets";
  const auto asset_manifest = flutter_assets / L"AssetManifest.bin";
  const auto flutter_library =
      std::filesystem::path(executable_directory) / L"flutter_windows.dll";
  if (!IsFile(icu_data) || !IsFile(aot_library) || !IsFile(asset_manifest) ||
      !IsFile(flutter_library) || !IsDirectory(flutter_assets)) {
    ShowStartupFailure(L"A required Flutter runtime file is missing. " +
                       L"Expected " + icu_data.wstring() + L", " +
                       aot_library.wstring() + L", " +
                       asset_manifest.wstring() + L", and " +
                       flutter_library.wstring() + L".");
    ::CoUninitialize();
    return EXIT_FAILURE;
  }

  flutter::DartProject project(executable_directory + L"\\data");

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"GhostBox", origin, size)) {
    ShowStartupFailure(
        L"The Flutter engine or its native window could not be initialized. "
        L"Check that the installation is complete and that Windows security "
        L"software has not blocked GhostBox runtime files.");
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}

#include "core_lifecycle.h"

#include <flutter/standard_method_codec.h>
#include <tlhelp32.h>
#include <filesystem>
#include <string>
#include <vector>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;

std::wstring Wide(const std::string& text) {
  const int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
      text.data(), static_cast<int>(text.size()), nullptr, 0);
  if (count <= 0) return {};
  std::wstring result(count, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), result.data(), count);
  return result;
}
std::wstring ImagePath(HANDLE process) {
  std::wstring path(32768, L'\0');
  DWORD size = static_cast<DWORD>(path.size());
  if (!QueryFullProcessImageNameW(process, 0, path.data(), &size)) return {};
  path.resize(size);
  return path;
}
bool SamePath(const std::wstring& left, const std::wstring& right) {
  if (left.empty() || right.empty()) return false;
  std::error_code error;
  const auto a = std::filesystem::weakly_canonical(left, error);
  if (error) return false;
  const auto b = std::filesystem::weakly_canonical(right, error);
  return !error && CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1,
      TRUE) == CSTR_EQUAL;
}
bool IsCore(const std::wstring& path) {
  const auto filename = std::filesystem::path(path).filename().wstring();
  return _wcsicmp(filename.c_str(), L"xray.exe") == 0 ||
      _wcsicmp(filename.c_str(), L"sing-box.exe") == 0;
}
bool HasLiveOwner(DWORD parent_pid, HANDLE child) {
  // The caller disconnected its own backends before requesting cleanup. A
  // still-running child of this UI is therefore a leftover to reclaim.
  if (parent_pid == GetCurrentProcessId()) return false;
  HANDLE parent = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE,
      FALSE, parent_pid);
  if (!parent) return GetLastError() == ERROR_ACCESS_DENIED;
  const auto filename = std::filesystem::path(ImagePath(parent)).filename().wstring();
  FILETIME parent_created{}, child_created{}, exit{}, kernel{}, user{};
  const bool owner = WaitForSingleObject(parent, 0) == WAIT_TIMEOUT &&
      _wcsicmp(filename.c_str(), L"GhostBox.exe") == 0 &&
      GetProcessTimes(parent, &parent_created, &exit, &kernel, &user) &&
      GetProcessTimes(child, &child_created, &exit, &kernel, &user) &&
      CompareFileTime(&parent_created, &child_created) <= 0;
  CloseHandle(parent);
  return owner;
}
}  // namespace

CoreLifecycle::CoreLifecycle(flutter::BinaryMessenger* messenger) {
  job_ = CreateJobObjectW(nullptr, nullptr);
  if (job_) {
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (!SetInformationJobObject(job_, JobObjectExtendedLimitInformation,
        &limits, sizeof(limits))) {
      CloseHandle(job_);
      job_ = nullptr;
    }
  }
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(messenger,
      "app.ghostbox.ghostbox/core_lifecycle",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const flutter::MethodCall<Value>& call,
      std::unique_ptr<flutter::MethodResult<Value>> result) {
    const auto* args = std::get_if<Map>(call.arguments());
    if (!args) { result->Error("arguments", "Expected a map."); return; }
    if (call.method_name() == "trackCore") {
      const auto pid_entry = args->find(Value("pid"));
      const auto path_entry = args->find(Value("executable"));
      if (pid_entry == args->end() || path_entry == args->end() ||
          !std::holds_alternative<std::string>(path_entry->second) ||
          (!std::holds_alternative<int32_t>(pid_entry->second) &&
           !std::holds_alternative<int64_t>(pid_entry->second))) {
        result->Error("arguments", "Expected a core pid and executable."); return;
      }
      const auto number = std::holds_alternative<int32_t>(pid_entry->second)
          ? static_cast<int64_t>(std::get<int32_t>(pid_entry->second))
          : std::get<int64_t>(pid_entry->second);
      const auto expected = Wide(std::get<std::string>(path_entry->second));
      if (number <= 0 || number > MAXDWORD || !IsCore(expected)) {
        result->Error("arguments", "Invalid core identity."); return;
      }
      HANDLE process = OpenProcess(PROCESS_SET_QUOTA | PROCESS_TERMINATE |
          PROCESS_QUERY_LIMITED_INFORMATION, FALSE, static_cast<DWORD>(number));
      if (!process) { result->Error("process", "Cannot open VPN core."); return; }
      const bool matches = SamePath(expected, ImagePath(process));
      const bool tracked = matches && job_ && AssignProcessToJobObject(job_, process);
      const DWORD error = GetLastError();
      CloseHandle(process);
      if (!tracked) {
        result->Error("supervision", "Cannot supervise VPN core (Win32 " +
            std::to_string(error) + ")."); return;
      }
      result->Success(Value(true));
      return;
    }
    if (call.method_name() == "cleanupStaleCores") {
      const auto entry = args->find(Value("executables"));
      const auto* list = entry == args->end() ? nullptr :
          std::get_if<flutter::EncodableList>(&entry->second);
      if (!list) { result->Error("arguments", "Expected executable paths."); return; }
      std::vector<std::wstring> paths;
      for (const auto& item : *list) {
        const auto* text = std::get_if<std::string>(&item);
        if (!text || !IsCore(Wide(*text))) {
          result->Error("arguments", "Only Xray and sing-box cores are allowed."); return;
        }
        paths.push_back(Wide(*text));
      }
      HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
      if (snapshot == INVALID_HANDLE_VALUE) {
        result->Error("snapshot", "Cannot inspect running VPN cores."); return;
      }
      PROCESSENTRY32W process_entry{};
      process_entry.dwSize = sizeof(process_entry);
      int32_t stopped = 0;
      bool failed = false;
      if (Process32FirstW(snapshot, &process_entry)) do {
        if (!IsCore(process_entry.szExeFile)) continue;
        HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION |
            PROCESS_TERMINATE | SYNCHRONIZE, FALSE, process_entry.th32ProcessID);
        if (!process) continue;
        const auto path = ImagePath(process);
        bool matches = false;
        for (const auto& expected : paths) matches = matches || SamePath(path, expected);
        if (matches && !HasLiveOwner(process_entry.th32ParentProcessID, process)) {
          if (TerminateProcess(process, 0) && WaitForSingleObject(process, 3000) == WAIT_OBJECT_0) {
            ++stopped;
          } else { failed = true; }
        }
        CloseHandle(process);
      } while (Process32NextW(snapshot, &process_entry));
      CloseHandle(snapshot);
      if (failed) { result->Error("cleanup", "A stale VPN core did not stop."); return; }
      result->Success(Value(stopped));
      return;
    }
    result->NotImplemented();
  });
}
CoreLifecycle::~CoreLifecycle() {
  channel_->SetMethodCallHandler(nullptr);
  channel_.reset();
  if (job_) CloseHandle(job_);
}

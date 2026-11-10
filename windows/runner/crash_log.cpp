#include "crash_log.h"

#include <shlobj.h>

#include <algorithm>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <vector>

#ifndef FLUTTER_VERSION
#define FLUTTER_VERSION "development"
#endif

namespace {
HANDLE log_file = INVALID_HANDLE_VALUE;
std::wstring log_directory;
LPTOP_LEVEL_EXCEPTION_FILTER previous_filter = nullptr;
LONG recording_crash = 0;

// The file is opened before Flutter/plugins start. Fault handling only uses
// bounded stack buffers and Win32 writes; it does not allocate or use iostreams.
void WriteRecord(const char* message) {
  if (log_file == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME time;
  GetSystemTime(&time);
  char buffer[2048];
  const int length = _snprintf_s(
      buffer, sizeof(buffer), _TRUNCATE,
      "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ pid=%lu thread=%lu %s\r\n",
      time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute,
      time.wSecond, time.wMilliseconds, GetCurrentProcessId(),
      GetCurrentThreadId(), message);
  if (length <= 0) return;
  DWORD written;
  WriteFile(log_file, buffer, static_cast<DWORD>(length), &written, nullptr);
  FlushFileBuffers(log_file);
}

LONG WINAPI OnUnhandledException(EXCEPTION_POINTERS* exception) {
  if (InterlockedCompareExchange(&recording_crash, 1, 0) == 0) {
    const auto* record = exception->ExceptionRecord;
    HMODULE module = nullptr;
    wchar_t module_path[MAX_PATH] = {};
    char module_name[MAX_PATH * 3] = "unknown";
    unsigned long long offset = 0;
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                              GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                          reinterpret_cast<LPCWSTR>(record->ExceptionAddress),
                          &module)) {
      offset = reinterpret_cast<uintptr_t>(record->ExceptionAddress) -
               reinterpret_cast<uintptr_t>(module);
      if (GetModuleFileNameW(module, module_path, MAX_PATH) > 0) {
        const wchar_t* name = wcsrchr(module_path, L'\\');
        WideCharToMultiByte(CP_UTF8, 0, name ? name + 1 : module_path, -1,
                            module_name, sizeof(module_name), nullptr, nullptr);
      }
    }
    char message[1400];
    _snprintf_s(message, sizeof(message), _TRUNCATE,
                "unhandled_exception code=0x%08lX address=%p module=%s "
                "offset=0x%llX",
                record->ExceptionCode, record->ExceptionAddress, module_name,
                offset);
    WriteRecord(message);
  }
  // Preserve Windows crash reporting/termination; never resume a faulty thread.
  // https://learn.microsoft.com/windows/win32/api/errhandlingapi/nf-errhandlingapi-setunhandledexceptionfilter
  return previous_filter ? previous_filter(exception)
                         : EXCEPTION_CONTINUE_SEARCH;
}

void OnAbort(int) { WriteRecord("fatal_signal SIGABRT"); }

void CloseLog() {
  WriteRecord("normal_exit");
  if (log_file != INVALID_HANDLE_VALUE) CloseHandle(log_file);
  log_file = INVALID_HANDLE_VALUE;
}

void PruneLogs(const std::filesystem::path& directory) {
  std::error_code error;
  std::vector<std::filesystem::path> files;
  std::filesystem::directory_iterator entries(directory, error), end;
  for (; !error && entries != end; entries.increment(error)) {
    const auto& path = entries->path();
    const auto name = path.filename().wstring();
    if (entries->is_regular_file(error) && name.rfind(L"native-", 0) == 0 &&
        path.extension() == L".log") {
      files.push_back(path);
    }
  }
  std::sort(files.begin(), files.end());
  for (size_t i = 0; i + 10 < files.size(); ++i) {
    // An open log from another instance may be locked. Leave it alone.
    std::filesystem::remove(files[i], error);
  }
}
}  // namespace

std::wstring GetCrashLogDirectory() {
  if (!log_directory.empty()) return log_directory;
  PWSTR roaming = nullptr;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_RoamingAppData, 0, nullptr,
                                   &roaming))) {
    std::wstring directory = std::wstring(roaming) +
                             L"\\com.moonrailgun\\sillydraft\\logs";
    CoTaskMemFree(roaming);
    return directory;
  }
  wchar_t temp[MAX_PATH];
  const auto length = GetTempPathW(MAX_PATH, temp);
  if (length == 0 || length >= MAX_PATH) return L"";
  return std::wstring(temp) + L"SillyDraft\\logs";
}

bool InitializeCrashLogging(const std::wstring& directory) {
  if (log_file != INVALID_HANDLE_VALUE) return true;
  if (directory.empty()) return false;
  log_directory = directory;
  std::error_code error;
  std::filesystem::create_directories(directory, error);
  if (error) return false;
  SYSTEMTIME time;
  GetSystemTime(&time);
  wchar_t name[120];
  swprintf_s(name, L"native-%04u%02u%02uT%02u%02u%02u%03u-%lu.log",
             time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute,
             time.wSecond, time.wMilliseconds, GetCurrentProcessId());
  const auto path = std::filesystem::path(directory) / name;
  log_file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                         CREATE_NEW, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_WRITE_THROUGH,
                         nullptr);
  if (log_file == INVALID_HANDLE_VALUE) return false;
  WriteRecord("session_start version=" FLUTTER_VERSION);
  previous_filter = SetUnhandledExceptionFilter(OnUnhandledException);
  std::signal(SIGABRT, OnAbort);
  std::atexit(CloseLog);
  PruneLogs(directory);
  return true;
}

void RecordNativeError(const char* stage, DWORD code) {
  char message[512];
  _snprintf_s(message, sizeof(message), _TRUNCATE, "%s code=0x%08lX", stage,
              code);
  WriteRecord(message);
}

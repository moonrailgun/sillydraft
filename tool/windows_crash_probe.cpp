// Standalone probe: deliberately crashes only this temporary test process.
#include <windows.h>
#include <cstdlib>
#include <string>

#include "../windows/runner/crash_log.h"

int wmain(int argc, wchar_t** argv) {
  if (argc != 3) return 2;
  SetErrorMode(SEM_NOGPFAULTERRORBOX | SEM_FAILCRITICALERRORS);
  if (!InitializeCrashLogging(argv[1])) return 3;
  if (std::wstring(argv[2]) == L"exception") {
    volatile int* invalid = nullptr;
    *invalid = 1;
    return 4;
  }
  if (std::wstring(argv[2]) == L"abort") std::abort();
  RecordNativeError("probe", ERROR_ACCESS_DENIED);
  return 0;
}

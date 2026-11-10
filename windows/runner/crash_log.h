#ifndef RUNNER_CRASH_LOG_H_
#define RUNNER_CRASH_LOG_H_

#include <windows.h>

#include <string>

// Matches path_provider's company/product application support directory.
std::wstring GetCrashLogDirectory();
bool InitializeCrashLogging(const std::wstring& directory);
void RecordNativeError(const char* stage, DWORD code);

#endif  // RUNNER_CRASH_LOG_H_

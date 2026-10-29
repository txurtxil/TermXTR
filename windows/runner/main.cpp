#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <exception>
#include <fstream>
#include <ctime>

#include "flutter_window.h"
#include "utils.h"

// v2.17.12: log de arranque en C++ (log\cpp_startup.log). El log de
// Dart (TermXTR.log) no llega a crearse si el proceso muere pronto; este
// cubre desde la primera linea de wWinMain y dice donde se paro.
static std::wstring ExeDirW() {
  wchar_t buf[MAX_PATH];
  GetModuleFileNameW(nullptr, buf, MAX_PATH);
  std::wstring p(buf);
  auto pos = p.find_last_of(L"\\/");
  if (pos != std::wstring::npos) p.resize(pos);
  return p;
}

static std::string W2A(const std::wstring& w) {
  if (w.empty()) return std::string();
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(),
                              nullptr, 0, nullptr, nullptr);
  std::string out(static_cast<size_t>(n), '\0');
  if (n > 0) {
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &out[0], n,
                        nullptr, nullptr);
  }
  return out;
}

static void CppLog(const std::string& msg) {
  std::wstring dir = ExeDirW() + L"\\log";
  CreateDirectoryW(dir.c_str(), nullptr);
  std::ofstream f(dir + L"\\cpp_startup.log", std::ios::app);
  if (!f) return;
  std::time_t t = std::time(nullptr);
  char tb[32];
  std::tm tmv{};
  if (localtime_s(&tmv, &t) == 0) {
    std::strftime(tb, sizeof(tb), "%Y-%m-%d %H:%M:%S", &tmv);
    f << "[" << tb << "] " << msg << "\n";
  } else {
    f << msg << "\n";
  }
}

static std::string WinErr(DWORD e) {
  wchar_t* m = nullptr;
  FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                     FORMAT_MESSAGE_IGNORE_INSERTS,
                 nullptr, e, MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                 (LPWSTR)&m, 0, nullptr);
  std::string r = m ? W2A(std::wstring(m)) : "error desconocido";
  while (!r.empty() && (r.back() == '\r' || r.back() == '\n')) r.pop_back();
  if (m) LocalFree(m);
  return r;
}

static void CppLogFiles() {
  std::wstring dir = ExeDirW() + L"\\";
  const wchar_t* kFiles[] = {
      L"flutter_windows.dll", L"file_selector_windows_plugin.dll",
      L"flutter_secure_storage_windows_plugin.dll", L"share_plus_plugin.dll",
      L"url_launcher_windows_plugin.dll", L"flutter_pty.dll",
      L"dartjni.dll"};
  for (const wchar_t* fn : kFiles) {
    DWORD a = GetFileAttributesW((dir + fn).c_str());
    CppLog(a == INVALID_FILE_ATTRIBUTES ? std::string("FALTA  ") + W2A(fn)
                                        : std::string("ok     ") + W2A(fn));
  }
  DWORD d = GetFileAttributesW((dir + L"data").c_str());
  CppLog((d != INVALID_FILE_ATTRIBUTES && (d & FILE_ATTRIBUTE_DIRECTORY))
             ? "ok     data\\"
             : "FALTA  data\\");
}


int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  CppLog("=== wWinMain inicio (v2.17.12) ===");
  {
    wchar_t cwd[MAX_PATH];
    if (GetCurrentDirectoryW(MAX_PATH, cwd)) {
      CppLog(std::string("cwd: ") + W2A(std::wstring(cwd)));
    }
  }
  CppLog(std::string("exe dir: ") + W2A(ExeDirW()));
  CppLogFiles();
  // v2.17.1/v2.17.9: los DLL (flutter_windows + plugins, delay-load,
  // ver CMakeLists) se empaquetan en lib/; el runtime VC vive en la
  // raiz (no es delay-loadable). Hay que registrar lib/ ANTES de que el
  // delay-load lo resuelva (primer uso de cada DLL, dentro de wWinMain).
  SetDefaultDllDirectories(LOAD_LIBRARY_SEARCH_APPLICATION_DIR |
                           LOAD_LIBRARY_SEARCH_USER_DIRS);
  {
    wchar_t exe_path[MAX_PATH];
    GetModuleFileNameW(nullptr, exe_path, MAX_PATH);
    if (wchar_t *p = wcsrchr(exe_path, L'\\')) *p = L'\0';
    std::wstring lib_dir = std::wstring(exe_path) + L"\\lib";
    DLL_DIRECTORY_COOKIE lib_cookie = AddDllDirectory(lib_dir.c_str());
    if (lib_cookie) {
      CppLog("AddDllDirectory(lib) OK");
    } else {
      CppLog("AddDllDirectory(lib) FALLO: " + WinErr(GetLastError()));
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  CppLog("antes de DartProject (primer delay-load: flutter_windows.dll)");
  flutter::DartProject project(L"data");
  CppLog("DartProject creado");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  try {
  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  CppLog("antes de window.Create (motor + registro de plugins)");
  if (!window.Create(L"linux_container", origin, size)) {
    CppLog("window.Create FALSO -> MessageBox + EXIT_FAILURE");
    // v2.17.10: antes era una salida silenciosa (EXIT_FAILURE sin
    // ventana ni dialogo). Ahora se dice la causa probable.
    ::MessageBoxW(nullptr,
        L"No se pudo crear la ventana Flutter.\n"
        L"Comprueba que todos los DLL estan junto al exe\n"
        L"y que data\\ existe (ver log\\cpp_startup.log).",
        L"TermXTR", MB_ICONERROR | MB_OK);
    return EXIT_FAILURE;
  }
  CppLog("window.Create OK");
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  CppLog("bucle de mensajes terminado");
  ::CoUninitialize();
  } catch (const std::exception& e) {
    // v2.17.10: una excepcion (p.ej. registro de plugins) mataba el
    // proceso con std::terminate y SIN mensaje alguno. Ahora la causa
    // se ve. Cierra el catch ANTES del return final.
    CppLog(std::string("EXCEPCION: ") + e.what());
    ::MessageBoxA(nullptr, e.what(), "TermXTR - excepcion",
                  MB_ICONERROR | MB_OK);
    return EXIT_FAILURE;
  }
  return EXIT_SUCCESS;
}

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <exception>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
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
    AddDllDirectory(lib_dir.c_str());
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  try {
  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"linux_container", origin, size)) {
    // v2.17.10: antes era una salida silenciosa (EXIT_FAILURE sin
    // ventana ni dialogo). Ahora se dice la causa probable.
    ::MessageBoxW(nullptr,
        L"No se pudo crear la ventana Flutter.\n"
        L"Comprueba que lib\\ tiene los DLL y data\\ es completo.",
        L"TermXTR", MB_ICONERROR | MB_OK);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  } catch (const std::exception& e) {
    // v2.17.10: una excepcion (p.ej. registro de plugins) mataba el
    // proceso con std::terminate y SIN mensaje alguno. Ahora la causa
    // se ve. Cierra el catch ANTES del return final.
    ::MessageBoxA(nullptr, e.what(), "TermXTR - excepcion",
                  MB_ICONERROR | MB_OK);
    return EXIT_FAILURE;
  }
  return EXIT_SUCCESS;
}

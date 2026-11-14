#include <webview/webview.h>
#include <json.hpp>
#include <iostream>
#include <string>

int main(int argc, char **argv) {
  if (argc == 2 && std::string(argv[1]) == "--negative") {
    HMODULE loader = LoadLibraryW(L"WebView2Loader.dll");
    if (!loader) { std::cerr << "NEGATIVE_FAIL loader unavailable\n"; return 2; }
    using Function = HRESULT (WINAPI *)(PCWSTR, LPWSTR *);
    auto function = reinterpret_cast<Function>(GetProcAddress(loader, "GetAvailableCoreWebView2BrowserVersionString"));
    LPWSTR result = nullptr;
    HRESULT hr = function ? function(nullptr, &result) : E_FAIL;
    bool passed = hr == E_ACCESSDENIED && result == nullptr;
    CoTaskMemFree(result);
    FreeLibrary(loader);
    std::cout << (passed ? "NEGATIVE_PASS unauthorized activation rejected\n" : "NEGATIVE_FAIL unauthorized activation accepted\n") << std::flush;
    return passed ? 0 : 1;
  }
  try {
    bool passed = false;
    webview::webview window(false, nullptr);
    window.set_title("WebKit bridge probe");
    window.set_size(720, 460, WEBVIEW_HINT_NONE);
    auto backendRoot = static_cast<HWND>(window.window().value());
    ShowWindow(backendRoot, SW_SHOW);
    SetWindowPos(backendRoot,nullptr,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOZORDER|SWP_SHOWWINDOW);
    window.init("window.__bridgeInjected = 'čeština ☃';");
    window.bind("KcdMp_probe", [](const std::string &request) {
      auto args = nlohmann::json::parse(request);
      if (!args.is_array() || args.size() != 1) throw std::runtime_error("Wrong arguments");
      const auto &value = args[0];
      bool verified = value.is_object() && value.value("text","") == "čeština \" ☃"
          && value["number"] == 42 && value["enabled"] == true
          && value["nested"] == nlohmann::json::array({nullptr,"back\\slash"});
      return nlohmann::json({{"echo", value}, {"backend", "Windows native handler"}, {"requestVerified",verified}}).dump();
    });
    window.bind("KcdMp_test_done", [&passed, &window, backendRoot](const std::string &request) {
      auto args = nlohmann::json::parse(request);
      bool backendHidden = !IsWindowVisible(backendRoot) && (GetWindowLongPtrW(backendRoot,GWL_EXSTYLE) & WS_EX_TOOLWINDOW);
      passed = args.is_array() && args.size() == 1 && args[0] == true && backendHidden;
      std::cout << "BACKEND_WINDOW " << (backendHidden?"hidden":"visible") << '\n';
      std::cout << (passed ? "PROBE_PASS native-to-JS-to-Windows-to-JS Unicode RPC\n" : "PROBE_FAIL JavaScript assertions\n") << std::flush;
      window.terminate();
      return "null";
    });
    window.set_html(R"HTML(<!doctype html><html><head><meta charset="utf-8"><title>Bridge test</title>
      <style>body{font:18px system-ui;background:#f7f5ef;color:#29251f;padding:44px}h1{font-size:30px}pre{white-space:pre-wrap}#status{font-weight:600}</style></head>
      <body><h1>WebKit bridge probe</h1><p id="status">Testing native bridge…</p><pre id="result"></pre>
      <script>(async()=>{
        try {
          const input={text:'čeština " ☃',number:42,enabled:true,nested:[null,'back\\slash']};
          const answer=await KcdMp_probe(input);
          const checks={documentScript:window.__bridgeInjected==='čeština ☃',
            nativeRequest:answer.requestVerified===true,
            unicode:answer.echo.text===input.text,
            number:answer.echo.number===42,
            boolean:answer.echo.enabled===true,
            array:Array.isArray(answer.echo.nested)&&answer.echo.nested.length===2&&answer.echo.nested[0]===null&&answer.echo.nested[1]===input.nested[1],
            backend:answer.backend==='Windows native handler'};
          const ok=Object.values(checks).every(value=>value===true);
          document.getElementById('status').textContent=ok?'Bridge ready':'Bridge assertions failed';
          document.getElementById('result').textContent=JSON.stringify({checks,answer},null,2);
          await KcdMp_test_done(ok);
        } catch(error) {
          document.getElementById('status').textContent='Bridge failed';
          document.getElementById('result').textContent=String(error);
          if(window.KcdMp_test_done) await KcdMp_test_done(false);
        }
      })();</script></body></html>)HTML");
    window.run();
    return passed ? 0 : 1;
  } catch (const std::exception &error) {
    std::cerr << "PROBE_FAIL " << error.what() << '\n' << std::flush;
    return 2;
  }
}

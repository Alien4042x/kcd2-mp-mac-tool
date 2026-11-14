#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <commctrl.h>
#include <objbase.h>
#include <WebView2.h>
#include <json.hpp>
#include <atomic>
#include <functional>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using json = nlohmann::json;
static constexpr uint32_t maxFrame = 8 * 1024 * 1024;
static constexpr UINT dispatchMessage = WM_APP + 41;
static HANDLE traceFile = INVALID_HANDLE_VALUE;
static std::mutex traceMutex;

static std::wstring env(const wchar_t *name) {
  DWORD size = GetEnvironmentVariableW(name, nullptr, 0);
  if (!size || size > 32768) return {};
  std::wstring result(size, L'\0');
  DWORD written = GetEnvironmentVariableW(name, result.data(), size);
  if (!written || written >= size) return {};
  result.resize(written);
  return result;
}
static std::string utf8(const std::wstring &value) {
  if (value.empty()) return {};
  int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  if (!count) throw std::runtime_error("Invalid UTF-16");
  std::string out(count, '\0');
  WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), out.data(), count, nullptr, nullptr);
  return out;
}
static std::wstring wide(const std::string &value) {
  if (value.empty()) return {};
  int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), nullptr, 0);
  if (!count) throw std::runtime_error("Invalid UTF-8");
  std::wstring out(count, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
      static_cast<int>(value.size()), out.data(), count);
  return out;
}
static void trace(const std::string &message) {
  std::lock_guard<std::mutex> lock(traceMutex);
  if (traceFile == INVALID_HANDLE_VALUE) return;
  std::string line = message + "\r\n";
  DWORD written{};
  WriteFile(traceFile, line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
  FlushFileBuffers(traceFile);
}
static HRESULT unsupported(const char *method) {
  trace(std::string("UNSUPPORTED ") + method);
  return E_NOTIMPL;
}
static HRESULT stringResult(const std::wstring &value, LPWSTR *out) {
  if (!out) return E_POINTER;
  *out = static_cast<LPWSTR>(CoTaskMemAlloc((value.size() + 1) * sizeof(wchar_t)));
  if (!*out) return E_OUTOFMEMORY;
  memcpy(*out, value.c_str(), (value.size() + 1) * sizeof(wchar_t));
  return S_OK;
}
template<class T> static const IID &iid();
#define MAP_IID(T) template<> const IID &iid<T>() { return IID_##T; }
MAP_IID(ICoreWebView2)
MAP_IID(ICoreWebView2Controller)
MAP_IID(ICoreWebView2Environment)
MAP_IID(ICoreWebView2Settings)
MAP_IID(ICoreWebView2WebMessageReceivedEventArgs)
MAP_IID(ICoreWebView2NavigationCompletedEventArgs)
template<class T> class RefCounted : public T {
  std::atomic<ULONG> refs{1};
public:
  virtual ~RefCounted() = default;
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void **out) override {
    if (!out) return E_POINTER;
    *out = nullptr;
    if (IsEqualIID(id, IID_IUnknown) || IsEqualIID(id, iid<T>())) {
      *out = static_cast<T *>(this); AddRef(); return S_OK;
    }
    wchar_t name[40]{};
    if (StringFromGUID2(id, name, 40)) trace("UNSUPPORTED_INTERFACE " + utf8(name));
    return E_NOINTERFACE;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
  ULONG STDMETHODCALLTYPE Release() override {
    ULONG left = --refs; if (!left) delete this; return left;
  }
};
#include "stubs.hpp"

class Core;
struct Session {
  SOCKET socket = INVALID_SOCKET;
  HWND dispatcher = nullptr;
  HWND parent = nullptr;
  HWND backendRoot = nullptr;
  LONG_PTR originalRootStyle = 0;
  Core *core = nullptr;
  std::atomic<bool> stopping{false};
  std::thread reader;
  std::mutex sendMutex;
  std::function<void(const json &)> onEvent;
  static LRESULT CALLBACK backendProc(HWND window, UINT message, WPARAM wp, LPARAM lp, UINT_PTR id, DWORD_PTR data) {
    auto *self = reinterpret_cast<Session *>(data);
    if (message == WM_WINDOWPOSCHANGING && lp) {
      auto *position = reinterpret_cast<WINDOWPOS *>(lp);
      position->flags &= ~SWP_SHOWWINDOW;
      position->flags |= SWP_HIDEWINDOW;
    } else if (message == WM_SHOWWINDOW && wp) {
      self->post([self] { if (self->backendRoot && IsWindow(self->backendRoot)) ShowWindow(self->backendRoot, SW_HIDE); });
    } else if (message == WM_NCDESTROY) {
      RemoveWindowSubclass(window, backendProc, id);
      if (self->backendRoot == window) self->backendRoot = nullptr;
    }
    return DefSubclassProc(window, message, wp, lp);
  }
  bool hideBackend(HWND child) {
    backendRoot = GetAncestor(child, GA_ROOT);
    if (!backendRoot) return false;
    originalRootStyle = GetWindowLongPtrW(backendRoot, GWL_EXSTYLE);
    if (!SetWindowSubclass(backendRoot, backendProc, 0x4b43444d, reinterpret_cast<DWORD_PTR>(this))) return false;
    SetLastError(0);
    if (!SetWindowLongPtrW(backendRoot, GWL_EXSTYLE, (originalRootStyle | WS_EX_TOOLWINDOW) & ~WS_EX_APPWINDOW)
        && GetLastError() != ERROR_SUCCESS) {
      RemoveWindowSubclass(backendRoot, backendProc, 0x4b43444d); return false;
    }
    ShowWindow(backendRoot, SW_HIDE);
    SetWindowPos(backendRoot, nullptr, 0,0,0,0,SWP_NOMOVE|SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE|SWP_FRAMECHANGED|SWP_HIDEWINDOW);
    trace("Windows backend window hidden and excluded from taskbar");
    return true;
  }
  static LRESULT CALLBACK windowProc(HWND window, UINT message, WPARAM wp, LPARAM lp) {
    if (message == dispatchMessage) {
      auto *task = reinterpret_cast<std::function<void()> *>(lp);
      try { (*task)(); } catch (const std::exception &e) { trace(std::string("DISPATCH_ERROR ") + e.what()); }
      delete task;
      return 0;
    }
    return DefWindowProcW(window, message, wp, lp);
  }
  bool post(std::function<void()> task) {
    auto *allocated = new std::function<void()>(std::move(task));
    if (!dispatcher || !PostMessageW(dispatcher, dispatchMessage, 0, reinterpret_cast<LPARAM>(allocated))) {
      delete allocated; return false;
    }
    return true;
  }
  bool exact(char *buffer, size_t count, bool writing) {
    while (count) {
      int part = writing ? ::send(socket, buffer, static_cast<int>(count), 0)
                         : ::recv(socket, buffer, static_cast<int>(count), 0);
      if (part <= 0) return false;
      buffer += part; count -= part;
    }
    return true;
  }
  bool send(const json &message) {
    std::string payload = message.dump();
    if (payload.empty() || payload.size() > maxFrame) return false;
    std::lock_guard<std::mutex> lock(sendMutex);
    if (socket == INVALID_SOCKET || stopping) return false;
    uint32_t size = htonl(static_cast<uint32_t>(payload.size()));
    return exact(reinterpret_cast<char *>(&size), sizeof(size), true)
        && exact(payload.data(), payload.size(), true);
  }
  bool receive(json &message) {
    uint32_t size{};
    if (!exact(reinterpret_cast<char *>(&size), sizeof(size), false)) return false;
    size = ntohl(size);
    if (!size || size > maxFrame) return false;
    std::string payload(size, '\0');
    if (!exact(payload.data(), size, false)) return false;
    message = json::parse(payload, nullptr, false);
    return message.is_object() && message.contains("op") && message["op"].is_string();
  }
  HRESULT start() {
    const auto portText = env(L"KCDMP_WEBKIT_BRIDGE_PORT");
    const auto token = env(L"KCDMP_WEBKIT_BRIDGE_TOKEN");
    if (portText.empty() || token.size() != 64) return E_ACCESSDENIED;
    wchar_t *end{};
    unsigned long port = wcstoul(portText.c_str(), &end, 10);
    if (!end || *end || port == 0 || port > 65535) return E_INVALIDARG;
    auto path = env(L"KCDMP_WEBKIT_BRIDGE_TRACE");
    if (!path.empty()) traceFile = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ,
        nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    trace("bridge 0.1, protocol 1, AMD64");
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2,2), &data)) return E_FAIL;
    socket = ::socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (socket == INVALID_SOCKET) return E_FAIL;
    DWORD timeout = 5000;
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<char *>(&timeout), sizeof(timeout));
    setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, reinterpret_cast<char *>(&timeout), sizeof(timeout));
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(static_cast<uint16_t>(port));
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(socket, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == SOCKET_ERROR) return E_FAIL;
    json answer;
    if (!send({{"op","hello"},{"protocol",1},{"token",utf8(token)},{"pid",GetCurrentProcessId()}})
        || !receive(answer) || answer.value("op","") != "accepted" || answer.value("protocol",0) != 1) return E_ACCESSDENIED;
    timeout = 0;
    setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, reinterpret_cast<char *>(&timeout), sizeof(timeout));
    WNDCLASSW cls{};
    cls.lpfnWndProc = windowProc;
    cls.hInstance = GetModuleHandleW(nullptr);
    cls.lpszClassName = L"KCDMP_WebKit_Bridge_Dispatcher_1";
    if (!RegisterClassW(&cls) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return E_FAIL;
    dispatcher = CreateWindowW(cls.lpszClassName, L"", 0,0,0,0,0, HWND_MESSAGE, nullptr,cls.hInstance,nullptr);
    if (!dispatcher) return E_FAIL;
    reader = std::thread([this] {
      try {
        json message;
        while (!stopping && receive(message)) {
          auto copy = message;
          if (!post([this, copy] { if (onEvent) onEvent(copy); })) break;
        }
      } catch (const std::exception &e) { trace(std::string("READER_ERROR ") + e.what()); }
      if (!stopping) post([this] {
        trace("bridge disconnected");
        if (backendRoot && IsWindow(backendRoot)) PostMessageW(backendRoot, WM_CLOSE, 0, 0);
      });
    });
    trace("authenticated");
    return S_OK;
  }
  void stop() {
    if (stopping.exchange(true)) return;
    trace("stop: shutting down transport");
    if (socket != INVALID_SOCKET) shutdown(socket, SD_BOTH);
    if (reader.joinable()) reader.join();
    trace("stop: reader joined");
    if (socket != INVALID_SOCKET) { closesocket(socket); socket = INVALID_SOCKET; }
    if (backendRoot && IsWindow(backendRoot)) {
      RemoveWindowSubclass(backendRoot, backendProc, 0x4b43444d);
      SetWindowLongPtrW(backendRoot, GWL_EXSTYLE, originalRootStyle);
    }
    backendRoot = nullptr;
    if (dispatcher) {
      MSG message{};
      while (PeekMessageW(&message, dispatcher, dispatchMessage, dispatchMessage, PM_REMOVE))
        delete reinterpret_cast<std::function<void()> *>(message.lParam);
      DestroyWindow(dispatcher); dispatcher = nullptr;
    }
    WSACleanup();
    trace("stopped");
    if (traceFile != INVALID_HANDLE_VALUE) { CloseHandle(traceFile); traceFile = INVALID_HANDLE_VALUE; }
  }
};
static Session *session = nullptr;

class Settings final : public SettingsStub {
  std::map<std::string, BOOL> values;
public:
#define SETTING(Name, Default) \
  HRESULT STDMETHODCALLTYPE get_##Name(BOOL *out) override { if (!out) return E_POINTER; auto it=values.find(#Name); *out=it==values.end()?Default:it->second; return S_OK; } \
  HRESULT STDMETHODCALLTYPE put_##Name(BOOL value) override { values[#Name]=value; return S_OK; }
  SETTING(IsScriptEnabled, TRUE)
  SETTING(IsWebMessageEnabled, TRUE)
  SETTING(AreDefaultScriptDialogsEnabled, FALSE)
  SETTING(IsStatusBarEnabled, FALSE)
  SETTING(AreDevToolsEnabled, FALSE)
  SETTING(AreDefaultContextMenusEnabled, FALSE)
  SETTING(AreHostObjectsAllowed, FALSE)
  SETTING(IsZoomControlEnabled, TRUE)
  SETTING(IsBuiltInErrorPageEnabled, FALSE)
#undef SETTING
};
class MessageArgs final : public MessageArgsStub {
  std::wstring source, message;
public:
  MessageArgs(std::wstring source, std::wstring message):source(std::move(source)),message(std::move(message)){}
  HRESULT STDMETHODCALLTYPE get_Source(LPWSTR *out) override { return stringResult(source,out); }
  HRESULT STDMETHODCALLTYPE get_WebMessageAsJson(LPWSTR *out) override { return stringResult(wide(json(utf8(message)).dump()),out); }
  HRESULT STDMETHODCALLTYPE TryGetWebMessageAsString(LPWSTR *out) override { return stringResult(message,out); }
};
class NavigationArgs final : public NavigationArgsStub {
  BOOL success;
public:
  explicit NavigationArgs(bool success):success(success){}
  HRESULT STDMETHODCALLTYPE get_IsSuccess(BOOL *out) override { if(!out)return E_POINTER;*out=success;return S_OK; }
  HRESULT STDMETHODCALLTYPE get_WebErrorStatus(COREWEBVIEW2_WEB_ERROR_STATUS *out) override {
    if(!out)return E_POINTER;
    *out=success?COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN:COREWEBVIEW2_WEB_ERROR_STATUS_UNEXPECTED_ERROR;return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_NavigationId(UINT64 *out) override { if(!out)return E_POINTER;*out=1;return S_OK; }
};
class Core final : public CoreStub {
  Settings *settings = new Settings;
  std::wstring source;
  int64_t sequence = 0;
  std::map<int64_t, ICoreWebView2WebMessageReceivedEventHandler *> messages;
  std::map<int64_t, ICoreWebView2NavigationCompletedEventHandler *> navigations;
  std::map<int64_t, ICoreWebView2ExecuteScriptCompletedHandler *> scripts;
public:
  Core() {
    session->core=this;
    session->onEvent=[this](const json &packet) { event(packet); };
  }
  ~Core() override {
    session->onEvent=nullptr;session->core=nullptr;
    for(auto &[id,handler]:messages)handler->Release();
    for(auto &[id,handler]:navigations)handler->Release();
    for(auto &[id,handler]:scripts){handler->Invoke(E_ABORT,nullptr);handler->Release();}
    settings->Release();
  }
  void event(const json &packet) {
    std::string op=packet.value("op","");
    if(op=="message") {
      if(!packet.contains("data")||!packet["data"].is_string())return;
      auto *args=new MessageArgs(source,wide(packet["data"].get<std::string>()));
      auto handlers=messages;
      for(auto &[id,handler]:handlers)handler->AddRef();
      for(auto &[id,handler]:handlers){handler->Invoke(this,args);handler->Release();}
      args->Release();trace("web message delivered");
    } else if(op=="evaluated") {
      auto it=scripts.find(packet.value("id",int64_t(-1)));
      if(it!=scripts.end()) {
        auto *handler=it->second;scripts.erase(it);
        bool ok=packet.value("ok",false);
        auto result=wide(packet.value("result",std::string("null")));
        handler->Invoke(ok?S_OK:E_FAIL,result.c_str());handler->Release();
      }
    } else if(op=="navigated") {
      auto *args=new NavigationArgs(packet.value("ok",false));
      for(auto &[id,handler]:navigations)handler->Invoke(this,args);
      args->Release();trace(packet.value("ok",false)?"navigation completed":"navigation failed");
    } else if(op=="close") {
      trace("native close requested");
      if(session->backendRoot&&IsWindow(session->backendRoot))PostMessageW(session->backendRoot,WM_CLOSE,0,0);
    }
  }
  HRESULT STDMETHODCALLTYPE get_Settings(ICoreWebView2Settings **out) override { if(!out)return E_POINTER;*out=settings;settings->AddRef();return S_OK; }
  HRESULT STDMETHODCALLTYPE get_Source(LPWSTR *out) override { return stringResult(source,out); }
  HRESULT STDMETHODCALLTYPE Navigate(LPCWSTR uri) override {
    if(!uri)return E_INVALIDARG;
    source=uri;trace("Navigate");
    return session->send({{"op","navigate"},{"url",utf8(source)}})?S_OK:E_FAIL;
  }
  HRESULT STDMETHODCALLTYPE NavigateToString(LPCWSTR html) override {
    if(!html)return E_INVALIDARG;
    source=L"about:blank";trace("NavigateToString");
    return session->send({{"op","html"},{"html",utf8(html)}})?S_OK:E_FAIL;
  }
  HRESULT STDMETHODCALLTYPE AddScriptToExecuteOnDocumentCreated(LPCWSTR script, ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler *handler) override {
    if(!script)return E_INVALIDARG;
    auto id=++sequence;
    if(!session->send({{"op","init"},{"id",id},{"script",utf8(script)}}))return E_FAIL;
    trace("document script registered");
    if(handler){handler->AddRef();session->post([handler,id]{auto value=std::to_wstring(id);handler->Invoke(S_OK,value.c_str());handler->Release();});}
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE RemoveScriptToExecuteOnDocumentCreated(LPCWSTR id) override {
    if(!id)return E_INVALIDARG;
    return session->send({{"op","remove_init"},{"id",utf8(id)}})?S_OK:E_FAIL;
  }
  HRESULT STDMETHODCALLTYPE ExecuteScript(LPCWSTR script, ICoreWebView2ExecuteScriptCompletedHandler *handler) override {
    if(!script)return E_INVALIDARG;
    auto id=++sequence;
    if(handler){handler->AddRef();scripts[id]=handler;}
    if(!session->send({{"op","eval"},{"id",id},{"script",utf8(script)}})){
      if(handler){scripts.erase(id);handler->Release();}return E_FAIL;
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE add_WebMessageReceived(ICoreWebView2WebMessageReceivedEventHandler *handler, EventRegistrationToken *token) override {
    if(!handler||!token)return E_POINTER;
    token->value=++sequence;handler->AddRef();messages[token->value]=handler;return S_OK;
  }
  HRESULT STDMETHODCALLTYPE remove_WebMessageReceived(EventRegistrationToken token) override {
    auto it=messages.find(token.value);if(it!=messages.end()){it->second->Release();messages.erase(it);}return S_OK;
  }
  HRESULT STDMETHODCALLTYPE add_NavigationCompleted(ICoreWebView2NavigationCompletedEventHandler *handler, EventRegistrationToken *token) override {
    if(!handler||!token)return E_POINTER;
    token->value=++sequence;handler->AddRef();navigations[token->value]=handler;return S_OK;
  }
  HRESULT STDMETHODCALLTYPE remove_NavigationCompleted(EventRegistrationToken token) override {
    auto it=navigations.find(token.value);if(it!=navigations.end()){it->second->Release();navigations.erase(it);}return S_OK;
  }
  HRESULT STDMETHODCALLTYPE add_PermissionRequested(ICoreWebView2PermissionRequestedEventHandler *handler, EventRegistrationToken *token) override {
    if(!handler||!token)return E_POINTER;
    token->value=++sequence;return S_OK;
  }
  HRESULT STDMETHODCALLTYPE remove_PermissionRequested(EventRegistrationToken) override { return S_OK; }
};
class Controller final : public ControllerStub {
  Core *core = new Core;
  HWND parent;
  RECT bounds{0,0,1000,720};
  BOOL visible=FALSE;
  double zoom=1;
public:
  explicit Controller(HWND parent):parent(parent){session->parent=parent;}
  ~Controller() override { core->Release();session->stop(); }
  HRESULT STDMETHODCALLTYPE get_CoreWebView2(ICoreWebView2 **out) override {if(!out)return E_POINTER;*out=core;core->AddRef();return S_OK;}
  HRESULT STDMETHODCALLTYPE get_IsVisible(BOOL *out) override {if(!out)return E_POINTER;*out=visible;return S_OK;}
  HRESULT STDMETHODCALLTYPE put_IsVisible(BOOL value) override {
    visible=value;ShowWindow(GetAncestor(parent,GA_ROOT),SW_HIDE);
    return session->send({{"op","visible"},{"value",bool(value)}})?S_OK:E_FAIL;
  }
  HRESULT STDMETHODCALLTYPE get_Bounds(RECT *out) override {if(!out)return E_POINTER;*out=bounds;return S_OK;}
  HRESULT STDMETHODCALLTYPE put_Bounds(RECT value) override {
    bounds=value;return session->send({{"op","bounds"},{"width",value.right-value.left},{"height",value.bottom-value.top}})?S_OK:E_FAIL;
  }
  HRESULT STDMETHODCALLTYPE get_ZoomFactor(double *out) override {if(!out)return E_POINTER;*out=zoom;return S_OK;}
  HRESULT STDMETHODCALLTYPE put_ZoomFactor(double value) override {if(value<=0||value>5)return E_INVALIDARG;zoom=value;return S_OK;}
  HRESULT STDMETHODCALLTYPE SetBoundsAndZoomFactor(RECT value,double factor) override {auto hr=put_ZoomFactor(factor);return FAILED(hr)?hr:put_Bounds(value);}
  HRESULT STDMETHODCALLTYPE MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON) override {return session->send({{"op","focus"}})?S_OK:E_FAIL;}
  HRESULT STDMETHODCALLTYPE get_ParentWindow(HWND *out) override {if(!out)return E_POINTER;*out=parent;return S_OK;}
  HRESULT STDMETHODCALLTYPE put_ParentWindow(HWND value) override {parent=value;session->parent=value;return S_OK;}
  HRESULT STDMETHODCALLTYPE NotifyParentWindowPositionChanged() override {return S_OK;}
  HRESULT STDMETHODCALLTYPE Close() override {session->send({{"op","closed"}});session->stop();return S_OK;}
};
class Environment final : public EnvironmentStub {
  bool created=false;
public:
  HRESULT STDMETHODCALLTYPE CreateCoreWebView2Controller(HWND parent, ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *handler) override {
    if(!handler||!IsWindow(parent))return E_INVALIDARG;
    if(created)return E_UNEXPECTED;
    created=true;
    handler->AddRef();
    session->post([handler,parent]{
      if (!session->hideBackend(parent)) { handler->Invoke(E_FAIL,nullptr);handler->Release();return; }
      auto *controller=new Controller(parent);handler->Invoke(S_OK,controller);controller->Release();handler->Release();
    });
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_BrowserVersionString(LPWSTR *out) override {return stringResult(L"0.1.0.0",out);}
};
static bool allowedProcess() {
  if(env(L"KCDMP_WEBKIT_BRIDGE_ENABLED")!=L"1")return false;
  auto expected=env(L"KCDMP_WEBKIT_BRIDGE_EXPECTED_EXE");
  if(expected.empty())return false;
  wchar_t path[32768]{};
  DWORD count=GetModuleFileNameW(nullptr,path,32768);
  return count&&count<32768&&_wcsicmp(path,expected.c_str())==0;
}
extern "C" HRESULT __stdcall GetAvailableCoreWebView2BrowserVersionString(PCWSTR,LPWSTR *out) {
  if(out)*out=nullptr;
  if(!allowedProcess())return E_ACCESSDENIED;
  return stringResult(L"0.1.0.0",out);
}
extern "C" HRESULT __stdcall CreateCoreWebView2EnvironmentWithOptions(PCWSTR,PCWSTR,ICoreWebView2EnvironmentOptions*,ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *handler) {
  if(!allowedProcess())return E_ACCESSDENIED;
  if(!handler)return E_POINTER;
  if(session)return E_UNEXPECTED;
  try {
    session=new Session;
    auto hr=session->start();
    if(FAILED(hr)){session->stop();return hr;}
    handler->AddRef();
    session->post([handler]{auto *environment=new Environment;handler->Invoke(S_OK,environment);environment->Release();handler->Release();});
    return S_OK;
  } catch(const std::exception &e){trace(std::string("INITIALIZATION_ERROR ")+e.what());if(session)session->stop();return E_FAIL;}
}
extern "C" HRESULT __stdcall CompareBrowserVersions(PCWSTR a,PCWSTR b,int *out) {
  if(!a||!b||!out)return E_POINTER;
  *out=wcscmp(a,b);return S_OK;
}

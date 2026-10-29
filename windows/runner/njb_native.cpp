// Modulo nativo de NJB Rec:
//  * Captura del audio del sistema mediante WASAPI loopback -> archivo WAV.
//  * Enumeracion de monitores con coordenadas fisicas (para gdigrab/ddagrab).
#include "njb_native.h"

#include <windows.h>

#include <audioclient.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <atomic>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace {

const CLSID kClsidMMDeviceEnumerator = __uuidof(MMDeviceEnumerator);
const IID kIidIMMDeviceEnumerator = __uuidof(IMMDeviceEnumerator);
const IID kIidIAudioClient = __uuidof(IAudioClient);
const IID kIidIAudioCaptureClient = __uuidof(IAudioCaptureClient);
const IID kIidIAudioRenderClient = __uuidof(IAudioRenderClient);

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return L"";
  int len = ::MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring out(static_cast<size_t>(len), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &out[0], len);
  out.resize(static_cast<size_t>(len) - 1);
  return out;
}

std::string WideToUtf8(const std::wstring& s) {
  if (s.empty()) return "";
  int len = ::WideCharToMultiByte(CP_UTF8, 0, s.c_str(), -1, nullptr, 0,
                                  nullptr, nullptr);
  std::string out(static_cast<size_t>(len), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, s.c_str(), -1, &out[0], len, nullptr,
                        nullptr);
  out.resize(static_cast<size_t>(len) - 1);
  return out;
}

std::string HrToString(HRESULT hr) {
  char buf[64];
  std::snprintf(buf, sizeof(buf), "0x%08lX", static_cast<unsigned long>(hr));
  return std::string(buf);
}

// ---------------------------------------------------------------------------
// Escritor WAV minimo (soporta WAVEFORMATEXTENSIBLE / float).
// ---------------------------------------------------------------------------
class WavWriter {
 public:
  bool Open(const std::wstring& path, const WAVEFORMATEX* wfx) {
    if (_wfopen_s(&file_, path.c_str(), L"wb") != 0 || file_ == nullptr) {
      return false;
    }
    block_align_ = wfx->nBlockAlign;
    const uint32_t fmt_size =
        static_cast<uint32_t>(sizeof(WAVEFORMATEX) + wfx->cbSize);
    WriteTag("RIFF");
    WriteU32(0);  // tamano total, se completa al cerrar
    WriteTag("WAVE");
    WriteTag("fmt ");
    WriteU32(fmt_size);
    std::fwrite(wfx, 1, fmt_size, file_);
    if (fmt_size % 2 == 1) std::fputc(0, file_);
    WriteTag("data");
    data_size_pos_ = std::ftell(file_);
    WriteU32(0);
    data_start_ = std::ftell(file_);
    return true;
  }

  void WriteFrames(const BYTE* data, UINT32 frames) {
    if (!file_) return;
    const size_t bytes = static_cast<size_t>(frames) * block_align_;
    if (data == nullptr) {
      static const std::vector<BYTE> zeros(65536, 0);
      size_t left = bytes;
      while (left > 0) {
        size_t chunk = left < zeros.size() ? left : zeros.size();
        std::fwrite(zeros.data(), 1, chunk, file_);
        left -= chunk;
      }
    } else {
      std::fwrite(data, 1, bytes, file_);
    }
  }

  void Close() {
    if (!file_) return;
    long end = std::ftell(file_);
    uint32_t data_size = static_cast<uint32_t>(end - data_start_);
    std::fseek(file_, data_size_pos_, SEEK_SET);
    WriteU32(data_size);
    std::fseek(file_, 4, SEEK_SET);
    WriteU32(static_cast<uint32_t>(end - 8));
    std::fclose(file_);
    file_ = nullptr;
  }

  ~WavWriter() { Close(); }

 private:
  void WriteTag(const char* tag) { std::fwrite(tag, 1, 4, file_); }
  void WriteU32(uint32_t v) { std::fwrite(&v, 1, 4, file_); }

  FILE* file_ = nullptr;
  uint16_t block_align_ = 0;
  long data_size_pos_ = 0;
  long data_start_ = 0;
};

// ---------------------------------------------------------------------------
// Grabador loopback.
// ---------------------------------------------------------------------------
class LoopbackRecorder {
 public:
  bool Start(const std::wstring& path, std::string* error) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (running_.load()) {
      *error = "Ya hay una captura en curso";
      return false;
    }

    ComPtr<IMMDeviceEnumerator> enumerator;
    HRESULT hr = ::CoCreateInstance(kClsidMMDeviceEnumerator, nullptr,
                                    CLSCTX_ALL, kIidIMMDeviceEnumerator,
                                    &enumerator);
    if (FAILED(hr)) {
      *error = "No se pudo crear el enumerador de audio " + HrToString(hr);
      return false;
    }
    ComPtr<IMMDevice> device;
    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
    if (FAILED(hr)) {
      *error = "No hay dispositivo de salida de audio predeterminado " +
               HrToString(hr);
      return false;
    }

    // --- cliente de captura (loopback)
    hr = device->Activate(kIidIAudioClient, CLSCTX_ALL, nullptr,
                          &capture_client_);
    if (FAILED(hr)) {
      *error = "Activate(capture) " + HrToString(hr);
      return false;
    }
    WAVEFORMATEX* wfx = nullptr;
    hr = capture_client_->GetMixFormat(&wfx);
    if (FAILED(hr) || wfx == nullptr) {
      *error = "GetMixFormat " + HrToString(hr);
      return false;
    }
    const REFERENCE_TIME kBufferDuration = 10000000;  // 1 s
    hr = capture_client_->Initialize(AUDCLNT_SHAREMODE_SHARED,
                                     AUDCLNT_STREAMFLAGS_LOOPBACK,
                                     kBufferDuration, 0, wfx, nullptr);
    if (FAILED(hr)) {
      ::CoTaskMemFree(wfx);
      *error = "Initialize(loopback) " + HrToString(hr);
      return false;
    }
    hr = capture_client_->GetService(kIidIAudioCaptureClient, &capture_);
    if (FAILED(hr)) {
      ::CoTaskMemFree(wfx);
      *error = "GetService(capture) " + HrToString(hr);
      return false;
    }

    if (!writer_.Open(path, wfx)) {
      ::CoTaskMemFree(wfx);
      *error = "No se pudo crear el archivo WAV";
      return false;
    }
    ::CoTaskMemFree(wfx);

    // --- cliente de render en silencio: garantiza que el loopback entregue
    // paquetes aunque no suene nada (evita huecos/desincronizacion).
    hr = device->Activate(kIidIAudioClient, CLSCTX_ALL, nullptr,
                          &render_client_);
    if (SUCCEEDED(hr)) {
      WAVEFORMATEX* rwfx = nullptr;
      if (SUCCEEDED(render_client_->GetMixFormat(&rwfx)) && rwfx) {
        hr = render_client_->Initialize(AUDCLNT_SHAREMODE_SHARED, 0,
                                        kBufferDuration, 0, rwfx, nullptr);
        ::CoTaskMemFree(rwfx);
        if (SUCCEEDED(hr)) {
          render_client_->GetService(kIidIAudioRenderClient, &render_);
        }
      }
    }
    if (!render_) render_client_.Reset();

    running_.store(true);
    if (render_) {
      silence_thread_ = std::thread([this] { SilenceLoop(); });
    }
    capture_thread_ = std::thread([this] { CaptureLoop(); });
    return true;
  }

  void Stop() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!running_.load()) return;
    running_.store(false);
    if (capture_thread_.joinable()) capture_thread_.join();
    if (silence_thread_.joinable()) silence_thread_.join();
    writer_.Close();
    capture_.Reset();
    capture_client_.Reset();
    render_.Reset();
    render_client_.Reset();
  }

  bool IsRunning() const { return running_.load(); }

 private:
  void CaptureLoop() {
    ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    HRESULT hr = capture_client_->Start();
    if (FAILED(hr)) {
      running_.store(false);
      ::CoUninitialize();
      return;
    }
    while (running_.load()) {
      ::Sleep(10);
      UINT32 packet = 0;
      while (SUCCEEDED(capture_->GetNextPacketSize(&packet)) && packet > 0) {
        BYTE* data = nullptr;
        UINT32 frames = 0;
        DWORD flags = 0;
        hr = capture_->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
        if (FAILED(hr)) break;
        if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
          writer_.WriteFrames(nullptr, frames);
        } else {
          writer_.WriteFrames(data, frames);
        }
        capture_->ReleaseBuffer(frames);
      }
    }
    capture_client_->Stop();
    ::CoUninitialize();
  }

  void SilenceLoop() {
    ::CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    UINT32 buffer_frames = 0;
    if (FAILED(render_client_->GetBufferSize(&buffer_frames)) ||
        FAILED(render_client_->Start())) {
      ::CoUninitialize();
      return;
    }
    while (running_.load()) {
      UINT32 padding = 0;
      if (SUCCEEDED(render_client_->GetCurrentPadding(&padding))) {
        UINT32 available = buffer_frames - padding;
        if (available > 0) {
          BYTE* buf = nullptr;
          if (SUCCEEDED(render_->GetBuffer(available, &buf))) {
            render_->ReleaseBuffer(available, AUDCLNT_BUFFERFLAGS_SILENT);
          }
        }
      }
      ::Sleep(100);
    }
    render_client_->Stop();
    ::CoUninitialize();
  }

  std::mutex mutex_;
  std::atomic<bool> running_{false};
  std::thread capture_thread_;
  std::thread silence_thread_;
  ComPtr<IAudioClient> capture_client_;
  ComPtr<IAudioCaptureClient> capture_;
  ComPtr<IAudioClient> render_client_;
  ComPtr<IAudioRenderClient> render_;
  WavWriter writer_;
};

// ---------------------------------------------------------------------------
// Monitores.
// ---------------------------------------------------------------------------
BOOL CALLBACK MonitorEnumProc(HMONITOR monitor, HDC, LPRECT, LPARAM param) {
  auto* list = reinterpret_cast<flutter::EncodableList*>(param);
  MONITORINFOEXW info{};
  info.cbSize = sizeof(info);
  if (!::GetMonitorInfoW(monitor, &info)) return TRUE;
  flutter::EncodableMap m;
  m[flutter::EncodableValue("id")] =
      flutter::EncodableValue(static_cast<int64_t>(list->size()));
  m[flutter::EncodableValue("name")] =
      flutter::EncodableValue(WideToUtf8(info.szDevice));
  m[flutter::EncodableValue("x")] =
      flutter::EncodableValue(static_cast<int32_t>(info.rcMonitor.left));
  m[flutter::EncodableValue("y")] =
      flutter::EncodableValue(static_cast<int32_t>(info.rcMonitor.top));
  m[flutter::EncodableValue("width")] = flutter::EncodableValue(
      static_cast<int32_t>(info.rcMonitor.right - info.rcMonitor.left));
  m[flutter::EncodableValue("height")] = flutter::EncodableValue(
      static_cast<int32_t>(info.rcMonitor.bottom - info.rcMonitor.top));
  m[flutter::EncodableValue("primary")] =
      flutter::EncodableValue((info.dwFlags & MONITORINFOF_PRIMARY) != 0);
  list->push_back(flutter::EncodableValue(m));
  return TRUE;
}

flutter::EncodableValue ListMonitors() {
  flutter::EncodableList list;
  ::EnumDisplayMonitors(nullptr, nullptr, MonitorEnumProc,
                        reinterpret_cast<LPARAM>(&list));
  flutter::EncodableMap virt;
  virt[flutter::EncodableValue("x")] =
      flutter::EncodableValue(::GetSystemMetrics(SM_XVIRTUALSCREEN));
  virt[flutter::EncodableValue("y")] =
      flutter::EncodableValue(::GetSystemMetrics(SM_YVIRTUALSCREEN));
  virt[flutter::EncodableValue("width")] =
      flutter::EncodableValue(::GetSystemMetrics(SM_CXVIRTUALSCREEN));
  virt[flutter::EncodableValue("height")] =
      flutter::EncodableValue(::GetSystemMetrics(SM_CYVIRTUALSCREEN));
  flutter::EncodableMap out;
  out[flutter::EncodableValue("monitors")] = flutter::EncodableValue(list);
  out[flutter::EncodableValue("virtual")] = flutter::EncodableValue(virt);
  return flutter::EncodableValue(out);
}

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;
LoopbackRecorder g_recorder;

}  // namespace

void RegisterNjbNativeChannel(flutter::BinaryMessenger* messenger) {
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "njbrec/native", &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const std::string& method = call.method_name();
        if (method == "loopbackStart") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          std::string path;
          if (args) {
            auto it = args->find(flutter::EncodableValue("path"));
            if (it != args->end()) {
              if (const auto* s = std::get_if<std::string>(&it->second)) {
                path = *s;
              }
            }
          }
          if (path.empty()) {
            result->Error("bad_args", "Falta 'path'");
            return;
          }
          std::string error;
          if (g_recorder.Start(Utf8ToWide(path), &error)) {
            result->Success(flutter::EncodableValue(true));
          } else {
            result->Error("loopback_error", error);
          }
        } else if (method == "loopbackStop") {
          g_recorder.Stop();
          result->Success(flutter::EncodableValue(true));
        } else if (method == "loopbackIsRunning") {
          result->Success(flutter::EncodableValue(g_recorder.IsRunning()));
        } else if (method == "listMonitors") {
          result->Success(ListMonitors());
        } else {
          result->NotImplemented();
        }
      });
}

void ShutdownNjbNative() {
  g_recorder.Stop();
  g_channel.reset();
}

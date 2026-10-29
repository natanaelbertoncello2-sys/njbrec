#ifndef RUNNER_NJB_NATIVE_H_
#define RUNNER_NJB_NATIVE_H_

#include <flutter/binary_messenger.h>

// Registra el canal "njbrec/native" que expone:
//   - loopbackStart(path)  : graba el audio del sistema (WASAPI loopback) a WAV
//   - loopbackStop()       : detiene la grabacion
//   - loopbackIsRunning()  : estado
//   - listMonitors()       : lista de monitores con coordenadas fisicas
void RegisterNjbNativeChannel(flutter::BinaryMessenger* messenger);

// Libera recursos (detiene la captura si sigue activa).
void ShutdownNjbNative();

#endif  // RUNNER_NJB_NATIVE_H_

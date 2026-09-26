#ifndef ECH_HTTP_H
#define ECH_HTTP_H
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#ifdef _WIN32
#define EH_EXPORT __declspec(dllexport)
#else
#define EH_EXPORT __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
typedef struct EhClient EhClient;
typedef struct EhRequest EhRequest;
typedef struct EhOptions {
  const char *url;
  const char *method;
  const char *headers;
  const char *proxy;
  const char *ech_config;
  const char *connect_ip;
  const char *ca_pem;
  const uint8_t *body;
  size_t body_length;
  int64_t timeout_ms;
  int64_t connect_timeout_ms;
  int64_t max_response_bytes;
} EhOptions;
struct _Dart_CObject;
// NativeApi.postCObject, not an isolate-owned callback.
typedef bool (*EhPostCObject)(int64_t port, struct _Dart_CObject *message);
EH_EXPORT const char *eh_version(void);
EH_EXPORT EhClient *eh_client_create(void);
EH_EXPORT void eh_client_destroy(EhClient *client);
// Copies options; posts [type, code, ech_accepted, ech_retries, Uint8List].
// Types: 1=headers, 2=body, 3=complete, 4=error. Payloads are VM-owned copies.
EH_EXPORT EhRequest *eh_request_start(EhClient *, const EhOptions *, EhPostCObject, int64_t port);
// Releases consumed body bytes from the 256 KiB delivery budget.
EH_EXPORT void eh_request_acknowledge(EhRequest *, size_t bytes);
// Stops posting and cancels without joining; safe for NativeFinalizer.
EH_EXPORT void eh_request_destroy(EhRequest *);
#ifdef __cplusplus
}
#endif
#endif

#ifndef ECH_HTTP_H
#define ECH_HTTP_H
#include <stddef.h>
#include <stdint.h>
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
// type: 1=headers, 2=body chunk, 3=complete, 4=error.
typedef struct EhEvent {
  int32_t type;
  int32_t code;
  int32_t ech_accepted;
  int32_t ech_retries;
  size_t length;
  uint8_t *data;
} EhEvent;
EH_EXPORT const char *eh_version(void);
EH_EXPORT EhClient *eh_client_create(void);
EH_EXPORT void eh_client_destroy(EhClient *client);
// Options are copied before this returns. Never blocks for network I/O.
EH_EXPORT EhRequest *eh_request_start(EhClient *, const EhOptions *);
EH_EXPORT EhEvent *eh_request_poll(EhRequest *);
EH_EXPORT void eh_request_cancel(EhRequest *);
// Only call after receiving the terminal event (3 or 4).
EH_EXPORT void eh_request_destroy(EhRequest *);
EH_EXPORT void eh_event_destroy(EhEvent *);
#ifdef __cplusplus
}
#endif
#endif

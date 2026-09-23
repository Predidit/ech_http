// Optional device smoke test; link against a built ech_http shared library.
#include "ech_http.h"
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <thread>

int main(int argc, char **argv) {
  if (argc != 5) {
    std::fprintf(stderr, "usage: native_smoke <url> <http-proxy-or-empty> <ECHConfigList> <target-IP>\n");
    return 2;
  }
  EhOptions opts{};
  opts.url = argv[1]; opts.method = "GET"; opts.proxy = argv[2];
  opts.ech_config = argv[3]; opts.connect_ip = argv[4];
  opts.timeout_ms = 30000; opts.connect_timeout_ms = 10000;
  opts.max_response_bytes = 1024 * 1024;
  auto *client = eh_client_create();
  if (!client) return 3;
  auto *request = eh_request_start(client, &opts);
  if (!request) { eh_client_destroy(client); return 4; }
  std::printf("%s\n", eh_version());
  size_t bytes = 0;
  bool accepted = false, ok = false;
  for (;;) {
    auto *event = eh_request_poll(request);
    if (!event) { std::this_thread::sleep_for(std::chrono::milliseconds(10)); continue; }
    const int type = event->type;
    if (type == 1) {
      std::printf("HTTP %d, ECH accepted=%d, retries=%d\n", event->code, event->ech_accepted, event->ech_retries);
      accepted = event->ech_accepted && event->code == 200;
    } else if (type == 2) {
      bytes += event->length;
    } else if (type == 4) {
      std::fprintf(stderr, "error %d: %.*s\n", event->code, static_cast<int>(event->length), event->data);
    }
    eh_event_destroy(event);
    if (type == 3 || type == 4) { ok = type == 3; break; }
  }
  eh_request_destroy(request);
  eh_client_destroy(client);
  std::printf("body bytes=%zu\n", bytes);
  return ok && accepted ? 0 : 1;
}

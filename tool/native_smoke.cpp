// Standalone smoke test: link ech_http and include the Dart SDK headers.
#include "ech_http.h"
#include <dart_native_api.h>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <mutex>
#include <utility>
#include <vector>

namespace {
struct Event {
  int type, code, accepted, retries;
  std::vector<uint8_t> data;
};
std::mutex mutex;
std::condition_variable ready;
std::deque<Event> events;
bool post(int64_t, Dart_CObject *message) {
  try {
    auto **v = message->value.as_array.values;
    const auto &data = v[4]->value.as_typed_data;
    Event event{v[0]->value.as_int32, v[1]->value.as_int32,
                v[2]->value.as_int32, v[3]->value.as_int32, {}};
    if (data.length) event.data.assign(data.values, data.values + data.length);
    std::lock_guard<std::mutex> lock(mutex);
    events.push_back(std::move(event));
    ready.notify_one();
    return true;
  } catch (...) { return false; }
}
}

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
  auto *request = eh_request_start(client, &opts, post, 1);
  if (!request) { eh_client_destroy(client); return 4; }
  std::printf("%s\n", eh_version());
  size_t bytes = 0;
  bool accepted = false, ok = false;
  for (;;) {
    std::unique_lock<std::mutex> lock(mutex);
    ready.wait(lock, [] { return !events.empty(); });
    auto event = std::move(events.front());
    events.pop_front();
    lock.unlock();
    const int type = event.type;
    if (type == 1) {
      std::printf("HTTP %d, ECH accepted=%d, retries=%d\n", event.code, event.accepted, event.retries);
      accepted = event.accepted && event.code == 200;
    } else if (type == 2) {
      bytes += event.data.size();
      eh_request_acknowledge(request, event.data.size());
    } else if (type == 4) {
      std::fprintf(stderr, "error %d: %.*s\n", event.code, static_cast<int>(event.data.size()), event.data.data());
    }
    if (type == 3 || type == 4) { ok = type == 3; break; }
  }
  eh_request_destroy(request);
  eh_client_destroy(client);
  std::printf("body bytes=%zu\n", bytes);
  return ok && accepted ? 0 : 1;
}

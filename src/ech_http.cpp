#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#endif
#include "ech_http.h"
#include "ca_bundle.h"
#include "gzip_decoder.h"
#include <dart_native_api.h>
#include <curl/curl.h>
#include <openssl/err.h>
#include <openssl/bytestring.h>
#include <openssl/evp.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <stdexcept>
#include <thread>
#include <utility>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;
constexpr size_t kBodyBufferLimit = 256 * 1024;
constexpr size_t kHeaderLimit = 128 * 1024;
std::once_flag curl_init_flag;
CURLcode curl_init_result = CURLE_FAILED_INIT;
std::string text(const char *s) { return s ? s : ""; }

template <typename T> void set_option(CURL *easy, CURLoption option, T value) {
  const auto result = curl_easy_setopt(easy, option, value);
  if (result != CURLE_OK) throw std::runtime_error(curl_easy_strerror(result));
}

// BoringSSL deliberately ignores valid but unsupported ECHConfigs. A required
// ECH client must reject those before it can emit a plaintext ClientHello.
bool supports_ech(const std::string &encoded) {
  std::vector<uint8_t> decoded(encoded.size());
  size_t length = 0;
  if (!EVP_DecodeBase64(decoded.data(), &length, decoded.size(), reinterpret_cast<const uint8_t *>(encoded.data()), encoded.size())) return false;
  CBS input, list;
  CBS_init(&input, decoded.data(), length);
  if (!CBS_get_u16_length_prefixed(&input, &list) || CBS_len(&input)) return false;
  bool found = false;
  while (CBS_len(&list)) {
    uint16_t version, kem;
    uint8_t id, padding;
    CBS contents, key, suites, name, extensions;
    if (!CBS_get_u16(&list, &version) || !CBS_get_u16_length_prefixed(&list, &contents)) return false;
    if (version != 0xfe0d) continue;
    if (!CBS_get_u8(&contents, &id) || !CBS_get_u16(&contents, &kem) || !CBS_get_u16_length_prefixed(&contents, &key) ||
        !CBS_get_u16_length_prefixed(&contents, &suites) || !CBS_get_u8(&contents, &padding) ||
        !CBS_get_u8_length_prefixed(&contents, &name) || !CBS_get_u16_length_prefixed(&contents, &extensions) || CBS_len(&contents)) return false;
    bool cipher = false, mandatory = false, valid_name = CBS_len(&name) > 0 && CBS_len(&name) <= 253;
    while (CBS_len(&suites)) {
      uint16_t kdf, aead;
      if (!CBS_get_u16(&suites, &kdf) || !CBS_get_u16(&suites, &aead)) return false;
      if (kdf == 1 && aead >= 1 && aead <= 3) cipher = true;
    }
    while (CBS_len(&extensions)) {
      uint16_t type; CBS body;
      if (!CBS_get_u16(&extensions, &type) || !CBS_get_u16_length_prefixed(&extensions, &body)) return false;
      mandatory |= (type & 0x8000) != 0;
    }
    size_t label_size = 0;
    bool label_end_alnum = false, all_numeric = true;
    for (size_t i = 0; i < CBS_len(&name); ++i) {
      const auto c = CBS_data(&name)[i];
      const bool digit = c >= '0' && c <= '9';
      const bool alnum = digit || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
      if (c == '.') { valid_name &= label_size > 0 && label_end_alnum; label_size = 0; label_end_alnum = false; }
      else { valid_name &= alnum || (c == '-' && label_size > 0); valid_name &= ++label_size <= 63; label_end_alnum = alnum; }
      if (!digit && c != '.') all_numeric = false;
    }
    valid_name &= label_size > 0 && label_end_alnum && !all_numeric;
    found |= kem == 0x20 && CBS_len(&key) == 32 && cipher && valid_name && !mandatory;
  }
  return found;
}

struct Pool {
  std::mutex mutex;
  std::vector<std::pair<std::string, CURL *>> idle;
  ~Pool() { for (auto &entry : idle) curl_easy_cleanup(entry.second); }
  CURL *take(const std::string &key) {
    std::lock_guard<std::mutex> lock(mutex);
    for (auto it = idle.begin(); it != idle.end(); ++it) {
      if (it->first == key) { auto *h = it->second; idle.erase(it); curl_easy_reset(h); return h; }
    }
    return curl_easy_init();
  }
  void put(const std::string &key, CURL *h) {
    std::lock_guard<std::mutex> lock(mutex);
    if (idle.size() < 8) idle.emplace_back(key, h);
    else curl_easy_cleanup(h);
  }
};

struct TlsState {
  std::string hostname;
  bool require_ech = false;
  bool hostname_verified = false;
  std::string retry_config;
};

void tls_state_free(void *, void *ptr, CRYPTO_EX_DATA *, int, long, void *) {
  delete static_cast<std::shared_ptr<TlsState> *>(ptr);
}
int tls_state_index() {
  static const int index = SSL_CTX_get_ex_new_index(0, nullptr, nullptr, nullptr, tls_state_free);
  return index;
}
TlsState *tls_state(const SSL *ssl) {
  auto *value = static_cast<std::shared_ptr<TlsState> *>(SSL_CTX_get_ex_data(SSL_get_SSL_CTX(ssl), tls_state_index()));
  return value ? value->get() : nullptr;
}

int verify_certificate(int verified, X509_STORE_CTX *ctx) noexcept {
  if (!verified) return 0;
  if (X509_STORE_CTX_get_error_depth(ctx) != 0) return 1;
  auto *ssl = static_cast<SSL *>(X509_STORE_CTX_get_ex_data(ctx, SSL_get_ex_data_X509_STORE_CTX_idx()));
  auto *state = ssl ? tls_state(ssl) : nullptr;
  if (!state) return 0;
  try {
    const char *override_name = nullptr;
    size_t override_length = 0;
    SSL_get0_ech_name_override(ssl, &override_name, &override_length);
    const std::string name = override_length ? std::string(override_name, override_length) : state->hostname;
    X509 *cert = X509_STORE_CTX_get_current_cert(ctx);
    const bool matches = X509_check_host(cert, name.c_str(), name.size(), X509_CHECK_FLAG_NO_PARTIAL_WILDCARDS, nullptr) == 1 || X509_check_ip_asc(cert, name.c_str(), 0) == 1;
    state->hostname_verified = matches;
    if (!matches) X509_STORE_CTX_set_error(ctx, X509_V_ERR_HOSTNAME_MISMATCH);
    return matches ? 1 : 0;
  } catch (...) { return 0; }
}

void handshake_info(const SSL *ssl, int where, int result) noexcept {
  auto *state = tls_state(ssl);
  if (!state) return;
  if (where & SSL_CB_HANDSHAKE_START) {
    // BoringSSL invokes START before ECH selection and ClientHello construction.
    SSL_set_reject_unusable_ech_config(const_cast<SSL *>(ssl), state->require_ech);
    return;
  }
  if (!state->hostname_verified || !(where & SSL_CB_EXIT) || result > 0) return;
  const auto error = ERR_peek_last_error();
  if (ERR_GET_LIB(error) != ERR_LIB_SSL || ERR_GET_REASON(error) != SSL_R_ECH_REJECTED) return;
  try {
    const uint8_t *bytes = nullptr;
    size_t length = 0;
    SSL_get0_ech_retry_configs(ssl, &bytes, &length);
    if (!bytes || !length || length > 65535) return;
    size_t encoded_length = 0;
    if (!EVP_EncodedLength(&encoded_length, length)) return;
    std::string encoded(encoded_length, '\0');
    const size_t n = EVP_EncodeBlock(reinterpret_cast<uint8_t *>(&encoded[0]), bytes, length);
    encoded.resize(n);
    state->retry_config = std::move(encoded);
  } catch (...) { /* Fail closed: no retry if copying the config fails. */ }
}

std::vector<std::string> lines(const std::string &s) {
  std::vector<std::string> result;
  size_t pos = 0;
  while (pos < s.size()) {
    auto end = s.find('\n', pos);
    auto line = s.substr(pos, end == std::string::npos ? end : end - pos);
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (!line.empty()) result.push_back(std::move(line));
    if (end == std::string::npos) break;
    pos = end + 1;
  }
  return result;
}

std::string content_encoding(const std::string &block) {
  std::string value;
  bool found = false;
  for (const auto &line : lines(block)) {
    const auto colon = line.find(':');
    if (colon == std::string::npos) continue;
    auto name = line.substr(0, colon);
    for (auto &c : name) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    if (name != "content-encoding") continue;
    const auto start = line.find_first_not_of(" \t", colon + 1);
    const auto end = line.find_last_not_of(" \t");
    if (found) value += ", ";
    if (start != std::string::npos) value += line.substr(start, end - start + 1);
    found = true;
  }
  return value;
}
} // namespace

struct EhClient { std::shared_ptr<Pool> pool = std::make_shared<Pool>(); };

namespace {
struct RequestState {
  std::shared_ptr<Pool> pool;
  std::string url, method, headers, proxy, config, ip, ca, body, hostname, port;
  int64_t timeout_ms, connect_timeout_ms, max_bytes;
  std::atomic<bool> cancelled{false};
  std::mutex mutex;
  std::condition_variable room;
  const EhPostCObject post;
  const int64_t event_port;
  size_t pending_bytes = 0, received_bytes = 0;
  std::string header_block, failure;
  bool in_header_block = false, sent_headers = false;
  const bool auto_uncompress;
  bool decode_gzip = false, decode_error = false;
  GzipDecoder decoder;
  int retries = 0, ech_accepted = 0;
  CURL *easy = nullptr;
  std::shared_ptr<TlsState> tls;
  Clock::time_point deadline;

  RequestState(std::shared_ptr<Pool> p, const EhOptions &o, EhPostCObject post, int64_t event_port)
    : pool(std::move(p)), url(text(o.url)), method(text(o.method)), headers(text(o.headers)),
      proxy(text(o.proxy)), config(text(o.ech_config)), ip(text(o.connect_ip)), ca(text(o.ca_pem)),
      body(o.body_length ? reinterpret_cast<const char *>(o.body) : "", o.body_length),
      timeout_ms(o.timeout_ms), connect_timeout_ms(o.connect_timeout_ms), max_bytes(o.max_response_bytes),
      post(post), event_port(event_port), auto_uncompress(o.auto_uncompress) {}
  void cancel() {
    // Stop posting before releasing the handle, including during isolate teardown.
    std::lock_guard<std::mutex> lock(mutex);
    cancelled.store(true);
    room.notify_all();
  }
  bool push(int type, int code, const char *data, size_t length) {
    std::unique_lock<std::mutex> lock(mutex);
    if (type == 2) {
      while (pending_bytes + length > kBodyBufferLimit && !cancelled.load()) {
        if (room.wait_until(lock, deadline) == std::cv_status::timeout) { failure = "Response consumer exceeded request timeout"; return false; }
      }
    }
    if (cancelled.load()) return false;
    Dart_CObject fields[5] = {};
    const int values[] = {type, code, ech_accepted, retries};
    Dart_CObject *items[5];
    for (int i = 0; i < 4; ++i) {
      fields[i].type = Dart_CObject_kInt32;
      fields[i].value.as_int32 = values[i];
      items[i] = &fields[i];
    }
    fields[4].type = Dart_CObject_kTypedData;
    fields[4].value.as_typed_data.type = Dart_TypedData_kUint8;
    fields[4].value.as_typed_data.length = static_cast<intptr_t>(length);
    fields[4].value.as_typed_data.values = reinterpret_cast<const uint8_t *>(data);
    items[4] = &fields[4];
    Dart_CObject message = {};
    message.type = Dart_CObject_kArray;
    message.value.as_array.length = 5;
    message.value.as_array.values = items;
    // The VM copies kTypedData before post returns.
    if (!post(event_port, &message)) {
      cancelled.store(true);
      return false;
    }
    if (type == 2) pending_bytes += length;
    return true;
  }
  void run() noexcept;
  bool deliver(const char *data, size_t length) {
    if (cancelled.load()) return false;
    if (Clock::now() >= deadline) { failure = "Response consumer exceeded request timeout"; return false; }
    if (length > static_cast<uint64_t>(max_bytes) - received_bytes) { failure = "Response exceeds maxResponseBytes"; return false; }
    received_bytes += length;
    return push(2, 0, data, length);
  }
};

CURLcode configure_tls(CURL *, void *context, void *userdata) noexcept {
  auto *request = static_cast<RequestState *>(userdata);
  auto *ctx = static_cast<SSL_CTX *>(context);
  try {
    const int index = tls_state_index();
    if (index < 0) return CURLE_OUT_OF_MEMORY;
    auto *state = new std::shared_ptr<TlsState>(request->tls);
    if (!SSL_CTX_set_ex_data(ctx, index, state)) { delete state; return CURLE_OUT_OF_MEMORY; }
    // ECH rejection precedes curl's certificate check; verify the public name here.
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, verify_certificate);
    SSL_CTX_set_info_callback(ctx, handshake_info);
    return CURLE_OK;
  } catch (...) { return CURLE_OUT_OF_MEMORY; }
}
size_t receive_header(char *data, size_t size, size_t count, void *userdata) noexcept {
  auto *r = static_cast<RequestState *>(userdata);
  const size_t length = size * count;
  try {
    if (r->cancelled.load()) return 0;
    if (length >= 5 && std::memcmp(data, "HTTP/", 5) == 0) { r->header_block.clear(); r->in_header_block = true; }
    if (!r->in_header_block) return length; // trailers
    if (r->header_block.size() + length > kHeaderLimit) { r->failure = "HTTP headers exceed 128 KiB"; return 0; }
    r->header_block.append(data, length);
    if ((length == 2 && data[0] == '\r' && data[1] == '\n') || (length == 1 && data[0] == '\n')) {
      r->in_header_block = false;
      long status = 0;
      curl_easy_getinfo(r->easy, CURLINFO_RESPONSE_CODE, &status);
      if (status < 200) return length;
      curl_tlssessioninfo *session = nullptr;
      if (curl_easy_getinfo(r->easy, CURLINFO_TLS_SSL_PTR, &session) == CURLE_OK && session && session->internals) {
        r->ech_accepted = SSL_ech_accepted(static_cast<SSL *>(session->internals));
      }
      if (!r->config.empty() && !r->ech_accepted) { r->failure = "Server did not accept required ECH"; return 0; }
      r->decode_gzip = r->auto_uncompress && content_encoding(r->header_block) == "gzip";
      if (!r->push(1, static_cast<int>(status), r->header_block.data(), r->header_block.size())) return 0;
      r->sent_headers = true;
    }
    return length;
  } catch (...) { return 0; }
}
size_t receive_body(char *data, size_t size, size_t count, void *userdata) noexcept {
  auto *r = static_cast<RequestState *>(userdata);
  const size_t length = size * count;
  try {
    if (r->cancelled.load() || !r->sent_headers) return 0;
    if (r->decode_gzip) {
      return r->decoder.write(data, length, [r](const char *bytes, size_t n) {
        return r->deliver(bytes, n);
      }) ? length : 0;
    }
    return r->deliver(data, length) ? length : 0;
  } catch (const std::runtime_error &e) {
    r->decode_error = true; r->failure = e.what(); return 0;
  } catch (...) { return 0; }
}
int progress(void *userdata, curl_off_t, curl_off_t, curl_off_t, curl_off_t) noexcept {
  return static_cast<RequestState *>(userdata)->cancelled.load() ? 1 : 0;
}
struct List {
  curl_slist *value = nullptr;
  ~List() { curl_slist_free_all(value); }
  void append(const std::string &s) {
    auto *next = curl_slist_append(value, s.c_str());
    if (!next) throw std::bad_alloc();
    value = next;
  }
};

void RequestState::run() noexcept {
  CURLcode result = CURLE_FAILED_INIT;
  std::string key;
  try {
    deadline = Clock::now() + std::chrono::milliseconds(timeout_ms);
    CURLU *u = curl_url();
    if (!u) throw std::bad_alloc();
    struct UrlGuard { CURLU *p; ~UrlGuard() { curl_url_cleanup(p); } } guard{u};
    if (curl_url_set(u, CURLUPART_URL, url.c_str(), 0) != CURLUE_OK) throw std::runtime_error("Invalid URL");
    char *h = nullptr, *p = nullptr;
    if (curl_url_get(u, CURLUPART_HOST, &h, 0) != CURLUE_OK) throw std::runtime_error("URL has no hostname");
    hostname = h; curl_free(h);
    if (hostname.size() > 2 && hostname.front() == '[') hostname = hostname.substr(1, hostname.size() - 2);
    if (curl_url_get(u, CURLUPART_PORT, &p, CURLU_DEFAULT_PORT) != CURLUE_OK) throw std::runtime_error("URL has no port");
    port = p; curl_free(p);
    key = hostname + ":" + port + "\n" + proxy + "\n" + config + "\n" + ip + "\n" + ca;
    easy = pool->take(key);
    if (!easy) throw std::bad_alloc();
    List request_headers, destinations;
    for (const auto &line : lines(headers)) request_headers.append(line);
    request_headers.append("Expect:");
    if (!ip.empty()) {
      const auto source = hostname.find(':') != std::string::npos ? "[" + hostname + "]" : hostname;
      const auto dest = ip.find(':') != std::string::npos ? "[" + ip + "]" : ip;
      destinations.append(source + ":" + port + ":" + dest + ":" + port);
    }
    const std::string &roots = ca.empty() ? eh_ca_bundle() : ca;
    curl_blob root_blob{const_cast<char *>(roots.data()), roots.size(), CURL_BLOB_COPY};
    set_option(easy, CURLOPT_URL, url.c_str());
    set_option(easy, CURLOPT_PROTOCOLS_STR, "http,https");
    set_option(easy, CURLOPT_PROXY, proxy.c_str()); // empty explicitly disables environment proxies
    set_option(easy, CURLOPT_NOPROXY, "");
    set_option(easy, CURLOPT_SUPPRESS_CONNECT_HEADERS, 1L);
    set_option(easy, CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    set_option(easy, CURLOPT_HTTPHEADER, request_headers.value);
    // Decode only gzip at the bridge, matching dart:io, including multi-member
    // responses. Keep other content encodings and original headers untouched.
    set_option(easy, CURLOPT_HTTP_CONTENT_DECODING, 0L);
    set_option(easy, CURLOPT_CONNECT_TO, destinations.value);
    set_option(easy, CURLOPT_NOSIGNAL, 1L);
    set_option(easy, CURLOPT_FOLLOWLOCATION, 0L);
    set_option(easy, CURLOPT_SSL_VERIFYPEER, 1L);
    set_option(easy, CURLOPT_SSL_VERIFYHOST, 2L);
    // Do not retain libcurl's build-host CA paths alongside our explicit roots.
    set_option(easy, CURLOPT_CAINFO, static_cast<const char *>(nullptr));
    set_option(easy, CURLOPT_CAPATH, static_cast<const char *>(nullptr));
    set_option(easy, CURLOPT_CAINFO_BLOB, &root_blob);
    set_option(easy, CURLOPT_SSL_CTX_FUNCTION, configure_tls);
    set_option(easy, CURLOPT_SSL_CTX_DATA, this);
    set_option(easy, CURLOPT_HEADERFUNCTION, receive_header);
    set_option(easy, CURLOPT_HEADERDATA, this);
    set_option(easy, CURLOPT_WRITEFUNCTION, receive_body);
    set_option(easy, CURLOPT_WRITEDATA, this);
    set_option(easy, CURLOPT_XFERINFOFUNCTION, progress);
    set_option(easy, CURLOPT_XFERINFODATA, this);
    set_option(easy, CURLOPT_NOPROGRESS, 0L);
    set_option(easy, CURLOPT_CONNECTTIMEOUT_MS, static_cast<long>(connect_timeout_ms));
    if (!body.empty() || method == "POST" || method == "PUT" || method == "PATCH") {
      set_option(easy, CURLOPT_POSTFIELDS, body.data());
      set_option(easy, CURLOPT_POSTFIELDSIZE_LARGE, static_cast<curl_off_t>(body.size()));
    }
    if (method == "HEAD") set_option(easy, CURLOPT_NOBODY, 1L);
    set_option(easy, CURLOPT_CUSTOMREQUEST, method.c_str());
    char error[CURL_ERROR_SIZE] = {};
    set_option(easy, CURLOPT_ERRORBUFFER, error);
    for (retries = 0; retries <= 2; ++retries) {
      if (cancelled.load()) break;
      auto remaining = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
      if (remaining <= 0) { result = CURLE_OPERATION_TIMEDOUT; break; }
      set_option(easy, CURLOPT_TIMEOUT_MS, static_cast<long>(remaining));
      tls = std::make_shared<TlsState>(); tls->hostname = hostname; tls->require_ech = !config.empty();
      if (!config.empty() && !supports_ech(config)) {
        result = CURLE_ECH_REQUIRED; failure = "No supported ECH configuration; refusing plaintext fallback"; break;
      }
      std::string ech_option = config.empty() ? "false" : "ecl:" + config;
      set_option(easy, CURLOPT_ECH, ech_option.c_str());
      if (!config.empty()) set_option(easy, CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_3);
      error[0] = 0;
      result = curl_easy_perform(easy);
      if (decode_error) result = CURLE_BAD_CONTENT_ENCODING;
      if (result == CURLE_OK && decode_gzip) {
        try { decoder.finish(); }
        catch (const std::runtime_error &e) { result = CURLE_BAD_CONTENT_ENCODING; failure = e.what(); }
      }
      if (result == CURLE_ECH_REQUIRED && !sent_headers && tls->hostname_verified && !tls->retry_config.empty() && retries < 2) {
        config = tls->retry_config;
        set_option(easy, CURLOPT_FRESH_CONNECT, 1L);
        continue;
      }
      if (result != CURLE_OK && failure.empty()) failure = error[0] ? error : curl_easy_strerror(result);
      break;
    }
    if (result == CURLE_OK) { pool->put(key, easy); easy = nullptr; }
  } catch (const std::exception &e) { result = CURLE_FAILED_INIT; failure = e.what(); }
    catch (...) { result = CURLE_FAILED_INIT; failure = "Unknown native exception"; }
  if (easy) { curl_easy_cleanup(easy); easy = nullptr; }
  if (cancelled.load()) return;
  if (result != CURLE_OK && failure.empty()) failure = curl_easy_strerror(result);
  try { push(result == CURLE_OK ? 3 : 4, result, failure.data(), failure.size()); } catch (...) {}
}
} // namespace

// Dart owns the handle; the worker independently owns the shared state.
struct EhRequest { std::shared_ptr<RequestState> state; };

extern "C" {
const char *eh_version(void) { return curl_version(); }
EhClient *eh_client_create(void) {
  try {
    std::call_once(curl_init_flag, [] { curl_init_result = curl_global_init(CURL_GLOBAL_DEFAULT); });
    if (curl_init_result != CURLE_OK) return nullptr;
    const auto *info = curl_version_info(CURLVERSION_NOW);
    if (!info || !(info->features & CURL_VERSION_LIBZ)) return nullptr;
    return new EhClient();
  } catch (...) { return nullptr; }
}
void eh_client_destroy(EhClient *client) { delete client; }
EhRequest *eh_request_start(EhClient *client, const EhOptions *options, EhPostCObject post, int64_t port) {
  if (!client || !options || !post || port == 0 || options->timeout_ms <= 0 || options->max_response_bytes <= 0) return nullptr;
  try {
    auto request = std::make_unique<EhRequest>();
    request->state = std::make_shared<RequestState>(client->pool, *options, post, port);
    std::thread([state = request->state] { state->run(); }).detach();
    return request.release();
  } catch (...) { return nullptr; }
}
void eh_request_acknowledge(EhRequest *r, size_t bytes) {
  auto &state = *r->state;
  std::lock_guard<std::mutex> lock(state.mutex);
  if (bytes <= state.pending_bytes) state.pending_bytes -= bytes;
  state.room.notify_one();
}
void eh_request_destroy(EhRequest *r) {
  if (!r) return;
  r->state->cancel();
  delete r;
}
}

#include "CPrivacyTransport.h"
#include <curl/curl.h>
#include <CommonCrypto/CommonKeyDerivation.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>

struct veil_cancel_token { atomic_bool cancelled; };
veil_cancel_token *veil_cancel_create(void) {
    veil_cancel_token *token = calloc(1, sizeof(*token));
    if (token) atomic_init(&token->cancelled, 0);
    return token;
}
void veil_cancel_set(veil_cancel_token *token) { if (token) atomic_store(&token->cancelled, 1); }
void veil_cancel_destroy(veil_cancel_token *token) { free(token); }
static int progress(void *context, curl_off_t a, curl_off_t b, curl_off_t c, curl_off_t d) {
    (void)a; (void)b; (void)c; (void)d;
    return context && atomic_load(&((veil_cancel_token *)context)->cancelled);
}
static pthread_once_t once = PTHREAD_ONCE_INIT;
static int initialized = 0;
static void initialize(void) {
    // SecureTransport may cause trustd to fetch intermediates outside the proxy.
    // Explicitly select the system libcurl OpenSSL/LibreSSL backend instead.
    if (curl_global_sslset(CURLSSLBACKEND_OPENSSL, NULL, NULL) != CURLSSLSET_OK) return;
    initialized = curl_global_init(CURL_GLOBAL_DEFAULT) == CURLE_OK;
}
static size_t receive(void *bytes, size_t size, size_t count, void *context) {
    veil_response *response = context;
    if (count && size > SIZE_MAX / count) return 0;
    size_t length = size * count;
    // Bound even decompressed responses to 8 MiB.
    if (length > 8 * 1024 * 1024 || response->length > 8 * 1024 * 1024 - length) return 0;
    uint8_t *buffer = realloc(response->bytes, response->length + length + 1);
    if (!buffer) return 0;
    memcpy(buffer + response->length, bytes, length);
    response->length += length;
    buffer[response->length] = 0;
    response->bytes = buffer;
    return length;
}
veil_response veil_request(const char *url, const uint8_t *body, size_t body_length,
                          uint16_t port, const char *isolation, const char *ca_path, veil_cancel_token *token) {
    return veil_request_typed(url, body, body_length, port, isolation, ca_path, token, 0);
}
veil_response veil_request_typed(const char *url, const uint8_t *body, size_t body_length,
                          uint16_t port, const char *isolation, const char *ca_path, veil_cancel_token *token, int media_type) {
    veil_response response = {0};
    pthread_once(&once, initialize);
    if (!initialized || !ca_path || !*ca_path) { response.code = CURLE_NOT_BUILT_IN; return response; }
    CURL *curl = curl_easy_init();
    if (!curl) { response.code = CURLE_FAILED_INIT; return response; }
    char proxy[64];
    snprintf(proxy, sizeof(proxy), "socks5h://127.0.0.1:%u", port);
    struct curl_slist *headers = NULL;
    if (media_type < 0 || media_type > 2) { response.code = CURLE_BAD_FUNCTION_ARGUMENT; curl_easy_cleanup(curl); return response; }
    const char *types[] = {"Content-Type: application/json", "Content-Type: text/plain", "Content-Type: application/x.aptos.signed_transaction+bcs"};
    headers = curl_slist_append(headers, types[media_type]);
    headers = curl_slist_append(headers, "Accept: application/json");
    headers = curl_slist_append(headers, "Expect:");
    #define SETOPT(option, value) do { CURLcode result = curl_easy_setopt(curl, option, value); if (result != CURLE_OK) { response.code = (int)result; goto cleanup; } } while (0)
    SETOPT( CURLOPT_URL, url);
    SETOPT( CURLOPT_PROXY, proxy);
    SETOPT( CURLOPT_PROXYTYPE, CURLPROXY_SOCKS5_HOSTNAME);
    SETOPT( CURLOPT_NOPROXY, ""); // Override NO_PROXY, including '*'.
    SETOPT( CURLOPT_PROXYUSERNAME, isolation);
    SETOPT( CURLOPT_PROXYPASSWORD, "veil");
    SETOPT( CURLOPT_PROTOCOLS_STR, "https");
    SETOPT( CURLOPT_REDIR_PROTOCOLS_STR, "https");
    SETOPT( CURLOPT_FOLLOWLOCATION, 0L);
    SETOPT( CURLOPT_CAINFO, ca_path);
    SETOPT( CURLOPT_SSLVERSION, CURL_SSLVERSION_TLSv1_2);
    SETOPT( CURLOPT_SSL_SESSIONID_CACHE, 0L);
    SETOPT( CURLOPT_SSL_VERIFYPEER, 1L);
    SETOPT( CURLOPT_SSL_VERIFYHOST, 2L);
    // Do not enable OCSP network fetches; never use system URL loading.
    SETOPT( CURLOPT_HTTP_VERSION, CURL_HTTP_VERSION_1_1);
    SETOPT( CURLOPT_HTTPHEADER, headers);
    SETOPT( CURLOPT_USERAGENT, "");
    SETOPT( CURLOPT_REFERER, NULL);
    SETOPT( CURLOPT_NETRC, CURL_NETRC_IGNORED);
    SETOPT( CURLOPT_CONNECTTIMEOUT, 30L);
    SETOPT( CURLOPT_TIMEOUT, 90L);
    SETOPT( CURLOPT_NOSIGNAL, 1L);
    SETOPT( CURLOPT_WRITEFUNCTION, receive);
    SETOPT( CURLOPT_WRITEDATA, &response);
    SETOPT( CURLOPT_XFERINFOFUNCTION, progress);
    SETOPT( CURLOPT_XFERINFODATA, token);
    SETOPT( CURLOPT_NOPROGRESS, 0L);
    if (body) {
        SETOPT( CURLOPT_POST, 1L);
        SETOPT( CURLOPT_POSTFIELDS, body);
        SETOPT( CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_length);
    }
    response.code = (int)curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response.status);
cleanup:
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    return response;
}
void veil_response_free(veil_response response) { free(response.bytes); }
veil_response veil_monero_local(uint16_t port, const char *password, const uint8_t *body, size_t body_length, veil_cancel_token *token) {
    veil_response response = {0};
    if (!port || !password || strlen(password) != 64 || !body || body_length > 2 * 1024 * 1024) { response.code = CURLE_BAD_FUNCTION_ARGUMENT; return response; }
    pthread_once(&once, initialize);
    if (!initialized) { response.code = CURLE_NOT_BUILT_IN; return response; }
    CURL *curl = curl_easy_init(); if (!curl) { response.code = CURLE_FAILED_INIT; return response; }
    char url[96]; snprintf(url, sizeof(url), "http://127.0.0.1:%u/json_rpc", port);
    struct curl_slist *headers = NULL;
    headers = curl_slist_append(headers, "Content-Type: application/json");
    headers = curl_slist_append(headers, "Expect:");
    SETOPT(CURLOPT_URL, url); SETOPT(CURLOPT_PROXY, ""); SETOPT(CURLOPT_NOPROXY, "*");
    SETOPT(CURLOPT_PROTOCOLS_STR, "http"); SETOPT(CURLOPT_FOLLOWLOCATION, 0L);
    SETOPT(CURLOPT_HTTPAUTH, (long)CURLAUTH_DIGEST); SETOPT(CURLOPT_USERNAME, "veil"); SETOPT(CURLOPT_PASSWORD, password);
    SETOPT(CURLOPT_NETRC, CURL_NETRC_IGNORED); SETOPT(CURLOPT_HTTPHEADER, headers);
    SETOPT(CURLOPT_POST, 1L); SETOPT(CURLOPT_POSTFIELDS, body); SETOPT(CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body_length);
    SETOPT(CURLOPT_CONNECTTIMEOUT, 2L); SETOPT(CURLOPT_TIMEOUT, 1800L); SETOPT(CURLOPT_NOSIGNAL, 1L);
    SETOPT(CURLOPT_WRITEFUNCTION, receive); SETOPT(CURLOPT_WRITEDATA, &response);
    SETOPT(CURLOPT_XFERINFOFUNCTION, progress); SETOPT(CURLOPT_XFERINFODATA, token); SETOPT(CURLOPT_NOPROGRESS, 0L);
    response.code = (int)curl_easy_perform(curl); curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &response.status);
cleanup:
    curl_slist_free_all(headers); curl_easy_cleanup(curl); return response;
}
int veil_pbkdf2(const uint8_t *password, size_t password_length,
                const uint8_t *salt, size_t salt_length, uint32_t rounds,
                int sha512, uint8_t *output, size_t output_length) {
    return CCKeyDerivationPBKDF(kCCPBKDF2, (const char *)password, password_length,
        salt, salt_length, sha512 ? kCCPRFHmacAlgSHA512 : kCCPRFHmacAlgSHA256,
        rounds, output, output_length);
}

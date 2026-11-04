#ifndef VEIL_PRIVACY_TRANSPORT_H
#define VEIL_PRIVACY_TRANSPORT_H
#include <stddef.h>
#include <stdint.h>
typedef struct veil_cancel_token veil_cancel_token;
veil_cancel_token *veil_cancel_create(void);
void veil_cancel_set(veil_cancel_token *token);
void veil_cancel_destroy(veil_cancel_token *token);
typedef struct {
    uint8_t *bytes;
    size_t length;
    long status;
    int code;
} veil_response;
// Only HTTPS over literal-loopback SOCKS5 with remote hostname resolution.
veil_response veil_request(const char *url, const uint8_t *body, size_t body_length,
                          uint16_t port, const char *isolation, const char *ca_path, veil_cancel_token *token);
// media_type: 0 JSON, 1 plain transaction text, 2 Aptos signed BCS.
veil_response veil_request_typed(const char *url, const uint8_t *body, size_t body_length,
                          uint16_t port, const char *isolation, const char *ca_path, veil_cancel_token *token, int media_type);
void veil_response_free(veil_response response);
// Only authenticated JSON-RPC to the bundled Monero child on literal IPv4 loopback.
// URL and path are constructed internally; this API cannot target external hosts.
veil_response veil_monero_local(uint16_t port, const char *password, const uint8_t *body, size_t body_length, veil_cancel_token *token);
int veil_pbkdf2(const uint8_t *password, size_t password_length,
                const uint8_t *salt, size_t salt_length, uint32_t rounds,
                int sha512, uint8_t *output, size_t output_length);
#endif

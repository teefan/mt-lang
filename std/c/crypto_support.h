#ifndef MT_CRYPTO_SUPPORT_H
#define MT_CRYPTO_SUPPORT_H

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static inline int mt_sha256(const uint8_t* data, uintptr_t data_len, uint8_t* out_digest) {
    if (out_digest == NULL) {
        return 0;
    }

    unsigned int digest_len = 0;
    EVP_MD_CTX* ctx = EVP_MD_CTX_new();
    if (ctx == NULL) {
        return 0;
    }

    int ok = EVP_DigestInit_ex(ctx, EVP_sha256(), NULL) == 1
          && EVP_DigestUpdate(ctx, data, (size_t) data_len) == 1
          && EVP_DigestFinal_ex(ctx, out_digest, &digest_len) == 1;

    EVP_MD_CTX_free(ctx);
    return ok ? 1 : 0;
}

static inline int mt_hmac_sha256(const uint8_t* key, uintptr_t key_len, const uint8_t* data, uintptr_t data_len, uint8_t* out_digest) {
    if (out_digest == NULL) {
        return 0;
    }

    unsigned int digest_len = 0;
    unsigned char* result = HMAC(EVP_sha256(),
                                 key, (int) key_len,
                                 data, (size_t) data_len,
                                 out_digest, &digest_len);
    return result != NULL ? 1 : 0;
}

static inline int mt_random_bytes(uint8_t* buffer, uintptr_t count) {
    if (buffer == NULL || count == 0) {
        return 0;
    }

    return RAND_bytes(buffer, (int) count) == 1 ? 1 : 0;
}

#endif

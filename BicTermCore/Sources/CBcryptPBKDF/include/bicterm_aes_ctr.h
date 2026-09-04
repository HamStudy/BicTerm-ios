#ifndef BICTERM_AES_CTR_H
#define BICTERM_AES_CTR_H

#include <stddef.h>
#include <stdint.h>

int bicterm_aes256_ctr_crypt(const uint8_t *input, size_t input_length,
    const uint8_t *key, size_t key_length,
    const uint8_t *iv, size_t iv_length,
    uint8_t *output);

#endif

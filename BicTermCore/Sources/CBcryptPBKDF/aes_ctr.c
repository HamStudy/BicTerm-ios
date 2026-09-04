#include "bicterm_aes_ctr.h"

#include <CommonCrypto/CommonCryptor.h>

int
bicterm_aes256_ctr_crypt(const uint8_t *input, size_t input_length,
    const uint8_t *key, size_t key_length,
    const uint8_t *iv, size_t iv_length,
    uint8_t *output)
{
    CCCryptorRef cryptor = NULL;
    size_t moved = 0;
    size_t final_moved = 0;
    CCCryptorStatus status;

    if (input == NULL || key == NULL || iv == NULL || output == NULL ||
        key_length != kCCKeySizeAES256 || iv_length != kCCBlockSizeAES128)
        return kCCParamError;

    status = CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES,
        ccNoPadding, iv, key, key_length, NULL, 0, 0,
        kCCModeOptionCTR_BE, &cryptor);
    if (status != kCCSuccess)
        return status;

    status = CCCryptorUpdate(cryptor, input, input_length, output,
        input_length, &moved);
    if (status == kCCSuccess)
        status = CCCryptorFinal(cryptor, output + moved,
            input_length - moved, &final_moved);

    CCCryptorRelease(cryptor);
    if (status != kCCSuccess)
        return status;
    return moved + final_moved == input_length ? kCCSuccess : kCCDecodeError;
}

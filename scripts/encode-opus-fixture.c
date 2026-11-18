#include <opus.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

/* Test-only encoder: raw 16kHz mono signed little-endian Int16 -> a sequence
 * of 2-byte big-endian lengths and raw Opus packets, matching the glasses. */
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    FILE *input = fopen(argv[1], "rb");
    FILE *output = fopen(argv[2], "wb");
    if (!input || !output) return 3;
    int error = 0;
    OpusEncoder *encoder = opus_encoder_create(16000, 1, OPUS_APPLICATION_VOIP, &error);
    if (!encoder || error) return 4;
    int16_t pcm[320];
    unsigned char packet[1275];
    size_t count;
    while ((count = fread(pcm, sizeof(int16_t), 320, input)) > 0) {
        memset(pcm + count, 0, (320 - count) * sizeof(int16_t));
        int length = opus_encode(encoder, pcm, 320, packet, sizeof(packet));
        if (length <= 0) return 5;
        unsigned char prefix[] = {(unsigned char)(length >> 8), (unsigned char)(length & 255)};
        if (fwrite(prefix, 1, 2, output) != 2 || fwrite(packet, 1, length, output) != (size_t)length) return 6;
    }
    opus_encoder_destroy(encoder);
    fclose(input);
    return fclose(output) ? 7 : 0;
}

#pragma once
#include <stdint.h>
#include <stdbool.h>

typedef struct {
    char key[5];
    char type[5];
    uint32_t size;
    uint8_t bytes[32];
} SMCVal;

int  smc_open(void);
void smc_close(void);
int  smc_read(const char *key, SMCVal *out);
int  smc_write(const char *key, const uint8_t *bytes, uint32_t size);
uint32_t smc_key_count(void);
int  smc_key_at(uint32_t idx, char out[5]);

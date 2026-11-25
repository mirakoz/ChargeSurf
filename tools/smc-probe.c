// smc-probe: read-only AppleSMC key lister. Usage: smc-probe <prefix>... (e.g. smc-probe CH bf TB)
// Useful for checking which charge-control keys exist on your Mac/firmware.
#include "../src/smc.h"
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    if (smc_open()) { puts("cannot open AppleSMC"); return 1; }
    uint32_t n = smc_key_count(); printf("total keys: %u\n", n);
    for (uint32_t i = 0; i < n; i++) {
        char k[5]; if (smc_key_at(i, k)) continue;
        int want = 0;
        for (int a = 1; a < argc; a++) if (!strncmp(k, argv[a], strlen(argv[a]))) want = 1;
        if (!want) continue;
        SMCVal v; if (smc_read(k, &v)) { printf("%s  (unreadable)\n", k); continue; }
        printf("%s  %-4s %2u  ", k, v.type, v.size);
        for (uint32_t b = 0; b < v.size && b < 16; b++) printf("%02x ", v.bytes[b]);
        if (!strcmp(v.type, "flt ") && v.size == 4) { float f; memcpy(&f, v.bytes, 4); printf(" = %.2f", f); }
        puts("");
    }
    smc_close(); return 0;
}

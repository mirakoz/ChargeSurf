// Minimal AppleSMC access via IOKit. Reading needs no privileges; writing needs root
// (and on macOS 27 the charge-control keys are entitlement-gated even for root).
#include "smc.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

typedef struct { char major, minor, build, reserved; uint16_t release; } Vers;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, mem; } PLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } KeyInfo;
typedef struct {
    uint32_t key; Vers vers; PLimit pLimit; KeyInfo keyInfo;
    uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32];
} KeyData;

enum { kKernelIndex = 2, kRead = 5, kWrite = 6, kIndex = 8, kInfo = 9 };
static io_connect_t conn = 0;

static uint32_t k2u(const char *k) { return ((uint32_t)k[0]<<24)|((uint32_t)k[1]<<16)|((uint32_t)k[2]<<8)|(uint32_t)k[3]; }
static void u2k(uint32_t v, char *o) { o[0]=v>>24; o[1]=v>>16; o[2]=v>>8; o[3]=v; o[4]=0; }

static int call(KeyData *in, KeyData *out) {
    size_t sz = sizeof(KeyData);
    kern_return_t r = IOConnectCallStructMethod(conn, kKernelIndex, in, sizeof(KeyData), out, &sz);
    if (r != KERN_SUCCESS) return (int)r;
    return out->result ? out->result : 0;
}

int smc_open(void) {
    io_service_t s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!s) return -1;
    kern_return_t r = IOServiceOpen(s, mach_task_self(), 0, &conn);
    IOObjectRelease(s);
    return r == KERN_SUCCESS ? 0 : (int)r;
}
void smc_close(void) { if (conn) IOServiceClose(conn); conn = 0; }

static int info(const char *key, KeyInfo *ki) {
    KeyData in = {0}, out = {0};
    in.key = k2u(key); in.data8 = kInfo;
    int r = call(&in, &out); if (r) return r;
    *ki = out.keyInfo; return 0;
}

int smc_read(const char *key, SMCVal *v) {
    KeyInfo ki; int r = info(key, &ki); if (r) return r;
    KeyData in = {0}, out = {0};
    in.key = k2u(key); in.keyInfo.dataSize = ki.dataSize; in.data8 = kRead;
    r = call(&in, &out); if (r) return r;
    memset(v, 0, sizeof *v);
    strncpy(v->key, key, 4); u2k(ki.dataType, v->type); v->size = ki.dataSize;
    memcpy(v->bytes, out.bytes, ki.dataSize > 32 ? 32 : ki.dataSize);
    return 0;
}

int smc_write(const char *key, const uint8_t *bytes, uint32_t size) {
    KeyInfo ki; int r = info(key, &ki); if (r) return r;
    if (ki.dataSize != size) return -2;
    KeyData in = {0}, out = {0};
    in.key = k2u(key); in.data8 = kWrite; in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, size);
    return call(&in, &out);
}

uint32_t smc_key_count(void) {
    SMCVal v; if (smc_read("#KEY", &v)) return 0;
    return ((uint32_t)v.bytes[0]<<24)|((uint32_t)v.bytes[1]<<16)|((uint32_t)v.bytes[2]<<8)|v.bytes[3];
}
int smc_key_at(uint32_t idx, char o[5]) {
    KeyData in = {0}, out = {0};
    in.data8 = kIndex; in.data32 = idx;
    int r = call(&in, &out); if (r) return r;
    u2k(out.key, o); return 0;
}

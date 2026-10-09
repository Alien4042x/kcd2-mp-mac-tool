// Read-only host VM protection probe for one Wine process and one ntdll address.
// It uses proc_pidinfo, does not attach, inject, or change memory protections.
#include <libproc.h>
#include <mach/vm_prot.h>
#include <sys/proc_info.h>
#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static uint64_t monotonic_ms(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * 1000 + (uint64_t)now.tv_nsec / 1000000;
}

static int parse_number(const char *text, int base, uint64_t *value) {
    if (!text || !*text || *text == '-') return 0;
    char *end = NULL;
    errno = 0;
    unsigned long long parsed = strtoull(text, &end, base);
    if (errno || !end || *end != '\0') return 0;
    *value = (uint64_t)parsed;
    return 1;
}

static int is_ntdll_path(const char *path) {
    const char *name = strrchr(path, '/');
    name = name ? name + 1 : path;
    return strcmp(name, "ntdll.dll") == 0;
}

static int read_region(int pid, uint64_t address, struct proc_regioninfo *region) {
    memset(region, 0, sizeof(*region));
    int size = proc_pidinfo(pid, PROC_PIDREGIONINFO, address, region, sizeof(*region));
    return size == sizeof(*region) && address >= region->pri_address &&
           address - region->pri_address < region->pri_size;
}

int main(int argc, char **argv) {
    uint64_t pid_number, address, seconds;
    if (argc != 4 || !parse_number(argv[1], 10, &pid_number) ||
        !parse_number(argv[2], 0, &address) || !parse_number(argv[3], 10, &seconds) ||
        pid_number == 0 || pid_number > INT32_MAX || address == 0 ||
        seconds == 0 || seconds > 300) {
        fprintf(stderr, "usage: macos_ntdll_page_probe MAC_PID HEX_ADDRESS SECONDS(1..300)\n");
        return 2;
    }
    int pid = (int)pid_number;
    char module[PROC_PIDPATHINFO_MAXSIZE] = {0};
    if (proc_regionfilename(pid, address, module, sizeof(module)) <= 0 ||
        !is_ntdll_path(module)) {
        fprintf(stderr, "refused: address is not mapped to ntdll.dll in PID %d\n", pid);
        return 3;
    }
    struct proc_regioninfo region;
    if (!read_region(pid, address, &region)) {
        fprintf(stderr, "refused: cannot read the selected memory region\n");
        return 3;
    }

    printf("PROBE|pid=%d|address=0x%" PRIx64 "|module=%s|interval_ms=10\n",
           pid, address, module);
    fflush(stdout);
    uint64_t started = monotonic_ms();
    uint64_t last_heartbeat = UINT64_MAX;
    uint32_t previous_protection = UINT32_MAX;
    uint32_t previous_max = UINT32_MAX;
    uint64_t previous_base = UINT64_MAX;
    uint64_t samples = 0;
    unsigned nonexec_samples = 0;
    struct timespec pause = {.tv_sec = 0, .tv_nsec = 10000000};

    while (monotonic_ms() - started < seconds * 1000) {
        uint64_t elapsed = monotonic_ms() - started;
        if (!read_region(pid, address, &region)) {
            printf("END|ms=%" PRIu64 "|reason=region_unavailable|samples=%" PRIu64
                   "|nonexec_samples=%u\n", elapsed, samples, nonexec_samples);
            fflush(stdout);
            return 0;
        }
        ++samples;
        uint64_t heartbeat = elapsed / 1000;
        int changed = region.pri_protection != previous_protection ||
                      region.pri_max_protection != previous_max ||
                      region.pri_address != previous_base;
        int nonexec = !(region.pri_protection & VM_PROT_EXECUTE);
        if (nonexec) ++nonexec_samples;
        if (changed || heartbeat != last_heartbeat) {
            printf("SAMPLE|ms=%" PRIu64 "|base=0x%" PRIx64 "|size=0x%" PRIx64
                   "|protect=%u|max=%u|execute=%d|changed=%d\n",
                   elapsed, region.pri_address, region.pri_size,
                   region.pri_protection, region.pri_max_protection,
                   !nonexec, changed);
            fflush(stdout);
            previous_protection = region.pri_protection;
            previous_max = region.pri_max_protection;
            previous_base = region.pri_address;
            last_heartbeat = heartbeat;
        }
        nanosleep(&pause, NULL);
    }
    printf("END|ms=%" PRIu64 "|reason=duration|samples=%" PRIu64
           "|nonexec_samples=%u\n", monotonic_ms() - started, samples, nonexec_samples);
    fflush(stdout);
    return 0;
}

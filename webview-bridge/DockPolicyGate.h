#pragma once
#include <stddef.h>
#include <string.h>
#include <strings.h>
#include <stdlib.h>
#include <limits.h>

static inline int kcdmp_dock_owner(const char *value) {
    if (!value || !*value) return 0;
    char *end = NULL;
    long number = strtol(value, &end, 10);
    return end && !*end && number > 1 && number <= INT_MAX ? (int)number : 0;
}

static inline int kcdmp_dock_allowed(int argc, const char *const *argv,
                                    const char *enabled, const char *expected, const char *token) {
    if (!argv || argc < 1 || !enabled || strcmp(enabled, "1") || !expected || expected[0] != '/' || !token || strlen(token) != 64) return 0;
    for (size_t i = 0; i < 64; ++i)
        if (!((token[i] >= '0' && token[i] <= '9') || (token[i] >= 'a' && token[i] <= 'f'))) return 0;
    const char *name = strrchr(expected, '/');
    if (!name || strcmp(name + 1, "KcdMp_launcher.exe")) return 0;
    // Only the first PE executable argument identifies this process. A game's
    // later argument containing the launcher's path must not activate this.
    for (int i = 0; i < argc; ++i) {
        if (!argv[i]) return 0;
        size_t length = strlen(argv[i]);
        if (length >= 4 && !strcasecmp(argv[i] + length - 4, ".exe"))
            return !strcmp(argv[i], expected);
    }
    return 0;
}

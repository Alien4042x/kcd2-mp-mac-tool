#include <assert.h>
#include <stdio.h>
#include "../webview-bridge/DockPolicyGate.h"

int main(void) {
    const char *expected = "/tmp/probe/KcdMp_launcher.exe";
    const char *token = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const char *launcher[] = {"/tmp/wine", expected};
    const char *game[] = {"/tmp/wine", "/tmp/game/KingdomCome.exe", expected};
    const char *steam[] = {"/tmp/wine", "/tmp/steam.exe", expected};
    const char *missing[] = {"/tmp/wine", NULL};
    assert(kcdmp_dock_allowed(2, launcher, "1", expected, token));
    assert(!kcdmp_dock_allowed(3, game, "1", expected, token));
    assert(!kcdmp_dock_allowed(3, steam, "1", expected, token));
    assert(!kcdmp_dock_allowed(0, NULL, "1", expected, token));
    assert(!kcdmp_dock_allowed(2, missing, "1", expected, token));
    assert(!kcdmp_dock_allowed(2, launcher, NULL, expected, token));
    assert(!kcdmp_dock_allowed(2, launcher, "0", expected, token));
    assert(!kcdmp_dock_allowed(2, launcher, "1", NULL, token));
    assert(!kcdmp_dock_allowed(2, launcher, "1", expected, NULL));
    assert(!kcdmp_dock_allowed(2, launcher, "1", expected, "0"));
    assert(!kcdmp_dock_allowed(2, launcher, "1", expected, "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg"));
    assert(!kcdmp_dock_allowed(2, launcher, "1", "/tmp/KingdomCome.exe", token));
    assert(!kcdmp_dock_allowed(2, launcher, "1", "C:\\KcdMp_launcher.exe", token));
    assert(kcdmp_dock_owner("42") == 42);
    assert(!kcdmp_dock_owner(NULL));
    assert(!kcdmp_dock_owner(""));
    assert(!kcdmp_dock_owner("0"));
    assert(!kcdmp_dock_owner("1"));
    assert(!kcdmp_dock_owner("-1"));
    assert(!kcdmp_dock_owner("null"));
    assert(!kcdmp_dock_owner("42invalid"));
    assert(!kcdmp_dock_owner("9999999999999999999999999999999999999999999"));
    puts("Dock policy gate: launcher accepted, game/Steam/missing/malformed activation refused");
}

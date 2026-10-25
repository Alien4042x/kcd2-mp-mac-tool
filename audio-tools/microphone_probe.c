#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <mmsystem.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static int failure(const char *status, UINT devices, DWORD code)
{
    printf("{\"status\":\"%s\",\"deviceCount\":%u,\"samples\":null,\"peak\":null,\"errorCode\":%lu}\n",
           status, devices, (unsigned long)code);
    return 1;
}

int main(void)
{
    const UINT devices = waveInGetNumDevs();
    if (!devices) return failure("no_devices", devices, 0);
    HANDLE event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!event) return failure("event_failed", devices, GetLastError());
    int16_t *samples = calloc(48000, sizeof(*samples));
    if (!samples) { CloseHandle(event); return failure("allocation_failed", devices, 0); }
    WAVEFORMATEX format = { WAVE_FORMAT_PCM, 1, 48000, 96000, 2, 16, 0 };
    HWAVEIN input = NULL;
    MMRESULT result = waveInOpen(&input, WAVE_MAPPER, &format, (DWORD_PTR)event, 0, CALLBACK_EVENT);
    if (result != MMSYSERR_NOERROR) {
        free(samples); CloseHandle(event); return failure("open_failed", devices, result);
    }
    WAVEHDR header = {0};
    header.lpData = (LPSTR)samples;
    header.dwBufferLength = 48000 * sizeof(*samples);
    result = waveInPrepareHeader(input, &header, sizeof(header));
    const char *error = NULL;
    if (result != MMSYSERR_NOERROR) error = "prepare_failed";
    if (!error) {
        result = waveInAddBuffer(input, &header, sizeof(header));
        if (result != MMSYSERR_NOERROR) error = "queue_failed";
    }
    if (!error) {
        result = waveInStart(input);
        if (result != MMSYSERR_NOERROR) error = "start_failed";
    }
    if (!error) {
        const ULONGLONG deadline = GetTickCount64() + 4000;
        while (!(header.dwFlags & WHDR_DONE) && GetTickCount64() < deadline)
            WaitForSingleObject(event, 100);
        if (!(header.dwFlags & WHDR_DONE)) error = "timeout";
        else if (!header.dwBytesRecorded) error = "empty_capture";
    }
    waveInStop(input);
    waveInReset(input);
    const DWORD count = header.dwBytesRecorded / sizeof(*samples);
    int peak = 0;
    if (!error) {
        for (DWORD i = 0; i < count; ++i) {
            const int sample = samples[i];
            const int magnitude = sample < 0 ? -sample : sample;
            if (magnitude > peak) peak = magnitude;
        }
    }
    if (header.dwFlags & WHDR_PREPARED) waveInUnprepareHeader(input, &header, sizeof(header));
    waveInClose(input);
    free(samples);
    CloseHandle(event);
    if (error) return failure(error, devices, result);
    printf("{\"status\":\"%s\",\"deviceCount\":%u,\"samples\":%lu,\"peak\":%d,\"errorCode\":null}\n",
           peak ? "ok_signal" : "ok_silent", devices, (unsigned long)count, peak);
    return 0;
}

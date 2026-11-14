#!/usr/bin/env python3
"""Generate explicit E_NOTIMPL bases from the pinned Microsoft COM interfaces."""
import re
import sys
from pathlib import Path

INTERFACES = {
    "ICoreWebView2": "CoreStub",
    "ICoreWebView2Controller": "ControllerStub",
    "ICoreWebView2Environment": "EnvironmentStub",
    "ICoreWebView2Settings": "SettingsStub",
    "ICoreWebView2WebMessageReceivedEventArgs": "MessageArgsStub",
    "ICoreWebView2NavigationCompletedEventArgs": "NavigationArgsStub",
}


def generate(header):
    output = ["// Generated from the pinned Microsoft WebView2.h. Do not edit.", "#pragma once"]
    for interface, name in INTERFACES.items():
        match = re.search(r"\b" + interface + r"\s*:\s*public IUnknown\s*\{(.*?)\n\s*\};", header, re.S)
        if not match:
            raise ValueError("Missing interface: " + interface)
        body = re.sub(r"/\*.*?\*/", "", match.group(1), flags=re.S)
        methods = re.findall(r"virtual\s+HRESULT\s+STDMETHODCALLTYPE\s+(\w+)\s*\((.*?)\)\s*=\s*0;", body, re.S)
        if not methods or body.count("= 0;") != len(methods):
            raise ValueError("Unrecognized method declaration in " + interface)
        output.append(f"struct {name} : RefCounted<{interface}> {{")
        for method, parameters in methods:
            parameters = " ".join(parameters.split())
            output.append(f'HRESULT STDMETHODCALLTYPE {method}({parameters}) override {{ return unsupported("{interface}.{method}"); }}')
        output.append("};")
    return "\n".join(output) + "\n"


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: generate_stubs.py WebView2.h output.hpp")
    Path(sys.argv[2]).write_text(generate(Path(sys.argv[1]).read_text(encoding="utf-8-sig")))

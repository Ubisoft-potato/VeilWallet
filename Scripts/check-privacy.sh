#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Application RPC uses CPrivacyTransport. Monero is the documented exception:
# authenticated literal-loopback RPC plus a kernel-restricted upstream helper.
if rg -n '\b(URLSession|URLRequest|WKWebView|NWConnection|NSURLConnection|Sentry|Firebase|AsyncImage)\b|webSocketTask[[:space:]]*\(|NSWorkspace\.shared\.open' Sources; then
    echo 'Unexpected network or telemetry surface in production sources' >&2; exit 1
fi
for required in CURLPROXY_SOCKS5_HOSTNAME CURLOPT_NOPROXY CURLOPT_PROTOCOLS_STR CURLOPT_SSL_VERIFYPEER CURLOPT_SSL_VERIFYHOST; do
    rg -q "$required" Sources/CPrivacyTransport/PrivacyTransport.c || exit 1
done
for required in 'deny network*' 'deny mach-lookup' 'deny file-read*' 'deny file-write*' '--no-addons' '/usr/bin/sandbox-exec'; do
    rg -Fq -- "$required" Sources/WalletCore/Networking/PrivacyProofRuntime.swift || exit 1
done
if rg -n 'https?://|require\(.?(https?|net|dns|tls|child_process)' Tools/PrivacyProof/main.cjs; then
    echo 'Unexpected network or process dependency in the offline proof adapter' >&2; exit 1
fi
for required in 'http://127.0.0.1:%u/json_rpc' CURLAUTH_DIGEST; do
    rg -Fq "$required" Sources/CPrivacyTransport/PrivacyTransport.c || exit 1
done
for required in 'deny network*' 'deny mach-lookup' 'localhost:\(torPort)' 'no-dns=1' 'no-initial-sync=1' 'proxy=127.0.0.1:' '/usr/bin/sandbox-exec'; do
    rg -Fq "$required" Sources/WalletCore/Networking/MoneroRuntime.swift || exit 1
done
if rg -n 'print\(|debugPrint\(|os_log\(|Logger\(' Sources; then
    echo 'Review production logging before enabling it' >&2; exit 1
fi
if rg -n '"net/http"|"net"|exec\.Command|os\.Open|fmt\.Print|log\.Print' Native/ChainCore -g '*.go'; then
    echo 'Unexpected I/O or logging in the native crypto ABI' >&2; exit 1
fi
echo 'Privacy source guard passed.'

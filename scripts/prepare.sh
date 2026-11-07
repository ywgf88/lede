#!/usr/bin/env bash
# Prepare a Lean LEDE tree for the MT7981 (CT3003 / RAX3000M / 360T7) build.
# Idempotent: safe to re-run on the same checkout.
#
# Environment:
#   DEVICES="cetron_ct3003 cmcc_rax3000m-nand qihoo_360t7"   (space separated)
#   SKIP_FEEDS=1   skip `feeds update/install` (incremental rebuilds)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
export DEVICES="${DEVICES:-cetron_ct3003 cmcc_rax3000m-nand qihoo_360t7}"

echo "=== [1/7] custom feeds ==="
if ! grep -q '^src-git vantage ' feeds.conf.default; then
	cat configs/feeds.custom >> feeds.conf.default
else
	echo "    already present"
fi

echo "=== [2/7] slim DEFAULT_PACKAGES.router (size budget) ==="
python3 - <<'PY'
import pathlib
p = pathlib.Path('include/target.mk')
s = p.read_text()
start = s.index('DEFAULT_PACKAGES.router:=')
end = s.index('\n\n', start)
new = r'''DEFAULT_PACKAGES.router:=\
	dnsmasq-full firewall4 nftables-json iptables ppp ppp-mod-pppoe \
	block-mount kmod-nf-nathelper kmod-tun iptables-mod-tproxy ip-full \
	default-settings luci luci-compat \
	luci-app-ssr-plus luci-app-passwall2 luci-theme-vantage \
	curl ca-certificates'''
p.write_text(s[:start] + new + s[end:])
print('    router defaults replaced')
PY

echo "=== [3/7] first-boot uci-defaults ==="
mkdir -p files/etc/uci-defaults
cp scripts/uci-defaults/zzzz-ipv4-only files/etc/uci-defaults/
cp scripts/uci-defaults/zzzz-vantage-theme files/etc/uci-defaults/
chmod 755 files/etc/uci-defaults/zzzz-*

echo "=== [4/7] seed .config ==="
cp configs/mt7981.seed .config

echo "=== [5/7] feeds ==="
if [ "${SKIP_FEEDS:-0}" != "1" ]; then
	./scripts/feeds update -a
	./scripts/feeds install -a
	# helloworld and passwall_packages both ship xray-core / chinadns-ng.
	# Force one consistent source so both proxy apps share a single binary.
	for pkg in xray-core chinadns-ng geoview v2ray-geoip v2ray-geosite; do
		./scripts/feeds install -f -p passwall_packages "$pkg" 2>/dev/null \
			&& echo "    pinned $pkg <- passwall_packages" \
			|| echo "    note: $pkg not in passwall_packages (using other feed)"
	done
	./scripts/feeds install -f -p passwall2 luci-app-passwall2
	./scripts/feeds install -f -p vantage luci-theme-vantage
else
	echo "    skipped (SKIP_FEEDS=1)"
fi

echo "=== [6/7] make defconfig + select device profiles ==="
make defconfig
python3 - <<'PY'
import os, pathlib, re, sys

wanted = {d.replace('-', '_') for d in os.environ['DEVICES'].split()}
prefix = 'CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_'
p = pathlib.Path('.config')
out, found, available = [], set(), []

for line in p.read_text().splitlines():
    raw = line[2:] if line.startswith('# ') else line
    if raw.startswith(prefix):
        sym = re.split(r'=| is not set', raw, maxsplit=1)[0].strip()
        short = sym[len(prefix):]
        key = short.replace('-', '_')
        available.append(sym)
        if key in wanted:
            out.append(sym + '=y')
            found.add(key)
        else:
            out.append('# ' + sym + ' is not set')
    else:
        out.append(line)

missing = wanted - found
if missing:
    sys.exit('ERROR: device profile symbol(s) not found for: %s\n'
             'Available DEVICE symbols sample:\n  %s'
             % (', '.join(sorted(missing)), '\n  '.join(available[:15])))
p.write_text('\n'.join(out) + '\n')
print('    selected: ' + ', '.join(sorted(found)))
PY
make defconfig

echo "=== [7/7] summary ==="
grep '^CONFIG_TARGET_DEVICE_mediatek_filogic_DEVICE_' .config || true
grep -E '^CONFIG_PACKAGE_(luci-app-ssr-plus|luci-app-passwall2|luci-theme-vantage)=' .config || true
[ -x scripts/diffconfig.sh ] && ./scripts/diffconfig.sh > configs/mt7981.diffconfig 2>/dev/null || true
echo "=== ready: run  make download -j8  then  make -j\$(nproc) V=s ==="

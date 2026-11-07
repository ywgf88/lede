#!/usr/bin/env bash
# Fail the build if any sysupgrade/factory image exceeds the size budget.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LIMIT_MIB="${LIMIT_MIB:-58}"
LIMIT=$((LIMIT_MIB * 1024 * 1024))

mapfile -t imgs < <(find bin/targets -type f \
	\( -name '*squashfs-sysupgrade*' -o -name '*squashfs-factory*' -o -name '*.itb' \) \
	-print 2>/dev/null | sort)

if [ "${#imgs[@]}" -eq 0 ]; then
	echo "ERROR: no firmware images found under bin/targets" >&2
	exit 1
fi

echo "Firmware size limit: ${LIMIT_MIB} MiB ($((LIMIT)) bytes)"
echo "-------------------------------------------------------------------------------"
fail=0
for f in "${imgs[@]}"; do
	bytes=$(stat -c %s "$f")
	mib=$(awk -v b="$bytes" 'BEGIN { printf "%.2f", b / 1048576 }')
	if [ "$bytes" -gt "$LIMIT" ]; then
		status="OVER LIMIT"
		fail=1
	else
		status="OK"
	fi
	printf '%-9s %8s MiB  %s\n' "$status" "$mib" "$f"
done
echo "-------------------------------------------------------------------------------"

if [ "$fail" -ne 0 ]; then
	echo ""
	echo "Images exceed ${LIMIT_MIB} MiB. Largest installed packages:"
	find bin/packages -type f -name '*.ipk' -printf '%s %p\n' 2>/dev/null \
		| sort -rn | head -20 \
		| awk '{ printf "%8.2f MiB  %s\n", $1/1048576, $2 }' || true
	echo ""
	echo "Fastest fixes, in order:"
	echo "  1. Remove luci-app-vantage (dashboard) if it was enabled."
	echo "  2. In configs/mt7981.seed drop one of the two proxy apps, or drop"
	echo "     shadowsocks-rust / mosdns / hysteria INCLUDE_* options."
	echo "  3. Set CONFIG_TARGET_SQUASHFS_BLOCK_SIZE=1024 (already the default here)."
	echo "  4. Drop extra luci-i18n language packages."
	exit 1
fi

echo "All images are within the ${LIMIT_MIB} MiB budget."

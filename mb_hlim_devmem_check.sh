#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# mb_hlim_devmem_check.sh — exercise MB_HLIM schemata across multiple resctrl
# groups and optionally compare sysfs values with MPAMCFG_MBW_MAX HARDLIM (bit 31)
# read via devmem/busybox devmem/devmem2.
#
# Requirements:
#   - Root
#   - /sys/fs/resctrl mounted (Arm MPAM + MB_HLIM schema)
#   - Optional: devmem2, busybox devmem, or util-linux devmem for HW checks
#
# Usage:
#   ./mb_hlim_devmem_check.sh [options]
#
# Options (environment):
#   RESCTRL_ROOT=/sys/fs/resctrl
#   NUM_GROUPS=4              number of child groups to create (default 4)
#   PREFIX=mbhlim_tst_        directory name prefix (default mbhlim_tst_)
#   CLEANUP=1                 remove test groups on exit (default 1)
#   HW_MAP=/path/to/map       optional; per-group per-domain MSC physical bases (see below)
#   MSC_BASE=0x....           optional; fallback MSC base when no per-domain override is set
#   MSC_BASE0=0x....          optional; MSC base for 1st MBA domain in MB: line (index 0)
#   MSC_BASE1=0x....          optional; MSC base for 2nd MBA domain (index 1), etc.
#   MSC_BASE_<dom>=0x....     optional; e.g. MSC_BASE_1 / MSC_BASE_2 for resctrl domain ids
#                             Resolution: HW_MAP row, then MSC_BASE_<dom>, then MSC_BASE<idx>,
#                             then MSC_BASE.  Multiple MBA domains usually need distinct bases.
#   START_CLOSID=1            first closid / partid for first created group (default 1)
#   START_PARTID=1            alias for START_CLOSID (MPAM naming)
#                             Only used with HW_MAP.  Note: sudo drops env unless you use
#                             sudo env START_PARTID=1 ./mb_hlim_devmem_check.sh
#                             or sudo START_PARTID=1 ./mb_hlim_devmem_check.sh
#
# HW_MAP file format (one MSC per resctrl MBA domain × test group you want checked):
#   # group_index dom_id msc_physical_base_hex
#   0 1 0x12340000
#   0 2 0x12341000
#   1 1 0x12340000
#   ...
# group_index matches creation order (0 .. NUM_GROUPS-1).  partid used for PART_SEL
# is START_CLOSID + group_index (non-CDP MPAM: partid == closid).
#
# Register layout (Arm MPAM IHI0099, matches drivers/resctrl/mpam_internal.h):
#   MPAMCFG_PART_SEL offset 0x100 from MSC reg frame base
#   MPAMCFG_MBW_MAX  offset 0x208 — HARDLIM in bit 31
#
# Caveats:
#   - Physical MSC bases are SoC/firmware specific; the kernel does not expose them
#     in sysfs.  You must fill HW_MAP from your DT/manual.
#   - Reading MBW_MAX requires selecting the partition in PART_SEL on that MSC first.
#   - If your devmem cannot reach high MMIO physical addresses, HW checks will fail.

set -euo pipefail

RESCTRL_ROOT="${RESCTRL_ROOT:-/sys/fs/resctrl}"
NUM_GROUPS="${NUM_GROUPS:-4}"
PREFIX="${PREFIX:-mbhlim_tst_}"
CLEANUP="${CLEANUP:-1}"
HW_MAP="${HW_MAP:-}"
MSC_BASE="${MSC_BASE:-}"
if [[ -n "${START_PARTID:-}" ]]; then
	START_CLOSID="$START_PARTID"
else
	START_CLOSID="${START_CLOSID:-1}"
fi

MPAMCFG_PART_SEL_OFFSET=$((0x100))
MPAMCFG_MBW_MAX_OFFSET=$((0x208))
MPAMCFG_MBW_MAX_HARDLIM=$((1 << 31))

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[*] $*"; }

# First schemata line whose resource key is $1 (e.g. MB), ignoring leading whitespace.
# Prints the original line (may include leading spaces).
get_schemata_line() {
	local key="$1" file="$2"
	awk -v k="$key" '
	function triml(s) { sub(/^[[:space:]]+/, "", s); return s }
	{
		t = triml($0)
		c = index(t, ":")
		if (c > 0 && substr(t, 1, c - 1) == k) { print; exit }
	}
	' "$file"
}

need_root() {
	[[ "$(id -u)" -eq 0 ]] || die "run as root"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Return decimal 32-bit value read from physical address (hex with or without 0x)
devmem_read32() {
	local addr="$1"
	local raw

	if have_cmd busybox; then
		raw="$(busybox devmem "$addr" 32 2>/dev/null)" || return 1
		raw="${raw//$'\r'/}"
		raw="${raw//[[:space:]]/}"
		[[ "$raw" =~ ^0[xX] ]] && raw="${raw#0x}" && raw="${raw#0X}"
		# Busybox prints hex without 0x on some builds; treat as hex if non-decimal.
		if [[ "$raw" =~ [a-fA-F] ]]; then
			echo $((16#$raw))
		else
			echo $((10#$raw))
		fi
		return 0
	fi
	if have_cmd devmem2; then
		raw="$(devmem2 "$addr" w 2>/dev/null)" || return 1
		if [[ "$raw" =~ 0x([0-9a-fA-F]+) ]]; then
			echo $((16#${BASH_REMATCH[1]}))
			return 0
		fi
		if [[ "$raw" =~ ^[0-9]+$ ]]; then
			echo "$raw"
			return 0
		fi
		return 1
	fi
	if have_cmd devmem; then
		raw="$(devmem "$addr" 32 2>/dev/null)" || return 1
		raw="${raw#0x}"
		echo $((16#${raw}))
		return 0
	fi
	return 1
}

devmem_write32() {
	local addr="$1" val="$2"

	if have_cmd busybox; then
		busybox devmem "$addr" 32 "$val"
		return 0
	fi
	if have_cmd devmem2; then
		devmem2 "$addr" w "$val"
		return 0
	fi
	if have_cmd devmem; then
		devmem "$addr" 32 "$val"
		return 0
	fi
	return 1
}

# Prints MPAMCFG_MBW_MAX readback to stderr (raw + HARDLIM bit 31); echoes 0/1 on stdout only.
# Args: base_hex partid [context_label] [expected_mb_hlim]
read_hardlim_hw() {
	local base_hex="$1" partid="$2"
	local ctx="${3:-}"
	local expected="${4:-}"
	local base part_sel_addr mbw_addr v bit31

	base="${base_hex#0x}"
	base=$((16#$base))
	part_sel_addr=$((base + MPAMCFG_PART_SEL_OFFSET))
	mbw_addr=$((base + MPAMCFG_MBW_MAX_OFFSET))

	partid=$((partid & 0xffff))
	devmem_write32 "0x$(printf '%x' "$part_sel_addr")" "$partid" || return 1
	# allow register access to settle
	sleep 0.05
	v="$(devmem_read32 "0x$(printf '%x' "$mbw_addr")")" || return 1
	if (((v & MPAMCFG_MBW_MAX_HARDLIM) != 0)); then
		bit31=1
	else
		bit31=0
	fi
	{
		echo -n "[*] HW MPAMCFG_MBW_MAX"
		[[ -n "$ctx" ]] && printf ' %s' "$ctx"
		printf ' partid=%u base=%s MBW_MAX=0x%08x (%u) HARDLIM(bit31)=%u' \
			"$partid" "$base_hex" "$v" "$v" "$bit31"
		[[ -n "$expected" ]] && printf ' MB_HLIM(expected)=%s' "$expected"
		echo
	} >&2
	echo "$bit31"
}

parse_mb_line_domains() {
	# stdin: one schemata line like "MB:1=50;2=50" or "MB_HLIM:1=0;2=1"
	local line prefix rest pair dom
	read -r line
	line="${line#"${line%%[![:space:]]*}"}"
	[[ "$line" == *:* ]] || return 1
	prefix="${line%%:*}"
	rest="${line#*:}"
	[[ "$prefix" == "$1" ]] || return 1
	IFS=';' read -ra pairs <<< "$rest"
	for pair in "${pairs[@]}"; do
		[[ -z "${pair//[[:space:]]/}" ]] && continue
		dom="${pair%%=*}"
		dom="${dom//[[:space:]]/}"
		[[ -n "$dom" ]] && echo "$dom"
	done
}

parse_mb_hlim_values() {
	# stdin: schemata file; prints "dom val" per domain from MB_HLIM line
	local line t hlim_line
	while IFS= read -r line; do
		t="${line#"${line%%[![:space:]]*}"}"
		[[ "$t" == MB_HLIM:* ]] && hlim_line="$t"
	done
	[[ -n "${hlim_line:-}" ]] || return 1
	local rest pair dom val
	rest="${hlim_line#MB_HLIM:}"
	IFS=';' read -ra pairs <<< "$rest"
	for pair in "${pairs[@]}"; do
		[[ -z "${pair//[[:space:]]/}" ]] && continue
		dom="${pair%%=*}"
		val="${pair#*=}"
		dom="${dom//[[:space:]]/}"
		val="${val//[[:space:]]/}"
		echo "$dom $val"
	done
}

build_schemata_with_mb_hlim() {
	local template_file="$1"
	local hlim_spec="$2" # e.g. "1=0;2=1"
	local out line replaced

	replaced=0
	while IFS= read -r line || [[ -n "$line" ]]; do
		local stripped="${line#"${line%%[![:space:]]*}"}"
		if [[ "$stripped" == MB_HLIM:* ]]; then
			echo "MB_HLIM:$hlim_spec"
			replaced=1
		else
			echo "$line"
		fi
	done < "$template_file"
	[[ "$replaced" -eq 1 ]] || echo "MB_HLIM:$hlim_spec"
}

cleanup_groups() {
	local g t
	for g in "$RESCTRL_ROOT"/${PREFIX}*; do
		[[ -d "$g" ]] || continue
		if [[ -f "$g/tasks" ]]; then
			while read -r t; do
				[[ -n "$t" ]] || continue
				echo "$t" > "$RESCTRL_ROOT/tasks" 2>/dev/null || true
			done < "$g/tasks"
		fi
		if [[ -d "$g/mon_groups" ]]; then
			find "$g/mon_groups" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | while read -r m; do
				[[ -d "$m" ]] || continue
				if [[ -f "$m/tasks" ]]; then
					while read -r t; do
						[[ -n "$t" ]] || continue
						echo "$t" > "$RESCTRL_ROOT/tasks" 2>/dev/null || true
					done < "$m/tasks"
				fi
				rmdir "$m" 2>/dev/null || true
			done
			rmdir "$g/mon_groups" 2>/dev/null || true
		fi
		rmdir "$g" 2>/dev/null || true
	done
}

trap '[[ "$CLEANUP" == 1 ]] && cleanup_groups' EXIT

main() {
	need_root
	[[ -d "$RESCTRL_ROOT" ]] || die "missing $RESCTRL_ROOT (mount resctrl)"
	[[ -r "$RESCTRL_ROOT/schemata" ]] || die "cannot read $RESCTRL_ROOT/schemata"

	log "reading template schemata from $RESCTRL_ROOT"
	local tmpl
	tmpl="$(mktemp)"
	cat "$RESCTRL_ROOT/schemata" > "$tmpl"
	get_schemata_line MB "$tmpl" >/dev/null || die "no MB: line in root schemata (MBA not exposed?)"
	get_schemata_line MB_HLIM "$tmpl" >/dev/null || die "no MB_HLIM: line in root schemata (MPAM MB_HLIM missing?)"

	local -a domains
	mapfile -t domains < <(parse_mb_line_domains "MB" < <(get_schemata_line MB "$tmpl"))
	((${#domains[@]} > 0)) || die "could not parse MBA domain ids from MB: line"

	log "MBA domains: ${domains[*]}"
	if [[ -n "${MSC_BASE:-}" ]]; then
		log "MSC_BASE=$MSC_BASE (fallback when no MSC_BASE_<dom>/MSC_BASE<idx>)"
	fi
	if [[ -n "${HW_MAP:-}" && ! -r "$HW_MAP" ]]; then
		log "warning: HW_MAP not readable ($HW_MAP); using MSC_BASE fallback only if set"
	fi

	cleanup_groups

	local i d hlim_pairs dom val expected hw mismatches
	mismatches=0

	for ((i = 0; i < NUM_GROUPS; i++)); do
		local gname="${PREFIX}${i}"
		local gpath="$RESCTRL_ROOT/$gname"
		mkdir "$gpath"

		hlim_pairs=""
		for d in "${domains[@]}"; do
			val=$(( (i + d) % 2 ))
			[[ -n "$hlim_pairs" ]] && hlim_pairs+=";"
			hlim_pairs+="$d=$val"
		done

		local new_sch
		new_sch="$(mktemp)"
		build_schemata_with_mb_hlim "$tmpl" "$hlim_pairs" > "$new_sch"
		cp "$new_sch" "$gpath/schemata"
		rm -f "$new_sch"

		log "group $gname: wrote MB_HLIM:$hlim_pairs"

		while read -r dom val; do
			expected="$val"
			# sysfs readback
			local got
			got="$(parse_mb_hlim_values < "$gpath/schemata" | awk -v d="$dom" '$1==d {print $2; exit}')"
			if [[ "$got" != "$expected" ]]; then
				echo "mismatch sysfs $gname dom $dom: expected $expected got $got" >&2
				((mismatches++)) || true
			fi

			local base partid dom_idx nvar dvar
			base=""
			if [[ -n "${HW_MAP:-}" && -r "$HW_MAP" ]]; then
				base="$(awk -v gi="$i" -v dd="$dom" '$1==gi && $2==dd {print $3; exit}' "$HW_MAP")"
			fi
			dom_idx=-1
			for di in "${!domains[@]}"; do
				if [[ "${domains[$di]}" == "$dom" ]]; then
					dom_idx=$di
					break
				fi
			done
			if [[ -z "$base" ]]; then
				dvar="MSC_BASE_${dom}"
				if [[ -n "${!dvar:-}" ]]; then
					base="${!dvar}"
				fi
			fi
			if [[ -z "$base" && "$dom_idx" -ge 0 ]]; then
				nvar="MSC_BASE${dom_idx}"
				if [[ -n "${!nvar:-}" ]]; then
					base="${!nvar}"
				fi
			fi
			if [[ -z "$base" && -n "${MSC_BASE:-}" ]]; then
				base="$MSC_BASE"
			fi
			if [[ -n "$base" ]]; then
				partid=$((START_CLOSID + i))
				hw="$(read_hardlim_hw "$base" "$partid" "$gname dom=$dom" "$expected")" || {
					echo "HW read failed group $gname dom $dom base $base partid $partid" >&2
					((mismatches++)) || true
					continue
				}
				if [[ "$hw" != "$expected" ]]; then
					echo "mismatch HW $gname dom $dom partid $partid: expected $expected got $hw (base $base)" >&2
					((mismatches++)) || true
				fi
			elif [[ -n "${HW_MAP:-}" && -r "$HW_MAP" ]]; then
				log "HW_MAP: no entry for group_index=$i dom=$dom (skip HW)"
			fi
		done < <(parse_mb_hlim_values < "$gpath/schemata")
	done

	rm -f "$tmpl"

	if [[ "$mismatches" -ne 0 ]]; then
		die "$mismatches mismatch(es)"
	fi
	log "all checks passed"
}

main "$@"

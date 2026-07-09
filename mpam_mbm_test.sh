#!/bin/bash
# SPDX-License-Identifier: GPL-2.0
#
# MPAM MBM sysfs test matrix for Grace and Vera platforms.
#
# Verifies mbm_total_bytes placement, ABMC assignment files, assign/unassign,
# and mbm_total_bytes growth under a resctrl partition during stress-ng traffic.
#
# Usage:
#   sudo ./mpam_mbm_test.sh [--platform grace|vera|auto] [--no-traffic] [--monitor-secs N]
#
# Copyright (C) 2026 NVIDIA Corporation

set -euo pipefail

RESCTRL_PATH="/sys/fs/resctrl"
INFO_PATH="${RESCTRL_PATH}/info"
MON_DATA="${RESCTRL_PATH}/mon_data"
KSFT_SKIP=4

PLATFORM="auto"
NO_TRAFFIC=0
MONITOR_SECS=60
TEST_PARTITION="partition_1"
PARTITION_PATH=""
STRESS_PID=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
DETECTED_PLATFORM=""
ASSIGN_FILE=""
MBM_MON_PREFIX=""
FIRST_DOMAIN=""
MONITOR_DOMAIN=""
ASSIGN_SAVED=""
ASSIGN_MODE_SAVED=""
MOUNTED_HERE=0

usage()
{
	cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --platform grace|vera|auto  Expected mbm_total_bytes layout (default: auto)
  --no-traffic                Skip stress-ng / mbm_total_bytes growth test
  --monitor-secs N            Seconds to monitor mbm_total_bytes (default: 60)
  -h, --help                  Show this help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	--platform)
		PLATFORM="$2"
		shift 2
		;;
	--no-traffic)
		NO_TRAFFIC=1
		shift
		;;
	--monitor-secs)
		MONITOR_SECS="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "Unknown option: $1" >&2
		usage
		exit 1
		;;
	esac
done

log_msg()
{
	printf '# %s\n' "$*"
}

pass()
{
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_PASSED=$((TESTS_PASSED + 1))
	log_msg "PASS: $*"
}

fail()
{
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	log_msg "FAIL: $*"
}

skip_test()
{
	log_msg "SKIP: $*"
}

skip_all()
{
	log_msg "SKIP: $*"
	exit $KSFT_SKIP
}

check_root()
{
	if [ "$(id -u)" -ne 0 ]; then
		echo "Run as root (resctrl mount and cgroup changes required)" >&2
		exit $KSFT_SKIP
	fi
}

check_mpam()
{
	if [ ! -d "${INFO_PATH}/L3" ] && [ ! -d "${INFO_PATH}/MB" ]; then
		skip_all "resctrl L3/MB info not present (MPAM/resctrl not enabled?)"
	fi

	case "$(uname -m)" in
	aarch64 | arm64) ;;
	*)
		skip_all "not an aarch64 platform (uname -m=$(uname -m))"
		;;
	esac
}

mount_resctrl()
{
	if mountpoint -q "$RESCTRL_PATH"; then
		return 0
	fi

	mkdir -p "$RESCTRL_PATH"
	if mount -t resctrl resctrl "$RESCTRL_PATH" 2>/dev/null; then
		MOUNTED_HERE=1
		return 0
	fi

	skip_all "resctrl not mounted at ${RESCTRL_PATH}"
}

umount_resctrl()
{
	if [ "$MOUNTED_HERE" -eq 1 ]; then
		umount "$RESCTRL_PATH" 2>/dev/null || true
	fi
}

mon_dirs_with_file()
{
	local prefix="$1"
	local file="$2"
	local dir path

	# Match only numeric domain ids (mon_L3_02, mon_MB_00). Control-only
	# resources create empty monitor directories whose names share the
	# prefix (mon_L3_MAX_02, mon_MB_HLIM_00) and must not match.
	for dir in "${MON_DATA}/${prefix}"[0-9][0-9]; do
		[ -d "$dir" ] || continue
		path="${dir}/${file}"
		if [ -f "$path" ]; then
			echo "$dir"
		fi
	done
}

count_mon_dirs_with_file()
{
	local prefix="$1"
	local file="$2"

	mon_dirs_with_file "$prefix" "$file" | wc -l
}

detect_platform()
{
	local l3_mbm mb_mbm

	l3_mbm=$(count_mon_dirs_with_file "mon_L3_" "mbm_total_bytes")
	mb_mbm=$(count_mon_dirs_with_file "mon_MB_" "mbm_total_bytes")

	if [ "$l3_mbm" -gt 0 ] && [ "$mb_mbm" -eq 0 ]; then
		DETECTED_PLATFORM="grace"
	elif [ "$mb_mbm" -gt 0 ] && [ "$l3_mbm" -eq 0 ]; then
		DETECTED_PLATFORM="vera"
	elif [ "$l3_mbm" -gt 0 ] && [ "$mb_mbm" -gt 0 ]; then
		DETECTED_PLATFORM="mixed"
	elif [ -f "${RESCTRL_PATH}/mbm_MB_assignments" ] &&
		grep -q "mbm_total_bytes:" "${RESCTRL_PATH}/mbm_MB_assignments" 2>/dev/null; then
		DETECTED_PLATFORM="vera"
	elif [ -f "${RESCTRL_PATH}/mbm_L3_assignments" ] &&
		grep -q "mbm_total_bytes:" "${RESCTRL_PATH}/mbm_L3_assignments" 2>/dev/null; then
		DETECTED_PLATFORM="grace"
	else
		DETECTED_PLATFORM="unknown"
	fi

	case "$PLATFORM" in
	auto) ;;
	grace | vera)
		if [ "$DETECTED_PLATFORM" != "$PLATFORM" ] &&
			[ "$DETECTED_PLATFORM" != "unknown" ] &&
			[ "$DETECTED_PLATFORM" != "mixed" ]; then
			fail "platform mismatch: expected ${PLATFORM}, detected ${DETECTED_PLATFORM}"
			DETECTED_PLATFORM="invalid"
			return
		fi
		DETECTED_PLATFORM="$PLATFORM"
		;;
	*)
		echo "Invalid --platform value: ${PLATFORM}" >&2
		exit 1
		;;
	esac

	case "$DETECTED_PLATFORM" in
	grace)
		ASSIGN_FILE="${RESCTRL_PATH}/mbm_L3_assignments"
		MBM_MON_PREFIX="mon_L3_"
		MONITOR_DOMAIN="1"
		log_msg "Detected platform profile: grace"
		;;
	vera)
		ASSIGN_FILE="${RESCTRL_PATH}/mbm_MB_assignments"
		MBM_MON_PREFIX="mon_MB_"
		MONITOR_DOMAIN="0"
		log_msg "Detected platform profile: vera"
		;;
	mixed)
		fail "mbm_total_bytes appears under both mon_L3_* and mon_MB_*"
		;;
	unknown | invalid)
		fail "could not detect Grace/Vera MBM layout from mon_data"
		;;
	esac
}

platform_profile_ok()
{
	[ "$DETECTED_PLATFORM" = "grace" ] || [ "$DETECTED_PLATFORM" = "vera" ]
}

test_llc_occupancy()
{
	local dir count=0

	for dir in "${MON_DATA}/mon_L3_"[0-9][0-9]; do
		[ -d "$dir" ] || continue
		count=$((count + 1))
		if [ ! -f "${dir}/llc_occupancy" ]; then
			fail "missing llc_occupancy in $(basename "$dir")"
			return
		fi
	done

	if [ "$count" -eq 0 ]; then
		fail "no mon_L3_* monitor directories found"
		return
	fi

	pass "llc_occupancy present in all ${count} mon_L3_[0-9][0-9] directories"
}

test_mbm_total_placement()
{
	if ! platform_profile_ok; then
		return
	fi

	local dir count wrong_prefix

	count=$(count_mon_dirs_with_file "$MBM_MON_PREFIX" "mbm_total_bytes")
	if [ "$count" -eq 0 ]; then
		fail "mbm_total_bytes missing under ${MBM_MON_PREFIX}* (${DETECTED_PLATFORM})"
		return
	fi

	pass "mbm_total_bytes present under ${count} ${MBM_MON_PREFIX}* directories"

	if [ "$DETECTED_PLATFORM" = "grace" ]; then
		wrong_prefix="mon_MB_"
	elif [ "$DETECTED_PLATFORM" = "vera" ]; then
		wrong_prefix="mon_L3_"
	else
		return
	fi

	if [ "$(count_mon_dirs_with_file "$wrong_prefix" "mbm_total_bytes")" -gt 0 ]; then
		fail "mbm_total_bytes must not appear under ${wrong_prefix}* on ${DETECTED_PLATFORM}"
	else
		pass "mbm_total_bytes absent from ${wrong_prefix}* (${DETECTED_PLATFORM})"
	fi
}

test_mon_mb_dirs_not_empty_on_vera()
{
	local dir empty=0 total=0

	if [ "$DETECTED_PLATFORM" != "vera" ]; then
		return
	fi

	for dir in "${MON_DATA}/mon_MB_"[0-9][0-9]; do
		[ -d "$dir" ] || continue
		total=$((total + 1))
		if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
			empty=$((empty + 1))
		fi
	done

	if [ "$total" -eq 0 ]; then
		fail "no mon_MB_* directories on Vera profile"
	elif [ "$empty" -gt 0 ]; then
		fail "${empty}/${total} mon_MB_* directories are empty on Vera"
	else
		pass "all ${total} mon_MB_* directories expose monitor files"
	fi
}

test_assignments_populated()
{
	if ! platform_profile_ok; then
		return
	fi

	local line

	if [ ! -f "$ASSIGN_FILE" ]; then
		fail "missing ${ASSIGN_FILE}"
		return
	fi

	line=$(grep -m1 "^mbm_total_bytes:" "$ASSIGN_FILE" 2>/dev/null || true)
	if [ -z "$line" ]; then
		fail "${ASSIGN_FILE} has no mbm_total_bytes assignment line"
		return
	fi

	if ! echo "$line" | grep -qE '=[e_]'; then
		fail "${ASSIGN_FILE} line malformed: ${line}"
		return
	fi

	FIRST_DOMAIN=$(echo "$line" | sed -n 's/.*:\([0-9]*\)=.*/\1/p' | head -1)
	if [ -z "$FIRST_DOMAIN" ]; then
		fail "could not parse domain id from: ${line}"
		return
	fi

	pass "${ASSIGN_FILE} lists mbm_total_bytes domains (e.g. domain ${FIRST_DOMAIN})"
}

mon_info_path()
{
	if [ "$DETECTED_PLATFORM" = "vera" ]; then
		echo "${INFO_PATH}/MB_MON"
	else
		echo "${INFO_PATH}/L3_MON"
	fi
}

available_mbm_cntrs_for_domain()
{
	local dom="$1"
	local info line avail

	info=$(mon_info_path)
	line=$(cat "${info}/available_mbm_cntrs" 2>/dev/null || true)
	avail=$(echo "$line" | tr ';' '\n' | sed -n "s/^${dom}=//p" | head -1)
	echo "${avail:-0}"
}

domain_assign_state()
{
	local dom="$1"
	local line rest

	line=$(grep -m1 "^mbm_total_bytes:" "$ASSIGN_FILE" 2>/dev/null || true)
	rest="${line#mbm_total_bytes:}"
	echo "$rest" | tr ';' '\n' | sed -n "s/^${dom}=//p" | head -1
}

assignment_domains()
{
	local line rest

	line=$(grep -m1 "^mbm_total_bytes:" "$ASSIGN_FILE" 2>/dev/null || true)
	rest="${line#mbm_total_bytes:}"
	echo "$rest" | tr ';' '\n' | sed -n 's/^\([0-9]*\)=.*/\1/p'
}

restore_assign_mode()
{
	local mode_file

	[ -n "$ASSIGN_MODE_SAVED" ] || return 0

	mode_file="$(mon_info_path)/mbm_assign_mode"
	[ -f "$mode_file" ] || return 0

	if echo "$ASSIGN_MODE_SAVED" | grep -q '^\[default\]'; then
		echo default >"$mode_file" 2>/dev/null || true
	elif echo "$ASSIGN_MODE_SAVED" | grep -q '^\[mbm_event\]'; then
		echo mbm_event >"$mode_file" 2>/dev/null || true
	fi
}

ensure_mbm_assign_mode()
{
	local mode_file mode

	mode_file="$(mon_info_path)/mbm_assign_mode"
	[ -f "$mode_file" ] || return 0

	mode=$(cat "$mode_file")
	if [ -z "$ASSIGN_MODE_SAVED" ]; then
		ASSIGN_MODE_SAVED="$mode"
	fi

	if echo "$mode" | grep -q '^\[default\]'; then
		if ! echo mbm_event >"$mode_file" 2>/dev/null; then
			fail "failed to enable mbm_event in $(basename "$mode_file")"
			return 1
		fi
		log_msg "Enabled mbm_event assign mode"
	fi

	return 0
}

enable_mbm_total_bytes_config()
{
	local cfg dom val line new_cfg sep

	cfg="$(mon_info_path)/mbm_total_bytes_config"
	[ -f "$cfg" ] || return 0

	line=$(cat "$cfg" 2>/dev/null || true)
	new_cfg=""
	sep=""
	for dom in $(assignment_domains); do
		val=$(echo "$line" | tr ';' '\n' | sed -n "s/^${dom}=0x//p" | head -1)
		if [ -z "$val" ] || [ "$val" = "00" ]; then
			val="ff"
		fi
		new_cfg="${new_cfg}${sep}${dom}=0x${val}"
		sep=";"
	done

	[ -n "$new_cfg" ] || return 0

	if ! printf '%s\n' "$new_cfg" >"$cfg" 2>/dev/null; then
		fail "failed to configure $(basename "$cfg")"
		return 1
	fi

	log_msg "Configured $(basename "$cfg"): ${new_cfg}"
	return 0
}

enable_mbm_total_assignments()
{
	if ! platform_profile_ok; then
		return
	fi

	local before after

	if [ -z "$FIRST_DOMAIN" ]; then
		fail "enable mbm_total_bytes skipped: no domain id"
		return
	fi

	before=$(grep -m1 "^mbm_total_bytes:" "$ASSIGN_FILE" 2>/dev/null || true)
	if [ -z "$before" ]; then
		fail "no mbm_total_bytes line in ${ASSIGN_FILE}"
		return
	fi
	if [ -z "$ASSIGN_SAVED" ]; then
		ASSIGN_SAVED="$before"
	fi

	ensure_mbm_assign_mode || return
	enable_mbm_total_bytes_config || return

	if ! echo "mbm_total_bytes:*=e" >"$ASSIGN_FILE" 2>/dev/null; then
		fail "failed to enable mbm_total_bytes via $(basename "$ASSIGN_FILE")"
		return
	fi

	after=$(grep -m1 "^mbm_total_bytes:" "$ASSIGN_FILE" 2>/dev/null || true)
	if ! echo "$after" | grep -qE '=[e]'; then
		fail "mbm_total_bytes not assigned after enable: ${after}"
		return
	fi

	if [ "$(domain_assign_state "$FIRST_DOMAIN")" != "e" ]; then
		fail "mbm_total_bytes not enabled on domain ${FIRST_DOMAIN}: ${after}"
		return
	fi

	pass "enabled mbm_total_bytes in $(basename "$ASSIGN_FILE")"
}

restore_assignments()
{
	local part dom state rest

	[ -n "$ASSIGN_SAVED" ] || return 0
	[ -f "$ASSIGN_FILE" ] || return 0

	rest="${ASSIGN_SAVED#mbm_total_bytes:}"
	for part in ${rest//;/ }; do
		dom="${part%%=*}"
		state="${part#*=}"
		echo "mbm_total_bytes:${dom}=${state}" >"$ASSIGN_FILE" 2>/dev/null || true
	done
}

test_assign_unassign()
{
	if ! platform_profile_ok; then
		return
	fi

	local after assign_back state

	if [ -z "$FIRST_DOMAIN" ]; then
		fail "assign/unassign skipped: no domain id"
		return
	fi

	state=$(domain_assign_state "$FIRST_DOMAIN")
	if [ "$state" != "e" ]; then
		fail "mbm_total_bytes not assigned on domain ${FIRST_DOMAIN} (state=${state})"
		return
	fi

	if ! echo "mbm_total_bytes:${FIRST_DOMAIN}=_" >"$ASSIGN_FILE" 2>/dev/null; then
		fail "write unassign mbm_total_bytes:${FIRST_DOMAIN}=_ failed"
		return
	fi

	after=$(grep -m1 "^mbm_total_bytes:" "$ASSIGN_FILE")
	if ! echo "$after" | grep -q "${FIRST_DOMAIN}=_"; then
		fail "unassign did not stick: ${after}"
		return
	fi

	if ! echo "mbm_total_bytes:${FIRST_DOMAIN}=e" >"$ASSIGN_FILE" 2>/dev/null; then
		fail "write assign mbm_total_bytes:${FIRST_DOMAIN}=e failed"
		return
	fi

	assign_back=$(grep -m1 "^mbm_total_bytes:" "$ASSIGN_FILE")
	if ! echo "$assign_back" | grep -q "${FIRST_DOMAIN}=e"; then
		fail "assign did not stick: ${assign_back}"
		return
	fi

	pass "mbm_total_bytes assign/unassign on domain ${FIRST_DOMAIN}"
}

read_mbm_counter()
{
	local target="$1"
	local val

	if [ -f "$target" ]; then
		val=$(cat "$target" 2>/dev/null | tr -d '\n')
	else
		val=$(cat "${target}/mbm_total_bytes" 2>/dev/null | tr -d '\n')
	fi
	echo "$val"
}

mbm_monitor_file()
{
	if [ "$DETECTED_PLATFORM" = "grace" ]; then
		echo "${PARTITION_PATH}/mon_data/mon_L3_01/mbm_total_bytes"
	else
		echo "${PARTITION_PATH}/mon_data/mon_MB_00/mbm_total_bytes"
	fi
}

partition_assign_file()
{
	echo "${PARTITION_PATH}/$(basename "$ASSIGN_FILE")"
}

stop_stress_ng()
{
	if [ -n "$STRESS_PID" ] && kill -0 "$STRESS_PID" 2>/dev/null; then
		kill -TERM "$STRESS_PID" 2>/dev/null || true
		wait "$STRESS_PID" 2>/dev/null || true
	fi
	STRESS_PID=""
}

destroy_test_partition()
{
	local pid

	stop_stress_ng

	[ -n "$PARTITION_PATH" ] || PARTITION_PATH="${RESCTRL_PATH}/${TEST_PARTITION}"
	[ -d "$PARTITION_PATH" ] || return 0

	echo $$ >"${RESCTRL_PATH}/tasks" 2>/dev/null || true
	sleep 0.5

	if [ -f "${PARTITION_PATH}/tasks" ]; then
		while read -r pid; do
			[ -n "$pid" ] || continue
			[ "$pid" -eq $$ ] && continue
			kill "$pid" 2>/dev/null || true
		done <"${PARTITION_PATH}/tasks"
	fi

	sleep 0.5
	rmdir "$PARTITION_PATH" 2>/dev/null || true
	PARTITION_PATH=""
}

cleanup_stale_partition()
{
	PARTITION_PATH="${RESCTRL_PATH}/${TEST_PARTITION}"
	destroy_test_partition
}

create_test_partition()
{
	local part_assign

	PARTITION_PATH="${RESCTRL_PATH}/${TEST_PARTITION}"
	destroy_test_partition

	# Only one RMID counter per domain: release root assignments first.
	if ! echo "mbm_total_bytes:*=_" >"$ASSIGN_FILE" 2>/dev/null; then
		fail "could not unassign root mbm_total_bytes before ${TEST_PARTITION}"
		return 1
	fi

	if ! mkdir "$PARTITION_PATH" 2>/dev/null; then
		fail "could not create resctrl partition ${TEST_PARTITION}"
		return 1
	fi

	part_assign=$(partition_assign_file)
	if ! echo "mbm_total_bytes:${MONITOR_DOMAIN}=e" >"$part_assign" 2>/dev/null; then
		fail "could not enable mbm_total_bytes:${MONITOR_DOMAIN}=e in ${part_assign}"
		destroy_test_partition
		return 1
	fi

	if ! echo $$ >"${PARTITION_PATH}/tasks" 2>/dev/null; then
		fail "could not move test shell into ${TEST_PARTITION}/tasks"
		destroy_test_partition
		return 1
	fi

	log_msg "Created ${TEST_PARTITION}, assigned domain ${MONITOR_DOMAIN}, attached shell to tasks"
	return 0
}

is_numeric_counter()
{
	local val="$1"

	[ -n "$val" ] || return 1
	case "$val" in
	Unavailable | Unassigned) return 1 ;;
	esac
	echo "$val" | grep -qE '^[0-9]+$'
}

test_mbm_counter_growth()
{
	if ! platform_profile_ok; then
		return
	fi

	local mon_file start end now val last first decreased=0
	local seen_numeric=0 sample=0

	if [ "$NO_TRAFFIC" -eq 1 ]; then
		log_msg "SKIP (by request): stress-ng mbm_total_bytes growth test"
		return
	fi

	if ! command -v stress-ng >/dev/null 2>&1; then
		skip_test "stress-ng not installed"
		return
	fi

	if ! command -v numactl >/dev/null 2>&1; then
		skip_test "numactl not installed"
		return
	fi

	create_test_partition || return

	mon_file=$(mbm_monitor_file)
	if [ ! -f "$mon_file" ]; then
		fail "missing monitor file ${mon_file}"
		destroy_test_partition
		return
	fi

	log_msg "Running stress-ng on node 0, monitoring ${mon_file} for ${MONITOR_SECS}s"
	numactl -N 0 -m 0 stress-ng --stream "$(nproc)" \
		--stream-l3-size 160m --stream-madvise hugepage >/dev/null 2>&1 &
	STRESS_PID=$!

	start=$(date +%s)
	end=$((start + MONITOR_SECS))
	last=""
	first=""

	while [ "$(date +%s)" -lt "$end" ]; do
		val=$(read_mbm_counter "$mon_file")
		if is_numeric_counter "$val"; then
			sample=$((sample + 1))
			if [ -z "$first" ]; then
				first="$val"
			fi
			if [ -n "$last" ] && [ "$val" -lt "$last" ]; then
				decreased=1
				log_msg "mbm_total_bytes decreased: ${last} -> ${val}"
			fi
			last="$val"
			seen_numeric=1
		fi
		sleep 2
	done

	stop_stress_ng
	destroy_test_partition

	if [ "$decreased" -eq 1 ]; then
		fail "mbm_total_bytes decreased during ${MONITOR_SECS}s monitoring (last=${last})"
		return
	fi

	if [ "$seen_numeric" -eq 0 ]; then
		fail "mbm_total_bytes never readable during ${MONITOR_SECS}s monitoring"
		return
	fi

	if [ -n "$first" ] && [ -n "$last" ] && [ "$last" -le "$first" ]; then
		fail "mbm_total_bytes did not grow (${first} -> ${last} over ${sample} samples)"
		return
	fi

	pass "mbm_total_bytes grew during stress-ng (${first} -> ${last}, ${sample} samples)"
}

cleanup()
{
	destroy_test_partition
	restore_assignments
	restore_assign_mode
	umount_resctrl
}

trap cleanup EXIT

log_msg "MPAM MBM sysfs test matrix"
check_root
mount_resctrl
check_mpam
detect_platform
cleanup_stale_partition
test_llc_occupancy
test_mbm_total_placement
test_mon_mb_dirs_not_empty_on_vera
test_assignments_populated
enable_mbm_total_assignments
test_assign_unassign
test_mbm_counter_growth

log_msg "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"
if [ "$TESTS_FAILED" -gt 0 ]; then
	exit 1
fi
exit 0

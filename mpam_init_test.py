#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""
Read and decode MPAM MSC registers given the MSC base address (physical).
Requires root. Base is the physical address (e.g. "Base address:" from ACPI MPAM.dsl).
Uses mmap(/dev/mem) by default; if that fails (e.g. EINVAL on high addresses),
use --devmem2 to read/write via devmem2 instead.

Usage: mpam_show_regs.py <base_hex> [num_ris] [max_partid] [--devmem2]
  base_hex   - MSC base address in hex (e.g. 0xfe147000b0000)
  num_ris    - number of RIS to dump (default: from IDR)
  max_partid - max PARTID to dump config for (default: 2)
  --devmem2  - use devmem2 for register access (try this if mmap fails)
"""

import argparse
import mmap
import os
import re
import shutil
import struct
import subprocess
import sys

# Register offsets (from drivers/resctrl/mpam_internal.h)
MPAMF_IDR       = 0x0000
MPAMF_IDR_HI    = 0x0004
MPAMF_IIDR      = 0x0018
MPAMF_AIDR      = 0x0020
MPAMF_CPOR_IDR  = 0x0030
MPAMF_CCAP_IDR  = 0x0038
MPAMF_MBW_IDR   = 0x0040
MPAMF_PRI_IDR   = 0x0048
MPAMF_MSMON_IDR = 0x0080
MPAMF_CSUMON_IDR   = 0x0088
MPAMF_MBWUMON_IDR  = 0x0090
MPAMCFG_PART_SEL = 0x0100
MPAMCFG_CMAX    = 0x0108
MPAMCFG_CMIN    = 0x0110
MPAMCFG_CASSOC  = 0x0118
MPAMCFG_MBW_MIN = 0x0200
MPAMCFG_MBW_MAX = 0x0208
MPAMCFG_PRI     = 0x0400
MPAMCFG_CPBM    = 0x1000
MPAMCFG_MBW_PBM = 0x2000
MPAMF_ESR       = 0x00F8

# IDR bit masks (64-bit IDR: low 32 bits + high 32 bits)
def bit(n): return (1 << n)
def genmask(h, l): return ((1 << (h - l + 1)) - 1) << l

IDR_PARTID_MAX   = genmask(15, 0)
IDR_PMG_MAX      = genmask(23, 16)
IDR_HAS_CCAP_PART = bit(24)
IDR_HAS_CPOR_PART = bit(25)
IDR_HAS_MBW_PART  = bit(26)
IDR_HAS_PRI_PART  = bit(27)
IDR_EXT           = bit(28)
IDR_HAS_MSMON     = bit(30)
IDR_HAS_PARTID_NRW = bit(31)
IDR_HAS_RIS       = 1 << 32   # in high word
IDR_RIS_MAX       = (0xF << 56)  # bits 56-59 of 64-bit IDR
IDR_HAS_ESR       = bit(39)
IDR_HAS_EXTD_ESR  = bit(38)

CPOR_IDR_CPBM_WD   = genmask(15, 0)
CCAP_IDR_CMAX_WD   = genmask(5, 0)
CCAP_IDR_CASSOC_WD = genmask(12, 8)
CCAP_IDR_HAS_CASSOC = bit(28)
CCAP_IDR_HAS_CMIN   = bit(29)
CCAP_IDR_NO_CMAX    = bit(30)
CCAP_IDR_HAS_CMAX_SOFTLIM = bit(31)

MBW_IDR_BWA_WD    = genmask(5, 0)
MBW_IDR_HAS_MIN   = bit(10)
MBW_IDR_HAS_MAX   = bit(11)
MBW_IDR_HAS_PBM   = bit(12)
MBW_IDR_BWPBM_WD  = genmask(28, 16)

MSMON_IDR_MSMON_CSU   = bit(16)
MSMON_IDR_MSMON_MBWU  = bit(17)
CSUMON_IDR_NUM_MON    = genmask(15, 0)
MBWUMON_IDR_NUM_MON   = genmask(15, 0)
MBWUMON_IDR_HAS_LONG  = bit(30)

PART_SEL_PARTID_SEL = genmask(15, 0)
PART_SEL_RIS        = genmask(27, 24)

CMAX_CMAX     = genmask(15, 0)
CMAX_SOFTLIM  = bit(31)
CMIN_CMIN     = genmask(15, 0)
MBW_MIN_MIN   = genmask(15, 0)
MBW_MAX_MAX   = genmask(15, 0)
MBW_MAX_HARDLIM = bit(31)
PRI_INTPRI    = genmask(15, 0)
PRI_DSPRI     = genmask(31, 16)


def expected_cmax_from_ccap(ccap):
    """Expected CMAX reset value from CCAP_IDR (CMAX_WD): all allowed bits set."""
    cmax_wd = ccap & CCAP_IDR_CMAX_WD
    if not cmax_wd:
        return 0xffff
    return (1 << cmax_wd) - 1


def cmax_allowed_mask(ccap):
    """
    Mask of CMAX allowed bits from CCAP_IDR (CMAX_WD), shifted into the high byte.
    E.g. cmax_wd=7 -> 0x7f00. Check (read_val & mask) == mask.
    """
    cmax_wd = ccap & CCAP_IDR_CMAX_WD
    if not cmax_wd:
        return 0xffff
    return ((1 << cmax_wd) - 1) << 8


# Same as kernel MPAMCFG_MBW_MAX_MAX (GENMASK(15,0))
MPAMCFG_MBW_MAX_MAX = 0xFFFF


def _cpbm_effective_wd(cpor):
    """CPBM_WD from CPOR_IDR, capped at 32 for u32 register compare. 0 if absent."""
    cpbm_wd = cpor & CPOR_IDR_CPBM_WD
    if not cpbm_wd:
        return 0
    return min(cpbm_wd, 32)


def cpbm_expected_genmask_hi(cpor):
    """High index h for GENMASK(h, 0) matching expected_cpbm_from_cpor_idr (or -1 if N/A)."""
    wd = _cpbm_effective_wd(cpor)
    return wd - 1 if wd else -1


def expected_cpbm_from_cpor_idr(cpor):
    """
    Expected CPBM after Linux MPAM driver init.

    drivers/resctrl/mpam_devices.c mpam_init_reset_cfg() sets:
        reset_cfg->cpbm = GENMASK(props->cpbm_wd - 1, 0);

    cpbm_wd is MPAMF_CPOR_IDR[15:0] (CPBM_WD). Values > 32 are capped for a 32-bit
    register compare (driver stores cpbm in u32).
    """
    wd = _cpbm_effective_wd(cpor)
    return (1 << wd) - 1 if wd else 0


def expected_mbw_max_from_mbw_idr(_mbw):
    """
    Expected MBW_MAX after Linux MPAM driver init.

    drivers/resctrl/mpam_devices.c mpam_init_reset_cfg() sets:
        reset_cfg->mbw_max = MPAMCFG_MBW_MAX_MAX;  /* GENMASK(15,0) == 0xffff */

    Arm MPAM can describe a smaller *architectural* encoding range via BWA_WD
    (e.g. GENMASK(15, 16 - bwa_wd) — for bwa_wd=7 that would be 0xfe00), but
    this kernel uses full 16-bit scale for the software default, not BWA_WD.
    """
    return MPAMCFG_MBW_MAX_MAX


def mbw_bwa_significant_mask(bwa_wd):
    """
    Mask of non-RES0 bits in the 16-bit BWA value for a given BWA_WD.
    Low (16 - bwa_wd) bits are RES0 and often read back as 0 from MPAMCFG_MBW_*.
    """
    if not bwa_wd or bwa_wd >= 16:
        return 0xFFFF
    res0_bits = 16 - bwa_wd
    return genmask(15, res0_bits) & 0xFFFF


def mbw_min_register_matches_extend_config(actual, expected_sw, bwa_wd):
    """
    mpam_extend_config() stores a full u16 in cfg->mbw_min; the MSC register may
    return the same value, or clear RES0 (low 16-bwa_wd bits). Accept either.
    """
    if actual == expected_sw:
        return True
    sig = mbw_bwa_significant_mask(bwa_wd)
    return actual == (expected_sw & sig)


def expected_mbw_min_from_extend_config(bwa_wd, mbw_max_val, t241_quirk=False):
    """
    Expected MBW_MIN from mpam_extend_config() algo: when only mbw_max is set,
    derive mbw_min = max(mbw_max - delta, min_hw_granule); optionally apply
    T241 quirk (min = min_hw_granule + 1 if result <= min_hw_granule).

    Compare register reads with mbw_min_register_matches_extend_config(): the
    kernel keeps the full u16 in software, but hardware may read back with
    RES0 bits cleared (mask GENMASK(15, 16-bwa_wd)).
    """
    if not bwa_wd:
        return 0
    res0_bits = 16 - bwa_wd
    max_hw_value = ((1 << bwa_wd) - 1) << res0_bits
    min_hw_granule = (~max_hw_value) & 0xFFFF
    delta = (5 * MPAMCFG_MBW_MAX_MAX) // 100 - 1
    if mbw_max_val > delta:
        min_val = mbw_max_val - delta
    else:
        min_val = 0
    result = max(min_val, min_hw_granule)
    if t241_quirk and result <= min_hw_granule:
        result = min_hw_granule + 1
    return result


# Max register offset we need + 4 bytes
MPAM_REG_SIZE = 0x2000 + 4

# Full name and C constant (from mpam_internal.h) for display
REG_NAMES = (
    ("IDR", "Identification Register", "MPAMF_IDR", MPAMF_IDR),
    ("IDR_HI", "Identification Register High", "MPAMF_IDR_HI", MPAMF_IDR_HI),
    ("AIDR", "Architecture ID Register", "MPAMF_AIDR", MPAMF_AIDR),
    ("IIDR", "Implementation ID Register", "MPAMF_IIDR", MPAMF_IIDR),
    ("CPOR_IDR", "Cache Portion ID Register", "MPAMF_CPOR_IDR", MPAMF_CPOR_IDR),
    ("CCAP_IDR", "Cache Capacity ID Register", "MPAMF_CCAP_IDR", MPAMF_CCAP_IDR),
    ("MBW_IDR", "Memory Bandwidth ID Register", "MPAMF_MBW_IDR", MPAMF_MBW_IDR),
    ("PRI_IDR", "Priority ID Register", "MPAMF_PRI_IDR", MPAMF_PRI_IDR),
    ("MSMON_IDR", "Monitoring ID Register", "MPAMF_MSMON_IDR", MPAMF_MSMON_IDR),
    ("CSUMON_IDR", "Cache-Side Unit Monitoring ID Register", "MPAMF_CSUMON_IDR", MPAMF_CSUMON_IDR),
    ("MBWUMON_IDR", "Memory Bandwidth Unit Monitoring ID Register", "MPAMF_MBWUMON_IDR", MPAMF_MBWUMON_IDR),
    ("PART_SEL", "Partition Select", "MPAMCFG_PART_SEL", MPAMCFG_PART_SEL),
    ("CMAX", "Cache Capacity Maximum", "MPAMCFG_CMAX", MPAMCFG_CMAX),
    ("CMIN", "Cache Capacity Minimum", "MPAMCFG_CMIN", MPAMCFG_CMIN),
    ("CPBM", "Cache Portion Bit Mask", "MPAMCFG_CPBM", MPAMCFG_CPBM),
    ("MBW_MIN", "Memory Bandwidth Minimum", "MPAMCFG_MBW_MIN", MPAMCFG_MBW_MIN),
    ("MBW_MAX", "Memory Bandwidth Maximum", "MPAMCFG_MBW_MAX", MPAMCFG_MBW_MAX),
    ("PRI", "Priority", "MPAMCFG_PRI", MPAMCFG_PRI),
    ("MBW_PBM", "Memory Bandwidth Portion Bit Mask", "MPAMCFG_MBW_PBM", MPAMCFG_MBW_PBM),
    ("ESR", "Error Status Register", "MPAMF_ESR", MPAMF_ESR),
)
REG_BY_KEY = {r[0]: (r[1], r[2], r[3]) for r in REG_NAMES}

def reg_label(key):
    """Return 'Full Name (C_NAME) @ 0xOFFSET'."""
    full_name, c_name, off = REG_BY_KEY[key]
    return "{} ({}) @ 0x{:04x}".format(full_name, c_name, off)

def part_sel(ris, partid):
    return (ris << 24) | (partid & 0xFFFF)

# --- devmem2 backend (for when mmap fails on high / restricted addresses) ---
DEVMEM2_READ_RE = re.compile(r'0x[0-9a-fA-F]+')

def devmem2_read32(base, off):
    addr = base + off
    out = subprocess.check_output(
        ['devmem2', f'0x{addr:x}', 'w'],
        stderr=subprocess.STDOUT, text=True)
    m = DEVMEM2_READ_RE.findall(out)
    if not m:
        raise RuntimeError(f"devmem2 read at 0x{addr:x}: could not parse output")
    return int(m[-1], 16)

def devmem2_write32(base, off, val):
    addr = base + off
    subprocess.run(
        ['devmem2', f'0x{addr:x}', 'w', f'0x{val & 0xFFFFFFFF:x}'],
        check=True, capture_output=True)

def run_with_devmem2(base, args):
    """Use devmem2 for all register read/write. base is full physical base address."""
    def r32(off):
        return devmem2_read32(base, off)
    def w32(off, val):
        devmem2_write32(base, off, val)
    return run_decode(r32, w32, base, args)

def run_decode(r32, w32, base, args):
    """Decode and print MPAM registers using r32(offset) and w32(offset, value).
    Runs 5 validation tests when features are supported; returns number of test failures."""
    test_failures = []
    test_results = []  # (test_num, passed, message) for line-by-line output, always 1–5 in order
    # Global IDR (RIS 0 selected by default or we select it)
    w32(MPAMCFG_PART_SEL, part_sel(0, 0))
    idr_lo = r32(MPAMF_IDR)
    idr_hi = r32(MPAMF_IDR_HI) if (idr_lo & IDR_EXT) else 0
    idr = idr_lo | (idr_hi << 32)

    partid_max = idr_lo & 0xFFFF
    pmg_max = (idr_lo >> 16) & 0xFF
    ris_max = (idr_hi >> 24) & 0xF if (idr_hi & 1) else 0  # IDR_HAS_RIS = high word bit 0
    num_ris = args.num_ris if args.num_ris is not None else (ris_max + 1)

    aidr = r32(MPAMF_AIDR)
    arch_maj = (aidr >> 4) & 0xF
    arch_min = aidr & 0xF
    iidr = r32(MPAMF_IIDR)
    impl = iidr & 0xFFF
    rev = (iidr >> 12) & 0xF
    var = (iidr >> 16) & 0xF
    prod = (iidr >> 20) & 0xFFF

    print("=== MPAM MSC @ 0x{:x} ===\n".format(base))
    print("{} : raw=0x{:08x}  arch {}.{}".format(reg_label("AIDR"), aidr & 0xFFFFFFFF, arch_maj, arch_min))
    print("{} : raw=0x{:08x}  implementer 0x{:03x} product 0x{:03x} var {} rev {}".format(
          reg_label("IIDR"), iidr & 0xFFFFFFFF, impl, prod, var, rev))
    print("{} : raw=0x{:08x}{}  PARTID_MAX {} PMG_MAX {} RIS_MAX {}".format(
          reg_label("IDR"), idr_lo & 0xFFFFFFFF,
          " raw_hi=0x{:08x}".format(idr_hi & 0xFFFFFFFF) if idr_hi else "",
          partid_max, pmg_max, ris_max))
    print("Features: CCAP={} CPOR={} MBW={} PRI={} MSMON={} PARTID_NRW={} ESR={}".format(
          "Y" if (idr_lo & IDR_HAS_CCAP_PART) else "N",
          "Y" if (idr_lo & IDR_HAS_CPOR_PART) else "N",
          "Y" if (idr_lo & IDR_HAS_MBW_PART) else "N",
          "Y" if (idr_lo & IDR_HAS_PRI_PART) else "N",
          "Y" if (idr_lo & IDR_HAS_MSMON) else "N",
          "Y" if (idr_lo & IDR_HAS_PARTID_NRW) else "N",
          "Y" if (idr_lo & IDR_HAS_ESR) else "N"))
    print()

    for ris in range(num_ris):
        w32(MPAMCFG_PART_SEL, part_sel(ris, 0))

        cpor = r32(MPAMF_CPOR_IDR) if (idr_lo & IDR_HAS_CPOR_PART) else 0
        ccap = r32(MPAMF_CCAP_IDR) if (idr_lo & IDR_HAS_CCAP_PART) else 0
        mbw = r32(MPAMF_MBW_IDR) if (idr_lo & IDR_HAS_MBW_PART) else 0
        pri = r32(MPAMF_PRI_IDR) if (idr_lo & IDR_HAS_PRI_PART) else 0
        msmon = r32(MPAMF_MSMON_IDR) if (idr_lo & IDR_HAS_MSMON) else 0
        csumon = r32(MPAMF_CSUMON_IDR) if (msmon & MSMON_IDR_MSMON_CSU) else 0
        mbwumon = r32(MPAMF_MBWUMON_IDR) if (msmon & MSMON_IDR_MSMON_MBWU) else 0

        print("--- RIS {} ---".format(ris))
        if idr_lo & IDR_HAS_CPOR_PART:
            cpbm_wd = cpor & CPOR_IDR_CPBM_WD
            print("  {} : raw=0x{:08x}  cpbm_wd {} (bits)".format(reg_label("CPOR_IDR"), cpor & 0xFFFFFFFF, cpbm_wd))
        if idr_lo & IDR_HAS_CCAP_PART:
            cmax_wd = ccap & CCAP_IDR_CMAX_WD
            cassoc_wd = (ccap & CCAP_IDR_CASSOC_WD) >> 8
            print("  {} : raw=0x{:08x}  cmax_wd {} cassoc_wd {} HAS_CMIN={} NO_CMAX={} CMAX_SOFTLIM={}".format(
                  reg_label("CCAP_IDR"), ccap & 0xFFFFFFFF, cmax_wd, cassoc_wd,
                  "Y" if (ccap & CCAP_IDR_HAS_CMIN) else "N",
                  "Y" if (ccap & CCAP_IDR_NO_CMAX) else "N",
                  "Y" if (ccap & CCAP_IDR_HAS_CMAX_SOFTLIM) else "N"))
        if idr_lo & IDR_HAS_MBW_PART:
            bwa_wd = mbw & MBW_IDR_BWA_WD
            bwpbm_wd = (mbw & MBW_IDR_BWPBM_WD) >> 16
            print("  {} : raw=0x{:08x}  bwa_wd {} bwpbm_wd {} HAS_MIN={} HAS_MAX={} HAS_PBM={}".format(
                  reg_label("MBW_IDR"), mbw & 0xFFFFFFFF, bwa_wd, bwpbm_wd,
                  "Y" if (mbw & MBW_IDR_HAS_MIN) else "N",
                  "Y" if (mbw & MBW_IDR_HAS_MAX) else "N",
                  "Y" if (mbw & MBW_IDR_HAS_PBM) else "N"))
        if idr_lo & IDR_HAS_MSMON:
            print("  {} : raw=0x{:08x}  CSU={} MBWU={}".format(
                  reg_label("MSMON_IDR"), msmon & 0xFFFFFFFF,
                  "Y" if (msmon & MSMON_IDR_MSMON_CSU) else "N",
                  "Y" if (msmon & MSMON_IDR_MSMON_MBWU) else "N"))
            if msmon & MSMON_IDR_MSMON_CSU:
                print("  {} : raw=0x{:08x}  num_mon {}".format(reg_label("CSUMON_IDR"), csumon & 0xFFFFFFFF, csumon & CSUMON_IDR_NUM_MON))
            if msmon & MSMON_IDR_MSMON_MBWU:
                print("  {} : raw=0x{:08x}  num_mon {} HAS_LONG={}".format(
                      reg_label("MBWUMON_IDR"), mbwumon & 0xFFFFFFFF,
                      mbwumon & MBWUMON_IDR_NUM_MON,
                      "Y" if (mbwumon & MBWUMON_IDR_HAS_LONG) else "N"))

        for partid in range(min(args.max_partid, partid_max + 1)):
            w32(MPAMCFG_PART_SEL, part_sel(ris, partid))
            print("  PARTID {}:".format(partid))
            cmax_val = cmin_val = mbw_min_val = mbw_max_val = cpbm_val = None
            ccap_read_failed = mbw_read_failed = cpor_read_failed = False
            if idr_lo & IDR_HAS_CCAP_PART:
                try:
                    cmax = r32(MPAMCFG_CMAX)
                    cmax_val = cmax & CMAX_CMAX
                    softlim = " softlim" if (cmax & CMAX_SOFTLIM) else ""
                    print("    {} : raw=0x{:08x}  cmax=0x{:x}{}".format(reg_label("CMAX"), cmax & 0xFFFFFFFF, cmax_val, softlim))
                    cmin = r32(MPAMCFG_CMIN)
                    cmin_val = cmin & CMIN_CMIN
                    print("    {} : raw=0x{:08x}  cmin=0x{:x}".format(reg_label("CMIN"), cmin & 0xFFFFFFFF, cmin_val))
                except Exception as e:
                    print("    {} : ?  (read failed)".format(reg_label("CMAX")))
                    print("    {} : ?  (read failed)".format(reg_label("CMIN")))
                    test_failures.append("RIS{} PARTID{}: CMAX/CMIN read failed ({})".format(ris, partid, e))
                    ccap_read_failed = True
            if idr_lo & IDR_HAS_CPOR_PART:
                try:
                    cpbm = r32(MPAMCFG_CPBM)
                    cpbm_val = cpbm & 0xFFFFFFFF
                    cpbm_wd = cpor & CPOR_IDR_CPBM_WD
                    exp_cpbm = expected_cpbm_from_cpor_idr(cpor)
                    exp_note = ""
                    if cpbm_wd and exp_cpbm:
                        gm_hi = cpbm_expected_genmask_hi(cpor)
                        exp_note = "  (expected GENMASK({},0)=0x{:x}, cpbm_wd={})".format(
                            gm_hi, exp_cpbm, cpbm_wd)
                    print("    {} : raw=0x{:08x}  cpbm=0x{:x}{}".format(
                          reg_label("CPBM"), cpbm_val, cpbm_val, exp_note))
                except Exception as e:
                    print("    {} : ?  (read failed)".format(reg_label("CPBM")))
                    test_failures.append("RIS{} PARTID{}: CPBM read failed ({})".format(ris, partid, e))
                    cpor_read_failed = True
            if idr_lo & IDR_HAS_MBW_PART:
                try:
                    mbw_min = r32(MPAMCFG_MBW_MIN)
                    mbw_max = r32(MPAMCFG_MBW_MAX)
                    mbw_min_val = mbw_min & MBW_MIN_MIN
                    mbw_max_val = mbw_max & MBW_MAX_MAX
                    hardlim = " hardlim" if (mbw_max & MBW_MAX_HARDLIM) else ""
                    exp_mbw_max_note = ""
                    if mbw & MBW_IDR_HAS_MAX:
                        exp_m = expected_mbw_max_from_mbw_idr(mbw)
                        exp_mbw_max_note = "  (expected 0x{:x} = MPAMCFG_MBW_MAX_MAX, kernel mpam_init_reset_cfg)".format(
                            exp_m)
                    exp_mbw_min_note = ""
                    bwa_wd_line = mbw & MBW_IDR_BWA_WD
                    if (mbw & MBW_IDR_HAS_MIN) and bwa_wd_line:
                        exp_min_sw = expected_mbw_min_from_extend_config(
                            bwa_wd_line, mbw_max_val, getattr(args, 't241', False))
                        sig_m = mbw_bwa_significant_mask(bwa_wd_line)
                        exp_min_reg = exp_min_sw & sig_m
                        if exp_min_reg != exp_min_sw:
                            exp_mbw_min_note = (
                                "  (extend_config sw=0x{:x}, bwa_wd={}: register-visible & GENMASK(15,{})=0x{:x})".format(
                                    exp_min_sw, bwa_wd_line, 16 - bwa_wd_line, exp_min_reg))
                        else:
                            exp_mbw_min_note = "  (expected from mpam_extend_config 0x{:x}, bwa_wd={})".format(
                                exp_min_sw, bwa_wd_line)
                    print("    {} : raw=0x{:08x}  mbw_min=0x{:x}{}".format(
                          reg_label("MBW_MIN"), mbw_min & 0xFFFFFFFF, mbw_min_val, exp_mbw_min_note))
                    print("    {} : raw=0x{:08x}  mbw_max=0x{:x}{}{}".format(
                          reg_label("MBW_MAX"), mbw_max & 0xFFFFFFFF, mbw_max_val, hardlim, exp_mbw_max_note))
                except Exception as e:
                    print("    {} : ?  (read failed)".format(reg_label("MBW_MIN")))
                    print("    {} : ?  (read failed)".format(reg_label("MBW_MAX")))
                    test_failures.append("RIS{} PARTID{}: MBW read failed ({})".format(ris, partid, e))
                    mbw_read_failed = True
            if idr_lo & IDR_HAS_PRI_PART:
                try:
                    pri_cfg = r32(MPAMCFG_PRI)
                    print("    {} : raw=0x{:08x}  intpri=0x{:x} dspri=0x{:x}".format(
                          reg_label("PRI"), pri_cfg & 0xFFFFFFFF, pri_cfg & PRI_INTPRI, (pri_cfg & PRI_DSPRI) >> 16))
                except Exception:
                    print("    {} : ?  (read failed)".format(reg_label("PRI")))

            # Validation tests: run only once (RIS 0 PARTID 0), expected values from ID registers / mpam_extend_config
            if ris == 0 and partid == 0:
                exp_cmax = expected_cmax_from_ccap(ccap) if (idr_lo & IDR_HAS_CCAP_PART) else 0xffff
                exp_cmin = 0
                bwa_wd = (mbw & MBW_IDR_BWA_WD) if (idr_lo & IDR_HAS_MBW_PART) else 0
                mbw_max_for_min = (mbw_max_val if mbw_max_val is not None else MPAMCFG_MBW_MAX_MAX) & 0xFFFF
                exp_mbw_min = expected_mbw_min_from_extend_config(bwa_wd, mbw_max_for_min, getattr(args, 't241', False)) if bwa_wd else 0
                exp_mbw_max = expected_mbw_max_from_mbw_idr(mbw) if (idr_lo & IDR_HAS_MBW_PART) else 0xffff
                exp_cpbm = expected_cpbm_from_cpor_idr(cpor) if (idr_lo & IDR_HAS_CPOR_PART) else 0
                cpbm_wd_chk = cpor & CPOR_IDR_CPBM_WD
                # Test 1: CMAX (allowed bits = cmax_wd shifted mask, e.g. 0x7f00 for cmax_wd=7)
                if ccap_read_failed:
                    test_results.append((1, False, "CMAX read failed"))
                elif (idr_lo & IDR_HAS_CCAP_PART) and cmax_val is not None:
                    cmax_mask = cmax_allowed_mask(ccap)
                    cmax_allowed = cmax_val & cmax_mask
                    cmax_wd = ccap & CCAP_IDR_CMAX_WD
                    if cmax_allowed == cmax_mask:
                        test_results.append((1, True, "CMAX=0x{:x} allowed bits mask 0x{:x} (cmax_wd={} shifted) ok".format(cmax_val, cmax_mask, cmax_wd)))
                    else:
                        test_failures.append("RIS0 PARTID0: CMAX allowed bits (mask 0x{:x}) must be 0x{:x} (got 0x{:x})".format(cmax_mask, cmax_mask, cmax_allowed))
                        test_results.append((1, False, "CMAX=0x{:x} allowed 0x{:x} (mask 0x{:x} cmax_wd={} shifted)".format(cmax_val, cmax_allowed, cmax_mask, cmax_wd)))
                else:
                    test_results.append((1, True, "CMAX (not supported)"))
                # Test 2: CMIN
                if ccap_read_failed:
                    test_results.append((2, False, "CMIN read failed"))
                elif (idr_lo & IDR_HAS_CCAP_PART) and (ccap & CCAP_IDR_HAS_CMIN) and cmin_val is not None:
                    if cmin_val == exp_cmin:
                        test_results.append((2, True, "CMIN=0x{:x}".format(cmin_val)))
                    else:
                        test_failures.append("RIS0 PARTID0: CMIN must be 0 (got 0x{:x})".format(cmin_val))
                        test_results.append((2, False, "CMIN=0x{:x} (expected 0)".format(cmin_val)))
                elif idr_lo & IDR_HAS_CCAP_PART:
                    test_results.append((2, True, "CMIN (not supported)"))
                else:
                    test_results.append((2, True, "CMIN (not supported)"))
                # Test 3: MBW_MIN
                if mbw_read_failed and (mbw & MBW_IDR_HAS_MIN):
                    test_results.append((3, False, "MBW_MIN read failed"))
                elif (idr_lo & IDR_HAS_MBW_PART) and (mbw & MBW_IDR_HAS_MIN) and mbw_min_val is not None:
                    sig_m = mbw_bwa_significant_mask(bwa_wd)
                    exp_reg = exp_mbw_min & sig_m
                    if mbw_min_register_matches_extend_config(mbw_min_val, exp_mbw_min, bwa_wd):
                        if mbw_min_val == exp_mbw_min:
                            test_results.append((3, True, "MBW_MIN register=0x{:x} (mpam_extend_config sw=0x{:x}, bwa_wd={})".format(
                                mbw_min_val, exp_mbw_min, bwa_wd)))
                        else:
                            test_results.append((3, True, "MBW_MIN register=0x{:x} matches sw=0x{:x} with RES0 cleared (mask=0x{:x}, bwa_wd={})".format(
                                mbw_min_val, exp_mbw_min, sig_m, bwa_wd)))
                    else:
                        test_failures.append(
                            "RIS0 PARTID0: MBW_MIN register=0x{:x} vs mpam_extend_config sw=0x{:x} (or & GENMASK(15,{})=0x{:x}), bwa_wd={}".format(
                                mbw_min_val, exp_mbw_min, 16 - bwa_wd, exp_reg, bwa_wd))
                        test_results.append((3, False, "MBW_MIN=0x{:x} (sw expect 0x{:x}, register-visible 0x{:x})".format(
                            mbw_min_val, exp_mbw_min, exp_reg)))
                else:
                    test_results.append((3, True, "MBW_MIN (not supported)"))
                # Test 4: MBW_MAX (kernel default MPAMCFG_MBW_MAX_MAX)
                if mbw_read_failed and (mbw & MBW_IDR_HAS_MAX):
                    test_results.append((4, False, "MBW_MAX read failed"))
                elif (idr_lo & IDR_HAS_MBW_PART) and (mbw & MBW_IDR_HAS_MAX) and mbw_max_val is not None:
                    actual = mbw_max_val & 0xFFFF
                    if actual == exp_mbw_max:
                        test_results.append((4, True, "MBW_MAX expected 0x{:x} (=MPAMCFG_MBW_MAX_MAX), register=0x{:x} ok".format(
                            exp_mbw_max, actual)))
                    else:
                        test_failures.append(
                            "RIS0 PARTID0: MBW_MAX expected 0x{:x} (=MPAMCFG_MBW_MAX_MAX), register=0x{:x}".format(
                                exp_mbw_max, actual))
                        test_results.append((4, False, "MBW_MAX expected 0x{:x}, register=0x{:x} (mismatch)".format(
                            exp_mbw_max, actual)))
                else:
                    test_results.append((4, True, "MBW_MAX (not supported)"))
                # Test 5: CPBM (kernel default: all portion bits set per CPOR_IDR CPBM_WD)
                gm_hi = cpbm_expected_genmask_hi(cpor)
                if cpor_read_failed:
                    test_results.append((5, False, "CPBM read failed"))
                elif (idr_lo & IDR_HAS_CPOR_PART) and cpbm_wd_chk and cpbm_val is not None:
                    if cpbm_val == exp_cpbm:
                        test_results.append((5, True, "CPBM GENMASK({},0)=0x{:x}, CPBM=0x{:x} ok (cpbm_wd={})".format(
                            gm_hi, exp_cpbm, cpbm_val, cpbm_wd_chk)))
                    else:
                        test_failures.append(
                            "RIS0 PARTID0: CPBM must match GENMASK({},0)=0x{:x} (cpbm_wd={}) (got 0x{:x})".format(
                                gm_hi, exp_cpbm, cpbm_wd_chk, cpbm_val))
                        test_results.append((5, False, "CPBM GENMASK({},0)=0x{:x}, got CPBM=0x{:x}".format(
                            gm_hi, exp_cpbm, cpbm_val)))
                else:
                    test_results.append((5, True, "CPBM (not supported)"))
            else:
                # Record failures for other PARTIDs; MBW_MIN expected from mpam_extend_config(mbw_max)
                bwa_wd = (mbw & MBW_IDR_BWA_WD) if (idr_lo & IDR_HAS_MBW_PART) else 0
                mbw_max_for_min = (mbw_max_val if mbw_max_val is not None else MPAMCFG_MBW_MAX_MAX) & 0xFFFF
                exp_mbw_min = expected_mbw_min_from_extend_config(bwa_wd, mbw_max_for_min, getattr(args, 't241', False)) if bwa_wd else 0
                exp_mbw_max = expected_mbw_max_from_mbw_idr(mbw) if (idr_lo & IDR_HAS_MBW_PART) else 0xffff
                exp_cpbm = expected_cpbm_from_cpor_idr(cpor) if (idr_lo & IDR_HAS_CPOR_PART) else 0
                cpbm_wd_chk = cpor & CPOR_IDR_CPBM_WD
                cpbm_gm_hi = cpbm_expected_genmask_hi(cpor)
                cmax_mask = cmax_allowed_mask(ccap) if (idr_lo & IDR_HAS_CCAP_PART) else 0xffff
                if (idr_lo & IDR_HAS_CCAP_PART) and cmax_val is not None and (cmax_val & cmax_mask) != cmax_mask:
                    test_failures.append("RIS{} PARTID{}: CMAX allowed bits must be 0x{:x} (got 0x{:x})".format(ris, partid, cmax_mask, cmax_val & cmax_mask))
                if (idr_lo & IDR_HAS_CCAP_PART) and (ccap & CCAP_IDR_HAS_CMIN) and cmin_val is not None and cmin_val != 0:
                    test_failures.append("RIS{} PARTID{}: CMIN must be 0 (got 0x{:x})".format(ris, partid, cmin_val))
                if ((idr_lo & IDR_HAS_MBW_PART) and (mbw & MBW_IDR_HAS_MIN) and mbw_min_val is not None
                        and not mbw_min_register_matches_extend_config(mbw_min_val, exp_mbw_min, bwa_wd)):
                    sig_m = mbw_bwa_significant_mask(bwa_wd)
                    test_failures.append(
                        "RIS{} PARTID{}: MBW_MIN register=0x{:x} vs extend_config sw=0x{:x} (or & mask 0x{:x}=0x{:x})".format(
                            ris, partid, mbw_min_val, exp_mbw_min, sig_m, exp_mbw_min & sig_m))
                if (idr_lo & IDR_HAS_MBW_PART) and (mbw & MBW_IDR_HAS_MAX) and mbw_max_val is not None and (mbw_max_val & 0xFFFF) != exp_mbw_max:
                    test_failures.append(
                        "RIS{} PARTID{}: MBW_MAX expected 0x{:x} (=MPAMCFG_MBW_MAX_MAX), register=0x{:x}".format(
                            ris, partid, exp_mbw_max, mbw_max_val & 0xFFFF))
                if (idr_lo & IDR_HAS_CPOR_PART) and cpbm_wd_chk and cpbm_val is not None and cpbm_val != exp_cpbm:
                    test_failures.append(
                        "RIS{} PARTID{}: CPBM must match GENMASK({},0)=0x{:x} (cpbm_wd={}) (got 0x{:x})".format(
                            ris, partid, cpbm_gm_hi, exp_cpbm, cpbm_wd_chk, cpbm_val))
        print()

    esr = r32(MPAMF_ESR)
    err_note = " (errors)" if esr else ""
    print("{} : raw=0x{:08x}{}".format(reg_label("ESR"), esr & 0xFFFFFFFF, err_note))

    # Test results line by line (Test 1–5 in order)
    print("Test results:")
    for n, passed, msg in test_results:
        status = "Pass" if passed else "Fail"
        print("  Test {} {}: {}".format(n, status, msg))
    if test_failures:
        return len(test_failures)
    return 0

def main():
    ap = argparse.ArgumentParser(description="Decode MPAM MSC registers")
    ap.add_argument("base", type=lambda x: int(x, 0), help="MSC base address (hex)")
    ap.add_argument("num_ris", nargs="?", type=int, default=None, help="Number of RIS (default: from IDR)")
    ap.add_argument("max_partid", nargs="?", type=int, default=2, help="Max PARTID to dump (default: 2)")
    ap.add_argument("--devmem2", action="store_true", help="Use devmem2 instead of mmap (for high/restricted addresses)")
    ap.add_argument("--t241", action="store_true", help="Apply T241 quirk when expecting MBW_MIN (min_hw_granule+1 if <= min_hw_granule)")
    args = ap.parse_args()

    base = args.base

    if args.devmem2:
        devmem2_path = shutil.which("devmem2")
        if not devmem2_path:
            print("devmem2 not found in PATH. Install it or use mmap.", file=sys.stderr)
            return 1
        return run_with_devmem2(base, args)

    try:
        page_size = os.sysconf('SC_PAGESIZE')
    except (AttributeError, ValueError, OSError):
        page_size = 4096
    if not page_size or page_size <= 0:
        page_size = 4096
    base_page = base & ~(page_size - 1)
    offset_in_page = base - base_page
    map_len = (offset_in_page + MPAM_REG_SIZE + page_size - 1) // page_size * page_size

    try:
        with open("/dev/mem", "r+b") as f:
            mem = mmap.mmap(f.fileno(), map_len, mmap.MAP_SHARED,
                            mmap.PROT_READ | mmap.PROT_WRITE, offset=base_page)
    except PermissionError:
        print("Must run as root to access /dev/mem", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"Failed to mmap: {e}", file=sys.stderr)
        if getattr(e, 'errno', None) == 22:  # EINVAL
            print("Tip: Try with --devmem2 (uses devmem2 for each register access).", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"Failed to mmap: {e}", file=sys.stderr)
        return 1

    def r32(off):
        return struct.unpack_from("<I", mem, offset_in_page + off)[0]
    def w32(off, val):
        struct.pack_into("<I", mem, offset_in_page + off, val & 0xFFFFFFFF)

    try:
        return run_decode(r32, w32, base, args)
    finally:
        mem.close()

if __name__ == "__main__":
    sys.exit(main())

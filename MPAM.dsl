/*
 * Intel ACPI Component Architecture
 * AML/ASL+ Disassembler version 20230628 (64-bit version)
 * Copyright (c) 2000 - 2023 Intel Corporation
 * 
 * Disassembly of MPAM, Thu Apr 23 23:27:50 2026
 *
 * ACPI Data Table [MPAM]
 *
 * Format: [HexOffset DecimalOffset ByteLength]  FieldName : FieldValue (in hex)
 */

[000h 0000 004h]                   Signature : "MPAM"    [Memory System Resource Partitioning and Monitoring Table]
[004h 0004 004h]                Table Length : 000000E4
[008h 0008 001h]                    Revision : 01
[009h 0009 001h]                    Checksum : B1
[00Ah 0010 006h]                      Oem ID : "NVIDIA"
[010h 0016 008h]                Oem Table ID : "SMCI--MB"
[018h 0024 004h]                Oem Revision : 00000001
[01Ch 0028 004h]             Asl Compiler ID : "ARMH"
[020h 0032 004h]       Asl Compiler Revision : 00010000

[000h 0000 002h]                      Length : 0060
[002h 0002 001h]              Interface type : 00
[003h 0003 001h]                    Reserved : 00
[004h 0004 004h]                  Identifier : 000000B7
[008h 0008 008h]                Base address : 0000670010088000
[010h 0016 004h]                   MMIO size : 00004000
[014h 0020 004h]          Overflow interrupt : 00000146
[018h 0024 004h]    Overflow interrupt flags : 00000000
[01Ch 0028 004h]                   Reserved1 : 00000000
[020h 0032 004h] Overflow interrupt affinity : 00000000
[024h 0036 004h]             Error interrupt : 00000147
[028h 0040 004h]       Error interrupt flags : 00000000
[02Ch 0044 004h]                   Reserved2 : 00000000
[030h 0048 004h]    Error interrupt affinity : 00000000
[034h 0052 004h]               MAX_NRDY_USEC : 00000002
[038h 0056 008h] Hardware ID of linked device : ""
[040h 0064 004h] Instance ID of linked device : 00000000
[044h 0068 004h]    Number of resource nodes : 00000001
[000h 0000 004h]                  Identifier : 000000B6
[004h 0004 001h]                   RIS Index : 00
[005h 0005 002h]                   Reserved1 : 0000
[007h 0007 001h]                Locator type : 00 [Processor cache]
[000h 0000 008h]             Cache reference : 0000000000000001
[008h 0008 004h]                    Reserved : 00000000
[000h 0000 004h] Number of functional dependencies : 00000001
[000h 0000 004h] Number of functional dependencies : 00000000


[000h 0000 002h]                      Length : 0060
[002h 0002 001h]              Interface type : 00
[003h 0003 001h]                    Reserved : 00
[004h 0004 004h]                  Identifier : 00000172
[008h 0008 008h]                Base address : 00006F0010088000
[010h 0016 004h]                   MMIO size : 00004000
[014h 0020 004h]          Overflow interrupt : 00000286
[018h 0024 004h]    Overflow interrupt flags : 00000000
[01Ch 0028 004h]                   Reserved1 : 00000000
[020h 0032 004h] Overflow interrupt affinity : 00000001
[024h 0036 004h]             Error interrupt : 00000287
[028h 0040 004h]       Error interrupt flags : 00000000
[02Ch 0044 004h]                   Reserved2 : 00000000
[030h 0048 004h]    Error interrupt affinity : 00000001
[034h 0052 004h]               MAX_NRDY_USEC : 00000002
[038h 0056 008h] Hardware ID of linked device : " "
[040h 0064 004h] Instance ID of linked device : 00000001
[044h 0068 004h]    Number of resource nodes : 00000001
[000h 0000 004h]                  Identifier : 00000171
[004h 0004 001h]                   RIS Index : 00
[005h 0005 002h]                   Reserved1 : 0000
[007h 0007 001h]                Locator type : 00 [Processor cache]
[000h 0000 008h]             Cache reference : 0000000000000002
[008h 0008 004h]                    Reserved : 00000000
[000h 0000 004h] Number of functional dependencies : 00000002
[000h 0000 004h] Number of functional dependencies : 00000000



Raw Table Data: Length 228 (0xE4)

    0000: 4D 50 41 4D E4 00 00 00 01 B1 4E 56 49 44 49 41  // MPAM......NVIDIA
    0010: 53 4D 43 49 2D 2D 4D 42 01 00 00 00 41 52 4D 48  // SMCI--MB....ARMH
    0020: 00 00 01 00 60 00 00 00 B7 00 00 00 00 80 08 10  // ....`...........
    0030: 00 67 00 00 00 40 00 00 46 01 00 00 00 00 00 00  // .g...@..F.......
    0040: 00 00 00 00 00 00 00 00 47 01 00 00 00 00 00 00  // ........G.......
    0050: 00 00 00 00 00 00 00 00 02 00 00 00 00 00 00 00  // ................
    0060: 00 00 00 00 00 00 00 00 01 00 00 00 B6 00 00 00  // ................
    0070: 00 00 00 00 01 00 00 00 00 00 00 00 00 00 00 00  // ................
    0080: 00 00 00 00 60 00 00 00 72 01 00 00 00 80 08 10  // ....`...r.......
    0090: 00 6F 00 00 00 40 00 00 86 02 00 00 00 00 00 00  // .o...@..........
    00A0: 00 00 00 00 01 00 00 00 87 02 00 00 00 00 00 00  // ................
    00B0: 00 00 00 00 01 00 00 00 02 00 00 00 01 00 00 00  // ................
    00C0: 00 00 00 00 01 00 00 00 01 00 00 00 71 01 00 00  // ............q...
    00D0: 00 00 00 00 02 00 00 00 00 00 00 00 00 00 00 00  // ................
    00E0: 00 00 00 00                                      // ....

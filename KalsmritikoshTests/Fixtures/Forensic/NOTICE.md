# Forensic sample fixtures — source and licence

Unified path SRC-12 (owner 2026-11-22, round 2). Used by `UnifiedPathForensicTests` (test phase T3, 2026-11-22): the Swift readers give the values below on every sample.

All files here come from the plaso project (log2timeline), https://github.com/log2timeline/plaso,
directory `test_data/` on branch `main`, downloaded 2026-11-22. plaso is licensed under the
Apache License, Version 2.0; the full licence text is in `LICENSE-plaso-Apache-2.0.txt` beside
this file. Copyright the plaso authors. Files are unmodified except where noted.

| File | plaso path | Note |
|---|---|---|
| AM_DELTA_PATCH_1.443.990.0.EX-7037CF86.pf | test_data/winprefetch/ | MAM-compressed, version 31 |
| NOTEPAD.EXE-D8414F97.pf | test_data/winprefetch/ | MAM-compressed, version 30 (metrics at 0x128) |
| ONEDRIVE.EXE-7E152375.pf | test_data/winprefetch/ | MAM-compressed, version 30 (metrics at 0x130), two 64 KiB blocks |
| CMD.EXE-087B4001.pf | test_data/winprefetch/ | uncompressed, version 17 |
| PING.EXE-B29F6629.pf | test_data/winprefetch/ | uncompressed, version 23 |
| System.evtx | test_data/evtx/ | |
| System2.evtx | test_data/evtx/ | |
| 1b4dd67f29cb1962.automaticDestinations-ms | test_data/automaticDestinations-ms/ | DestList version 1 |
| 9d1f905ce5044aee.automaticDestinations-ms | test_data/automaticDestinations-ms/ | DestList version 3 |
| system.journal.gz | test_data/systemd/journal/system.journal | MODIFIED: cut at the end of the last object (5,742,272 of 8,388,608 bytes; the rest is unused arena) and gzip-compressed to stay under 5 MB |
| SYSTEM.ControlSet001.AppCompatCache.bin | test_data/SYSTEM | DERIVED: only the value `ControlSet001\Control\Session Manager\AppCompatCache\AppCompatCache` (56,256 bytes) extracted from the 16 MB hive |

## What each sample showed (2026-11-22, python prototypes of the Swift readers)

- Prefetch: all three MAM files decompress (LZXPRESS Huffman) to exactly the declared size with a
  valid SCCA header. AM_DELTA v31: 1 run 2026-02-04 13:43:44 UTC, count 1 (also confirmed by the
  Swift reader). NOTEPAD v30: 2 runs, count 2 at 0xC8. ONEDRIVE v30: 2 runs, count 2 at 0xD0.
  CMD v17: last run 2013-03-10 10:11:49 UTC, count 2. PING v23: 2012-04-06 19:00:55 UTC, count 14.
  Every path hash matches the hash in the file name.
- EVTX: BinXML resolved for 194/194 records of System2.evtx (Security: 4624 ×47, 4672 ×36,
  4735 ×34 …) and 5,009/5,009 of System.evtx (7036 ×3,434, 7040 ×1,018; record 1 = 7036 from
  "Service Control Manager", param1 "Windows Event Log", param2 "stopped").
- Jump lists: DestList v1 — 7 entries, streams 7,5,2,1,6,4,3, host student-pc1, newest
  2015-08-29 15:32:44 UTC "C:\Users\bperry\Downloads". DestList v3 — 2 entries, streams 2,1, access
  count 1 each, newest 2016-01-17 13:08:08 UTC (also confirmed by the Swift reader).
- systemd journal: 2,101 entries (= header n_entries), 2017-01-27 09:40:55 UTC to
  2017-02-06 16:24:42 UTC; two XZ-compressed DATA objects decode.
- Shimcache: Windows 7 32-bit layout (0xBADC0FEE), 330 entries, first
  `\??\C:\Program Files\McAfee\VirusScan Enterprise\mfeann.exe` modified 2011-01-12 12:08:00 UTC;
  238 entries carry insert flag 0x2.

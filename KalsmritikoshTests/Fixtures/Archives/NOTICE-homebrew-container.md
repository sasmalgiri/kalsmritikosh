# homebrew-container.rar — source and licence

Test phase T3 (2026-11-22), row IN-24. No tool on this Mac can write a RAR file, so a freely licensed sample was used.

- File: `homebrew-container.rar` (87 bytes, RAR 4, one stored member `container`, 17 bytes, SHA-256
  `306c6ca7407560340797866e077e053627ad409277d1b9da58106fce4cf717cb`).
- Source: Homebrew, `Library/Homebrew/test/support/fixtures/cask/container.rar`, copied unmodified from the local
  Homebrew installation (/opt/homebrew) on 2026-11-22.
- Licence: BSD 2-Clause, Copyright (c) 2009-present, Homebrew contributors. The full text is in
  `LICENSE-homebrew-BSD-2-Clause.txt` beside this file.
- Used by: `UnifiedPathForensicTests/rarThroughLibarchive()`.
- Limit: RAR 5, solid, multi-volume and passworded RAR are not covered by this sample.

# Bundled dictionary data

## Standard dictionaries

`standard/FIX40.xml` through `standard/FIXT11.xml` are unmodified QuickFIX/J
dictionaries. They were retrieved on 2026-09-16 from commit
`560200e6237bb6172acb18cbf3e5513fdf8cacb5`:

<https://github.com/quickfix-j/quickfixj/tree/560200e6237bb6172acb18cbf3e5513fdf8cacb5/quickfixj-messages>

QuickFIX/J distributes these files under the QuickFIX Software License,
Version 1.0. See `THIRD_PARTY_LICENSES.txt`.

`standard/FIXLatest-metadata.xml` contains field, enum, and message metadata
mechanically projected from the official `OrchestraFIXLatest.xml`. The source
was retrieved on 2026-09-16 from commit
`cd24169a2abd8daba7c360987c7a46ca11873a12`:

<https://github.com/FIXTradingCommunity/orchestrations/blob/cd24169a2abd8daba7c360987c7a46ca11873a12/FIX%20Standard/OrchestraFIXLatest.xml>

The source SHA-256 is
`1bf82a22423d6504fbb77c4c8c522a4efefb32aec19b630c138860ccddf8228d`.
The projection retains only documentation metadata:

- field ID and first non-empty `SYNOPSIS`;
- code-set field ID, value, and first non-empty `SYNOPSIS`;
- message type, category, and first non-empty `SYNOPSIS`.

QuickFIX/J remains authoritative for version membership, names, types, enum
values, enum display names, messages, components, and repeating groups.
Orchestra metadata cannot introduce or redefine a dictionary element.

The `FIXTradingCommunity/orchestrations` repository licenses the source under
Apache-2.0. See `THIRD_PARTY_LICENSES.txt`.

`standard/SHA256SUMS` records the SHA-256 of every bundled dictionary and the
derived metadata file. The QuickFIX/J dictionaries are unmodified, so their
manifest hashes are also the hashes of the pinned upstream files. Verify all
bundled files from this directory with:

```sh
cd xml/standard
sha256sum -c SHA256SUMS
```

## Test dictionaries

`custom/synthetic/` contains Apache-2.0 QuickFIX fixtures written for this
project. See `custom/README.md`.

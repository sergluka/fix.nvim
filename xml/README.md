# Bundled dictionary data

## FIX Repository

The `FIX.*/Base/` and `FIXT.1.1/Base/` directories contain per-version extracts
of the FIX Repository, 2010 Edition, under the terms described in
`THIRD_PARTY_LICENSES.txt`.

The five files under `FIX.4.3/Base/` were retrieved on 2026-09-16 from commit
`54c3b328d774d92e0b41ceb0237547980f7ae9de` of the public
`VirtuFinancial/FixClient` repository:

`https://github.com/VirtuFinancial/FixClient/tree/54c3b328d774d92e0b41ceb0237547980f7ae9de/Dictionary/Repository/FIX.4.3/Base`

Raw SHA-256 values:

- `Components.xml`: `fa4966dd8479701c1201483402173d3f118789129046d62b4603c48c3b856619`
- `Enums.xml`: `86605a4ff0c87296f2740223a9e39aa92bedb0300c4a230d677f2bcd08d6d533`
- `Fields.xml`: `530e425498d8c08ee8706776ce6b421530e5dffdd2d190edba2f6dad3d9243de`
- `Messages.xml`: `132b7ce9a4b10da592f6c240d55f4e8c5caf4baba1975cb70f2c4e527e62b1d6`
- `MsgContents.xml`: `eec8a58368ed5fa602f8286f5889e26a5eb167d42d1186642fe5c6715282a061`

These hashes identify the downloaded files. The repository copies normalize
line endings and indentation without changing the XML data.

The previous `FIX.4.3/Base/Fields.xml` was an incorrect copy of the FIX 4.2
file. Replacing the complete set keeps this version reproducible from one
pinned public source.

## Test dictionaries

`custom/synthetic/` contains Apache-2.0 QuickFIX fixtures written for this
project. See `custom/README.md`.

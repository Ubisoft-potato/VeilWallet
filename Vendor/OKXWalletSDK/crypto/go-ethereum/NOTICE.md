# Third-Party Notices — go-ethereum

This directory contains a vendored snapshot of selected packages from
[go-ethereum](https://github.com/ethereum/go-ethereum), used by the SDK for
Ethereum primitives (common types, crypto, RLP, EIP-712 typed-data hashing,
transaction types, etc.).

## License

Except where a subdirectory ships its own `LICENSE` file, all code in this
directory is licensed under the **GNU Lesser General Public License v3.0 or
later (LGPL-3.0-or-later)**, the same as upstream go-ethereum's library code.

The canonical license texts that upstream ships at the repository root are:

- `COPYING`         — GNU General Public License v3.0 (GPL-3.0)
- `COPYING.LESSER`  — GNU Lesser General Public License v3.0 (LGPL-3.0)

LGPL-3.0 incorporates GPL-3.0 by reference, so **both files are required** to
fully represent the licensing terms. They are not yet present at this
directory's root; please populate them from upstream (see "Populating the
license files" below).

### Subpackages under different licenses

These subdirectories carry their own `LICENSE` files and are NOT LGPL:

| Path                  | License                      |
|-----------------------|------------------------------|
| `crypto/bn256/`       | See `crypto/bn256/LICENSE`   |
| `crypto/ecies/`       | See `crypto/ecies/LICENSE`   |
| `crypto/secp256k1/`   | See `crypto/secp256k1/LICENSE` |

## Modifications

Some files carry local patches / hardening on top of upstream. Such files
mark the divergence in their package-level doc comment and list the
applicable modifications. Examples:

- `signer/core/apitypes/types.go` — EIP-712 hardening (reference-type regex,
  bare int/uint normalization, signed-range validation, recursive
  fixed-array length validation, etc.)

If you port further files from upstream, please preserve the upstream
copyright header and note the source path (and ideally the upstream commit
SHA) in the package doc comment.

## Populating the license files

Run these commands from the repository root to fetch the canonical license
texts from upstream go-ethereum into this directory:

```bash
# Requires network access to github.com; run manually.
curl -fsSL https://raw.githubusercontent.com/ethereum/go-ethereum/master/COPYING \
  -o crypto/go-ethereum/COPYING
curl -fsSL https://raw.githubusercontent.com/ethereum/go-ethereum/master/COPYING.LESSER \
  -o crypto/go-ethereum/COPYING.LESSER
```

After populating the files, please pin the upstream commit SHA in each
modified file's package doc comment (search for `Pinned at:` markers).

## Upstream

- Repository: https://github.com/ethereum/go-ethereum
- License:    https://github.com/ethereum/go-ethereum#license

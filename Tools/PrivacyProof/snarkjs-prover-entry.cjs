// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2018 0kims association; 2026 Veil Wallet contributors.
// Prover-only entry for the pinned upstream snarkjs fork. These are unmodified
// upstream primitives. Legacy JavaScript verification/setup APIs are excluded;
// the native wallet validates public inputs against the deployed verifier.
'use strict';
exports.Circuit = require('./src/circuit.js');
exports.bigInt = require('./src/bigint.js');
exports.ZqField = require('./src/zqfield.js');
exports.stringifyBigInts = require('./src/stringifybigint.js').stringifyBigInts;
exports.unstringifyBigInts = require('./src/stringifybigint.js').unstringifyBigInts;
const Bn128 = require('./src/bn128.js');
exports.bn128 = new Bn128();

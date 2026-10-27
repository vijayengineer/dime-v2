# Deployments

## Monad mainnet (chain 143) — founder-only commissioning

Deployed 2026-10-13 from block **113002354** with `scripts/deploy.sh` (stage `commissioning`).
Manifest: [`deployments/143.json`](../deployments/143.json). All transactions succeeded (status 1).
All contracts are verified on Sourcify (MonadVision).

| Contract | Address | Deploy tx |
|---|---|---|
| DimeProtocol | `0x2C3De859ccAa0bfcDeFAa21d348b17F2aA2b746E` | `0x8c0669fd6006073e521aeffcff6a6b8609959286647132964e28308202c1561d` |
| DimeToken (DIME) | `0xC64efbA1E151a0914509EC76CAe1b5A827Ce50C9` | `0xdf65545417ee9570a2741fb7352ad77ebb6afa6997e1d540780f51b07d0b8607` |
| OperatorPriceVerifier | `0xC9Af6f42c6962CF327Eb0F5893EdC09F7067263c` | `0x9198977784e777665bbd914c8765d8726ecb7cd75c737016320bcb4c4f262169` |
| DimeMath (library) | `0x44e7C17D6FbbF9cD6B7714c9AD89cc6D55F7a0c5` | `0xab5e68a2a7dd41f8c6f71661c5be195388b21c64a6f8a9a0f835502300e64519` |
| DimeRights (library) | `0x6Ab1b49f68565dD87d60BDe64B503F63eCEA86A2` | `0xf094784fa89c075fba69c82da1b5df4af1482fb796e1cab5baf158378c96756f` |

Collateral: Circle USDC `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` (6 decimals).

### Post-deploy state (checked on-chain after the deploy)

- `DEFAULT_ADMIN_ROLE` on protocol, verifier and token is held by the admin wallet
  `0x1607265A81A3E35Ab5058afBfA261534a72a062A`. The deployer holds none, and its key was destroyed.
- `RELAYER_ROLE` → `0xEc87…5962`, `GUARDIAN_ROLE` → `0xDe82…3b75`, `REPORTER_ROLE` (verifier) → `0xA4DA…c593`.
- `MINTER_ROLE` on DIME is held only by the protocol and is locked; DIME transfers are disabled.
- The allow-list is **on** and contains only the admin wallet.
- `isIndependentOracle()` is `false`: the reference is operator-signed, and labelled as such.

### Setup transactions

| Step | Tx |
|---|---|
| DimeToken.setProtocol | `0xed492b318506d6fa6d063a3ad3c894c20cd92f3bce651ffa9252ecf919428396` |
| Protocol grantRole (relayer) | `0x4f7c05ca5abded236edd55208c11a9861b5ba7385215947cd3040c727b561e25` |
| Protocol grantRole (guardian) | `0x3b05b9615e1edbdf4865755267864083cdeebfebaa476e422126e716fb870a60` |
| setAllowlistEnabled(true) | `0x7f131b09461ea8950747a217e6de150876f51208781675b5510c32a71acae5ea` |
| setAllowlisted([admin], true) | `0x08c9f24a8edd2dc32628145b88fd53d2cccdbbcc49e3130e9dd30101c41a7945` |
| Protocol grant admin → admin wallet | `0x6d7ae25dd1b85d561e540b272efb3698a9c5daaa93be4d80f7c5669b6b12c044` |
| Protocol deployer renounces admin | `0xd71e5da26f18547ce52d869fbe6b2048453b00e2ea237ebf8fc2b665b24a78bf` |
| Verifier grant admin → admin wallet | `0x78e29ec3e249eed7cc85b4dba3c24b86ecde145b2332a0d3ce3bd2c6c0c054eb` |
| Verifier deployer renounces admin | `0x768a158ce607587e33b2239e6e06213a93c186529bf12d51663ed0f355535da4` |
| Token grant admin → admin wallet | `0xc77794d80708f04e4a2844bcbb55bda30078521458265a52ab55dfd16ddd5cfe` |
| Token deployer renounces admin | `0x07a7953949e0000653bff538469ce22bec6a7720c3027fe826880d5789297356` |

### Backend

`https://api-dime.rndm.io` serves `/feed*` (pricing, :8710) and `/v1/*` and `/health` (API, :8720).
`dime-pricing`, `dime-api`, `dime-keeper` and `dime-watchdog` run as the `dime` user with
`deploy/env/backend.env.commissioning`.

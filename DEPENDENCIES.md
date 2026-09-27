# Vendored dependencies

All required dependency sources are included as ordinary files, with no submodules
or installation step. Runtime source imports resolve through `remappings.txt`.

| Dependency | Pinned release | Included files | License |
| --- | --- | --- | --- |
| OpenZeppelin Contracts | v5.0.2 | ERC20, IERC20, IERC20Metadata, IERC20Permit, SafeERC20, Address, Context, ReentrancyGuard, IERC6093 | MIT, `lib/openzeppelin-contracts/LICENSE` |
| forge-std | v1.9.7 | Upstream `src/` tree for testing | MIT OR Apache-2.0, licenses in `lib/forge-std/` |

Sources were copied without modification from these release archives:

- https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.0.2
- https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.7

Only the needed OpenZeppelin dependency closure is included; forge-std is test-only.
Foundry and the pinned Solidity compiler are execution-profile tools, not repository
dependencies. The ABI export utility uses only the Python 3 standard library.

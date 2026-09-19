# Third-party

## Runtime (not in git)

| Component | Source | License | Hitch’s use |
|---|---|---|---|
| `cursor-sdk-bridge` standalone | [cursor/sdk-bridge](https://github.com/cursor/sdk-bridge) GitHub Releases | MIT (adapter). The bundled Cursor agent runtime is Cursor’s package. | Spawned subprocess. Fetched by `scripts/fetch-bridge.sh` into `~/.hitch/bridge/`. Never committed. |
| `@cursor/sdk` | npm | `SEE LICENSE IN LICENSE.md` (Cursor) | Not a dependency of Hitch. Node gold uses it; we talk to the official bridge process instead. |

## Design / protocol gold (not vendored)

| Project | License | Hitch’s use |
|---|---|---|
| [cursor-sdk2api](https://github.com/Sunnyender-org/cursor-sdk2api) | MIT | Independent Node gateway we A/B against. Compact-summary extraction and fail-closed rules follow their documented behavior. |

## Standard library

Zig 0.16 standard library — used under the Zig license terms that ship with the compiler.

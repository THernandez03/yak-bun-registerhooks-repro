# yak-bun-registerhooks-repro

Minimal reproduction of a startup crash in `@yak/react` 10.1.0: when Vite runs on the Bun runtime (for example `bunx --bun vite build`), every Vite command that uses `viteYak()` fails, `vite build` and the dev server alike:

```text
Error: Could not start the .yak.ts evaluator on Node v26.12.1: Export named 'registerHooks' not found in module 'node:module'.
```

This repository exists to show the crash in isolation, to show that it follows the Bun runtime and not the package manager, and to back a report to [yak](https://github.com/galaxuslabs/yak) asking for a feature-detected fallback.

## Summary

The crash happens in an app with no `.yak.ts` file, with each of the four package managers tried, and not with `@yak/react@10.0.0`. Bun does not implement `module.registerHooks` yet ([oven-sh/bun#27369](https://github.com/oven-sh/bun/issues/27369)), and yak's evaluator worker imports it as a static named import, so the worker fails to load and `createEvaluator()` rejects.

Bun is not in yak's `engines` (`^22.18.0 || >=23.6.0`), and the missing API is Bun's to add. The change this repro argues for is narrower: yak could feature-detect `registerHooks`, so the plugin degrades on a runtime without it instead of failing every command.

## Contents

`src/main.tsx` renders one `styled` component, `vite.config.ts` has `viteYak()` as its only plugin, there is no `.yak.ts` file, `package.json` pins exact versions, and `bun.lock` is committed. `vite.config.ts` logs `runtime: bun ...` or `runtime: node ...` as its first statement, so every log names the runtime that actually ran it.

## Steps

```sh
bun install
bun run build:node   # node node_modules/vite/bin/vite.js build: passes
bun run build:bun    # bun --bun node_modules/vite/bin/vite.js build: fails with the error above
bun -e 'import { registerHooks } from "node:module"; console.log(typeof registerHooks)'
# Bun: SyntaxError: Export named 'registerHooks' not found in module 'node:module'.
bash scripts/matrix.sh   # every package manager under both runtimes, see below
```

`bun run dev:bun` and `bun run dev:node` start the dev server the same two ways, and `bun run probe` runs the `bun -e` line above. Under Node, `typeof registerHooks` is `function`. The probe uses the binding on purpose: `bun -e 'import { registerHooks } from "node:module"'` alone exits 0 on the tested Bun, because the unused import is dropped.

## `scripts/matrix.sh`

The script installs the app once per package manager (bun, npm, pnpm, Yarn 4), each in its own directory, runs `vite build` and a dev start under Bun and under Node in each, and prints the comparison tables.

Prerequisites: `bash`, `mktemp`, `timeout`, `sha256sum` (or `shasum -a 256`); a missing one stops the script with its name. `bun`, `node`, `npm`, `pnpm` and `yarn` (Yarn 4) are each optional: a missing one is printed as skipped. The script installs no package manager and sets no `HOME` or cache variable itself.

It copies `package.json`, `vite.config.ts`, `index.html` and `src/main.tsx` into one directory per package manager under `$MATRIX_DIR` (default a fresh `mktemp -d`; it must be empty), installs there, then runs `build` and a dev start (`timeout 30`, `--strictPort`, ports from `$PORT_BASE`, default 5200) under Bun and Node. A cell on a failed install is reported as "not evaluable". Files it writes, into a copy only:

- Bun: `bun.lock` is copied too.
- Yarn: `.yarnrc.yml` (`nodeLinker: node-modules`) and an empty `yarn.lock`.
- pnpm: `pnpm-workspace.yaml` (`strictDepBuilds: false`). Without it pnpm 12 exits 1 with `ERR_PNPM_IGNORED_BUILDS` for `@swc/core`'s install script; with it the script stays ignored, as Bun does by default. Set `PNPM_STORE_DIR` to pass `--store-dir` to every `pnpm install`.

## Results

All four installs resolved `@yak/react` 10.1.0 and `vite` 8.3.8 with the same `dist/isolated-source-eval/worker.js` (sha256 `5df4fa888d3cf69c553b96495fe8c7ad92fbae11ad8014d1fe7b1e822132b588`, identical to the file in the registry tarball), so the package manager and the `node_modules` layout play no part.

| Installed with | Bun 1.4.6-canary.1: `vite build` | Bun: dev start | Node v27.0.0-alpha.0.1.1: `vite build` | Node: dev start |
|---|---|---|---|---|
| bun 1.4.6-canary.1 | exit 1, error above | same error, no ready line | exit 0 | ready |
| npm 12.2.3 | exit 1, error above | same error, no ready line | exit 0 | ready |
| pnpm 12.21.0 | exit 1, error above | same error, no ready line | exit 0 | ready |
| Yarn 4.19.0 (`nodeLinker: node-modules`) | exit 1, error above | same error, no ready line | exit 0 | ready |

Other checks, each in a Bun-installed copy of the repro:

| Check | Runtime (from the config's log line) | `vite build` | dev start |
|---|---|---|---|
| `bunx --bun vite build` | bun 1.4.6 | exit 1, error above | not run |
| `bunx vite build` | node v27.0.0-alpha.0.1.1 | exit 0 | not run |
| `@yak/react@10.0.0` instead of 10.1.0 | bun 1.4.6 | exit 0 | ready |
| `@yak/react@10.1.0` with the optional-call patch under Workarounds | bun 1.4.6 | exit 0 | ready |

The last two also pass under Node. Deno 2.9.8 (`deno run -A node_modules/vite/bin/vite.js` in the npm-installed copy) builds and reaches dev ready too; its config log line reads `runtime: node v26.5.1` because Deno emulates `process.version`.

`node:module` without yak, `typeof registerHooks` / `typeof register`: Bun 1.4.6-canary.1 `undefined` / `function`, Node v27.0.0-alpha.0.1.1 `function` / `function`, Deno 2.9.8 `function` / `function`.

## Actual output

`bun --bun node_modules/vite/bin/vite.js build` in the Bun-installed copy made by `scripts/matrix.sh` (path shortened to `<matrix>`):

```text
runtime: bun 1.4.6
error during build:
Error: Could not start the .yak.ts evaluator on Node v26.12.1: Export named 'registerHooks' not found in module 'node:module'.
    at fail (<matrix>/bun/node_modules/@yak/react/dist/isolated-source-eval/index.js:17:31)
    at applyHandlers (node:events:64:20)
    at emitError (node:events:44:27)
    at #onError (node:worker_threads:731:14)
```

The dev server prints the same error after `error when starting dev server:`.

## Expected

`bun --bun vite build` builds, as it does under Node and as it did with 10.0.0. If the evaluator cannot run on the current runtime, the error names that runtime: here Bun 1.4.6, not "Node v26.12.1", which is the Node version Bun reports in `process.version`.

## Cause

- `packages/yak-internals/isolated-source-eval/worker.ts` imports `registerHooks` as a static named import from `node:module` ([line 19 at `2a80cbe`](https://github.com/galaxuslabs/yak/blob/2a80cbe23af15f4ec1e771ab0055a7048f2d880d/packages/yak-internals/isolated-source-eval/worker.ts#L19), since [galaxuslabs/yak#716](https://github.com/galaxuslabs/yak/pull/716)). On a runtime whose `node:module` has no such export, the worker module fails to link before any of its code runs.
- `viteYak()` awaits `createEvaluator()` when the plugin is created (`dist/loaders/vite-plugin.js:709` in 10.1.0), which boots the worker, so the failure stops every Vite command, including in apps without `.yak.ts` files. [galaxuslabs/yak#720](https://github.com/galaxuslabs/yak/pull/720) would have started the evaluator on the first `.yak.ts` evaluation, but it was closed unmerged.
- The rejection message is built from `process.version` (`dist/isolated-source-eval/index.js:17`). Bun reports `v26.12.1` there, which is inside the `engines` range, so neither the range nor the message points at Bun. [galaxuslabs/yak#719](https://github.com/galaxuslabs/yak/pull/719) handles the same failure on Node 23.0 to 23.5 through `engines`, which does not help here.

## Regression range

10.0.0 to 10.1.0. 10.0.0's worker imports `register`, not `registerHooks`, and in this repro it builds and reaches dev ready under Bun. Caveat: Bun documents `module.register` as a no-op (see Related), and 10.0.0's worker waits for replies from the loader that `register()` would start, so under Bun 10.0.0 probably could not evaluate `.yak.ts` files either. That part is read from the code, not tested (this repro has no `.yak.ts` file). So the regression in practice is the startup crash: an app without `.yak.ts` files started under Bun on 10.0.0 and fails on 10.1.0.

## Environment

Linux x64. Bun 1.4.6-canary.1+25c4fca9e (`process.versions.bun` reports `1.4.6`), Node v27.0.0-alpha.0.1.1 (an alpha), Deno 2.9.8, npm 12.2.3, pnpm 12.21.0, Yarn 4.19.0. `@yak/react` 10.1.0 (the latest published when tested), `vite` 8.3.8, `react` and `react-dom` 19.3.1. Every package-manager call ran with `HOME`, the XDG directories and each tool's cache and store directory pointed at a scratch directory. Not tested on stable Bun or Node releases: these results hold for the versions above only.

## Suggested fix

A suggestion, not tested against the TypeScript source:

1. Import the namespace and feature-detect the API:

   ```ts
   import * as nodeModule from "node:module";

   if (typeof nodeModule.registerHooks === "function") {
     nodeModule.registerHooks({
       resolve(specifier, context, nextResolve) {
         // unchanged
       },
     });
   }
   ```

   A namespace import still avoids the bare `module` identifier that the comment above the current import keeps away from Node's strip-types parser. The compiled equivalent (the patch under Workarounds) builds and reaches dev ready under Bun 1.4.6-canary.1 and Node v27.0.0-alpha.0.1.1; whether Node's strip-types parser accepts it in `worker.ts` is untested.
2. When the hooks are missing, report only the entry file from `dependenciesOf`, and warn once that changes to files a `.yak.ts` module imports will not trigger a reload on this runtime.
3. Name the actual runtime in the startup error, for example `` process.versions.bun ? `Bun ${process.versions.bun}` : `Node ${process.version}` ``.

Starting the evaluator lazily, as [galaxuslabs/yak#720](https://github.com/galaxuslabs/yak/pull/720) did, would also keep apps without `.yak.ts` files from booting the workers at all.

## Workarounds

- Run Vite on Node: in this repro, `bunx vite build` (without `--bun`) ran under Node v27.0.0-alpha.0.1.1 and built. It needs Node installed; observed in this repro only.
- Patch `dist/isolated-source-eval/worker.js`, for example through `patchedDependencies`:

  ```diff
  -import { registerHooks } from "node:module";
  +import * as nodeModule from "node:module";
  ...
  -registerHooks({ resolve(specifier, context, nextResolve) {
  +nodeModule.registerHooks?.({ resolve(specifier, context, nextResolve) {
  ```

  Under Bun the hook then never runs, so files a `.yak.ts` module imports are not watched in dev (read from the code, not tested).

## Related

- [oven-sh/bun#27369](https://github.com/oven-sh/bun/issues/27369) (open): Bun does not support `module.registerHooks`. Its implementation, [oven-sh/bun#35690](https://github.com/oven-sh/bun/pull/35690), is an open draft; [oven-sh/bun#34171](https://github.com/oven-sh/bun/issues/34171), the same `Export named 'registerHooks' not found` error from a static named import, was closed as its duplicate.
- [Bun's Node.js compatibility page](https://github.com/oven-sh/bun/blob/77c8fbd83d395aabd4e9ba646aaedbb9ab3547b4/docs/runtime/nodejs-compat.mdx#L124), on `node:module`: "Missing `Module#load()`, `registerHooks`, ..." and "`syncBuiltinESMExports`, `module._load`, `module._pathCache` and `module.register` are no-ops".
- [galaxuslabs/yak#714](https://github.com/galaxuslabs/yak/issues/714) and [galaxuslabs/yak#716](https://github.com/galaxuslabs/yak/pull/716) (Node 26's `module.register()` deprecation and the move to `module.registerHooks`), [galaxuslabs/yak#719](https://github.com/galaxuslabs/yak/pull/719) (the same failure on Node 23.0 to 23.5), [galaxuslabs/yak#720](https://github.com/galaxuslabs/yak/pull/720) (lazy evaluator start, closed).

Status of the linked threads as of 2026-11-22.

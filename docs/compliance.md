# Compliance

## reth (reference client)

Hook: `FastEvmRunner` (evm2 `InterpreterRunner`, frame mode) installed by `RethEvmFactory`
when built with `--features fastevm` and `FASTEVM_BACKEND=cpu|gpu`; counters via `FASTEVM_STATS`.

| Suite | Native reth | fastevm CPU | fastevm GPU |
|---|---|---|---|
| `cargo test --release -p ef-tests --features ef-tests,fastevm` (ethereum/tests v17 GeneralStateTests as blockchain tests, ValidBlocks, InvalidBlocks; EEST v4.5.0) | 60/60 groups, 46.4 s | 60/60, 47.3 s | 60/60, 436 s |
| `ef-test-runner` on tests@v21.0.1 `blockchain_tests/for_{cancun,prague,osaka,cancuntopragueattime15k}` (7,290 tests) | 7,285 pass, 2 fail, 3 skipped | identical | identical |

fastevm counters: ef-tests 102,225 frames executed, 74 resource fallbacks, 10,919 pre-Cancun
frames skipped; v21 209,629 executed, 67 fallbacks. The two v21 failures
(`test_system_contract_deployment[fork_CancunToPragueAtTime15k-…-deploy_after_fork-nonzero_balance]`
for EIP-7002 and EIP-7251) fail on native reth as well. Notes: reth's fixture parser rejects the
BPO transition networks, so those directories are excluded; the runner aborts after a suite with
failures, so `for_cancun` was run separately; it needs `RUST_MIN_STACK=16777216` (deep-call tests
overflow 2 MiB worker stacks on native evm2 too).

All runs use execution-spec-tests **tests@v21.0.1** (the release pinned by both
go-ethereum `build/checksums.txt` and Besu `ethereum/referencetests/build.gradle`),
fetched with `scripts/fetch-fixtures.sh` (sha256 verified).

## go-ethereum

Hook: every depth-0 message (no tracer, not a system call) of the state and
blockchain test runners goes to fastevm via `vm.DefaultEngine`
(`tests/fastevm_test.go`, `-tags fastevm`). Messages on forks the engine does
not support (pre-Cancun, Amsterdam+) run on geth's interpreter and are counted
as `skipped`. A message the engine cannot finish (lane arena exhausted) is
counted as a `fallback` and re-executed by geth — never partially applied.

| Run | Subtests | Failures | On fastevm | Fallbacks |
|---|---:|---:|---:|---:|
| `TestExecutionSpecState`, all fork dirs, 4 permutations, CPU backend | 421,173 | 0 | 152,836 | 264 (arena) |
| `TestExecutionSpecState/for_(cancun\|prague\|osaka)`, CPU backend | 83,149 | 0 | 38,209 | 66 (arena) |
| `TestExecutionSpecState/for_(cancun\|prague\|osaka)`, **GPU backend** | 83,149 | 0 | 38,209 | 66 (arena) |
| `TestExecutionSpecBlocktests/for_(cancun\|prague\|osaka\|*transition*)`, CPU backend | 50,067 | 0 | 582,575 | 706 (arena) |

Bugs found and fixed on the way (each caught by the suites):

* identity precompile output aliasing its input before return data was captured
  (`identity_return_overwrite`, `mem_copy_self`);
* EIP-7702 self-delegation: the delegate is warm because the call target was
  warmed first (`self_set_code_cost`);
* BLOCKHASH via the host must record the header in the stateless witness, as
  `opBlockhash` does (stateless self-validation in blockchain tests);
* the "account has no storage → slot is zero" shortcut must not skip asking the
  host when warm flags come from the host (EIP-2930 access-list tests).

## Engine-level checks

* `fastevm-tests`: uint256 vs bit-serial reference (20k random divisions, 5k
  mulmods), keccak/sha256/ripemd160/blake2f vectors, interpreter cases
  (calls, reverts, CREATE, storage refunds, precompiles, OOG), CPU vs GPU on a
  sum loop, and a 2,000-program differential fuzz (CPU vs GPU: status, error,
  gas, refund, output, account/slot diffs, logs).
* Corpus differential vs geth `evm run` (Osaka genesis): identical gas used and
  output for every benchmark program.

## Besu

Hook: `FastEvmExecutor.tryExecute` around the initial-frame loop of
`MainnetTransactionProcessor` (tracer must be `NO_TRACING`), enabled with
`BESU_FASTEVM=cpu|gpu FASTEVM_LIB=…/libfastevm.so` (inherited by the test JVMs)
or the `besu.fastevm*` system properties. Fixtures: the same `tests@v21.0.1`
tree (besu's `build/execution-spec-tests/fixtures` linked to it).

```sh
./gradlew :ethereum:referencetests:referenceTests --tests '*ExecutionSpecStateTest*' --rerun \
  -x extractStableFixtures -x executionSpecTests
```

| Run | Test classes | Tests | Failures | Errors | Skipped (besu ignore list) | On fastevm | Fallbacks |
|---|---:|---:|---:|---:|---:|---:|---:|
| Java EVM (baseline) | 2,309 | 83,367 | 0 | 0 | 1,788 | – | – |
| fastevm CPU | 2,309 | 83,367 | **0** | **0** | 1,788 | 38,209 | 66 (arena) |
| fastevm GPU | 2,309 | 83,367 | **0** | **0** | 1,788 | 38,209 | 66 (arena) |

Besu runs every fork's state tests; the engine takes the Cancun/Prague/Osaka
messages (38,209 — the same set and the same 66 arena fallbacks as in geth) and
the Java EVM runs the rest.

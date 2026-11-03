# Java binding (Besu)

`FastEvmNative` maps libfastevm's flat FFI API with JNA direct mapping;
`FastEvmExecutor` runs a Besu depth-0 `MessageFrame` on the engine and completes
the frame the way `AbstractMessageProcessor` would.

These sources are the canonical copy of what `integrations/besu.patch` adds to
`besu/evm/src/main/java/org/hyperledger/besu/evm/fastevm/` (Besu's `evm` module
already depends on JNA). The patch also adds the hook in
`MainnetTransactionProcessor`, public accessors `AbstractMessageProcessor.getEvm()`
and `MessageCallProcessor.getPrecompileContractRegistry()`, and passes
`besu.fastevm*` system properties to reference-test JVMs.

Enable: `-Dbesu.fastevm=cpu|gpu`, `-Dbesu.fastevm.lib=/path/libfastevm.so`,
optional `-Dbesu.fastevm.stats=/path/stats.txt` (executed/fallback counters at exit).

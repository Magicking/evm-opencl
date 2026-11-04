// Batch-throughput harness for Besu's EVM: runs N independent messages (distinct
// senders, same contract) on a fixed thread pool through the fluent EVMExecutor.
//
//   java -cp "<evmtool lib>/*:." BesuBatch <codeHex> <inputHex> <gas> <n> <threads> <repeat>
//
// Prints one JSON line: best/median wall time over `repeat` runs (after JIT warmup).
// State is reset for every message (commitWorldState(false)), like the geth and fastevm harnesses.
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;

import org.apache.tuweni.bytes.Bytes;
import org.hyperledger.besu.datatypes.Address;
import org.hyperledger.besu.datatypes.Wei;
import org.hyperledger.besu.evm.Code;
import org.hyperledger.besu.evm.EvmSpecVersion;
import org.hyperledger.besu.evm.fluent.EVMExecutor;
import org.hyperledger.besu.evm.fluent.EvmSpec;
import org.hyperledger.besu.evm.fluent.SimpleWorld;

public class BesuBatch {
  public static void main(String[] args) throws Exception {
    final Bytes codeBytes = Bytes.fromHexString(args[0]);
    final Bytes input = Bytes.fromHexString(args[1]);
    final long gas = Long.parseLong(args[2]);
    final int n = Integer.parseInt(args[3]);
    final int threads = Integer.parseInt(args[4]);
    final int repeat = Integer.parseInt(args[5]);
    final EvmSpec spec = EvmSpec.evmSpec(EvmSpecVersion.OSAKA);
    final Address contract = Address.fromHexString("0x000000000000000000000000000000000000c0de");
    final Code code = new Code(codeBytes);
    final ExecutorService pool = Executors.newFixedThreadPool(threads);

    // Reference output of one message (validates the harness against the other engines).
    final SimpleWorld refWorld = new SimpleWorld();
    refWorld.createAccount(contract, 1, Wei.ZERO).setCode(code.getBytes());
    final Bytes refOut =
        new EVMExecutor(spec)
            .worldUpdater(refWorld.updater())
            .commitWorldState(false)
            .code(code)
            .contract(contract)
            .receiver(contract)
            .sender(Address.fromHexString(String.format("0x%040x", 0x100000L)))
            .gas(gas)
            .callData(input)
            .execute();
    // Warm up the JIT: at least ~20k messages (or 2 s) before measuring.
    final int warm = Math.min(Math.max(n, 512), 4096);
    final long warmStart = System.nanoTime();
    for (int done = 0; done < 20000 && System.nanoTime() - warmStart < 2_000_000_000L; done += warm) {
      runBatch(pool, spec, code, contract, input, gas, warm, threads);
    }
    List<Double> times = new ArrayList<>();
    for (int r = 0; r < repeat; r++) {
      long t0 = System.nanoTime();
      runBatch(pool, spec, code, contract, input, gas, n, threads);
      times.add((System.nanoTime() - t0) / 1e9);
    }
    pool.shutdown();
    Collections.sort(times);
    double best = times.get(0), median = times.get(times.size() / 2);
    System.out.printf(
        "{\"engine\":\"besu\",\"batch\":%d,\"threads\":%d,\"best_s\":%.9f,\"median_s\":%.9f,\"msgs_per_s\":%.1f,\"output\":\"%s\"}%n",
        n, threads, best, median, n / median, refOut == null ? "" : refOut.toUnprefixedHexString());
  }

  static void runBatch(ExecutorService pool, EvmSpec spec, Code code, Address contract, Bytes input, long gas, int n,
      int threads) throws Exception {
    List<Future<?>> fs = new ArrayList<>();
    for (int t = 0; t < threads; t++) {
      final int tid = t;
      fs.add(pool.submit(() -> {
        SimpleWorld world = new SimpleWorld();
        world.createAccount(contract, 1, Wei.ZERO).setCode(code.getBytes());
        for (int i = tid; i < n; i += threads) {
          Address sender = Address.fromHexString(String.format("0x%040x", 0x100000L + i));
          new EVMExecutor(spec)
              .worldUpdater(world.updater())
              .commitWorldState(false)
              .code(code)
              .contract(contract)
              .receiver(contract)
              .sender(sender)
              .gas(gas)
              .callData(input)
              .execute();
        }
        return null;
      }));
    }
    for (Future<?> f : fs) f.get();
  }
}

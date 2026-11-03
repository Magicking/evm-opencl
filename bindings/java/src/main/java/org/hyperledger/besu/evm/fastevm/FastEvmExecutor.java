/*
 * Copyright contributors to Besu.
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
 * an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
package org.hyperledger.besu.evm.fastevm;

import org.hyperledger.besu.datatypes.Address;
import org.hyperledger.besu.datatypes.Hash;
import org.hyperledger.besu.datatypes.Log;
import org.hyperledger.besu.datatypes.LogTopic;
import org.hyperledger.besu.datatypes.VersionedHash;
import org.hyperledger.besu.datatypes.Wei;
import org.hyperledger.besu.evm.EVM;
import org.hyperledger.besu.evm.EvmSpecVersion;
import org.hyperledger.besu.evm.account.Account;
import org.hyperledger.besu.evm.account.MutableAccount;
import org.hyperledger.besu.evm.frame.BlockValues;
import org.hyperledger.besu.evm.frame.ExceptionalHaltReason;
import org.hyperledger.besu.evm.frame.MessageFrame;
import org.hyperledger.besu.evm.precompile.PrecompileContractRegistry;
import org.hyperledger.besu.evm.precompile.PrecompiledContract;
import org.hyperledger.besu.evm.worldstate.WorldUpdater;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicLong;

import com.sun.jna.Pointer;
import org.apache.tuweni.bytes.Bytes;
import org.apache.tuweni.bytes.Bytes32;
import org.apache.tuweni.units.bigints.UInt256;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Runs top-level (depth 0) message frames on the fastevm engine (CPU or CUDA backend).
 *
 * <p>Enabled with {@code -Dbesu.fastevm=cpu|gpu} or {@code BESU_FASTEVM=cpu|gpu}; the native
 * library is located with {@code -Dbesu.fastevm.lib=/path/libfastevm.so} / {@code FASTEVM_LIB} or
 * the JNA search path. State is read lazily from the frame's world updater; the resulting diff is
 * written back and the frame is completed exactly as the built-in processors would. Any message the
 * engine cannot run returns {@code false} and is executed by the Java EVM unchanged.
 */
public final class FastEvmExecutor {
  private static final Logger LOG = LoggerFactory.getLogger(FastEvmExecutor.class);

  private static final int FEVM_MSG_CALL = 0;
  private static final int FEVM_MSG_CREATE = 1;
  private static final int REQ_ACCOUNT = 0;
  private static final int REQ_STORAGE = 1;
  private static final int REQ_BLOCKHASH = 2;
  private static final int REQ_PRECOMPILE = 3;
  private static final int STATUS_SUCCESS = 0;
  private static final int STATUS_REVERT = 1;
  private static final int STATUS_HALT = 2;
  private static final int ACC_BALANCE = 1;
  private static final int ACC_NONCE = 2;
  private static final int ACC_CODE = 4;
  private static final int ACC_CREATED = 8;
  private static final int ACC_DESTRUCTED = 16;

  private static final FastEvmExecutor INSTANCE = create();

  /** Messages executed by the engine. */
  public final AtomicLong executed = new AtomicLong();

  /** Messages handed back to the Java EVM. */
  public final AtomicLong fallbacks = new AtomicLong();

  private final ThreadLocal<Pointer> engines;

  private FastEvmExecutor(final int backend) {
    this.engines =
        ThreadLocal.withInitial(() -> FastEvmNative.fevm_engine_create_flat(backend, 0, 1, 0, 0));
  }

  private static FastEvmExecutor create() {
    String mode = System.getProperty("besu.fastevm", System.getenv("BESU_FASTEVM"));
    if (mode == null || mode.isEmpty() || mode.equals("off")) {
      return null;
    }
    try {
      FastEvmNative.load(System.getProperty("besu.fastevm.lib", System.getenv("FASTEVM_LIB")));
      LOG.info(
          "fastevm engine enabled (backend={}, abi={})", mode, FastEvmNative.fevm_abi_version());
      final FastEvmExecutor ex = new FastEvmExecutor(mode.equals("gpu") ? 1 : 0);
      final String statsFile =
          System.getProperty("besu.fastevm.stats", System.getenv("FASTEVM_STATS"));
      Runtime.getRuntime().addShutdownHook(new Thread(() -> reportStats(ex, statsFile)));
      return ex;
    } catch (final Throwable t) {
      LOG.warn("fastevm requested but unavailable, using the Java EVM: {}", t.toString());
      return null;
    }
  }

  private static void reportStats(final FastEvmExecutor ex, final String statsFile) {
    final String line =
        "fastevm: executed=" + ex.executed.get() + " fallbacks=" + ex.fallbacks.get();
    LOG.info(line);
    if (statsFile == null) {
      return;
    }
    try {
      Files.writeString(
          Path.of(statsFile),
          line + System.lineSeparator(),
          StandardOpenOption.CREATE,
          StandardOpenOption.APPEND);
    } catch (final IOException e) {
      LOG.warn("cannot write fastevm stats", e);
    }
  }

  /**
   * Returns the process-wide executor, or {@code null} when fastevm is disabled.
   *
   * @return the executor or null
   */
  public static FastEvmExecutor get() {
    return INSTANCE;
  }

  private static int forkOf(final EvmSpecVersion v) {
    return switch (v) {
      case CANCUN -> 0;
      case PRAGUE -> 1;
      case OSAKA -> 2;
      default -> -1;
    };
  }

  private static byte[] word(final Bytes b) {
    return b == null ? new byte[32] : Bytes32.leftPad(b).toArrayUnsafe();
  }

  /**
   * Executes the frame's message on fastevm and completes the frame.
   *
   * @param frame a NOT_STARTED depth-0 frame
   * @param evm the EVM the frame would run on
   * @param precompiles active precompiles (for precompiles the engine delegates to the host)
   * @param senderNoncePreincremented whether the transaction processor already bumped the sender
   *     nonce (contract creation)
   * @return true when the frame was executed and completed, false to run it on the Java EVM
   */
  public boolean tryExecute(
      final MessageFrame frame,
      final EVM evm,
      final PrecompileContractRegistry precompiles,
      final boolean senderNoncePreincremented) {
    final int fork = forkOf(evm.getEvmVersion());
    if (fork < 0 || frame.getDepth() != 0 || frame.getState() != MessageFrame.State.NOT_STARTED) {
      return false;
    }
    final Pointer engine = engines.get();
    if (engine == null) {
      return false;
    }
    final BlockValues bv = frame.getBlockValues();
    final Pointer batch =
        FastEvmNative.fevm_batch_create_flat(
            engine,
            frame.getMiningBeneficiary().getBytes().toArrayUnsafe(),
            bv.getNumber(),
            bv.getTimestamp(),
            bv.getGasLimit(),
            word(bv.getMixHashOrPrevRandao()),
            word(bv.getBaseFee().map(Wei::toBytes).orElse(null)),
            word(frame.getBlobGasPrice().toBytes()),
            word(evm.getChainId().orElse(null)),
            fork);
    try {
      final boolean create = frame.getType() == MessageFrame.Type.CONTRACT_CREATION;
      final byte[] input =
          create
              ? frame.getCode().getBytes().toArrayUnsafe()
              : frame.getInputData().toArrayUnsafe();
      byte[] blobs = null;
      int nBlobs = 0;
      final Optional<List<VersionedHash>> vh = frame.getVersionedHashes();
      if (vh.isPresent() && !vh.get().isEmpty()) {
        nBlobs = vh.get().size();
        blobs = new byte[32 * nBlobs];
        for (int i = 0; i < nBlobs; i++) {
          System.arraycopy(vh.get().get(i).getBytes().toArrayUnsafe(), 0, blobs, 32 * i, 32);
        }
      }
      FastEvmNative.fevm_batch_add_flat(
          batch,
          create ? FEVM_MSG_CREATE : FEVM_MSG_CALL,
          frame.getSenderAddress().getBytes().toArrayUnsafe(),
          frame.getRecipientAddress().getBytes().toArrayUnsafe(),
          word(frame.getValue().toBytes()),
          frame.getRemainingGas(),
          input,
          input.length,
          frame.getOriginatorAddress().getBytes().toArrayUnsafe(),
          word(frame.getGasPrice().toBytes()),
          blobs,
          nBlobs,
          1,
          senderNoncePreincremented ? 1 : 0);
      final Host host = new Host(frame, precompiles);
      final int rc = FastEvmNative.fevm_batch_execute_flat(batch, Pointer.NULL, host);
      if (rc != 0 || host.failed) {
        fallbacks.incrementAndGet();
        return false;
      }
      final int[] status = new int[1];
      final int[] error = new int[1];
      final long[] gasLeft = new long[1];
      final long[] refund = new long[1];
      final byte[] created = new byte[20];
      final long[] counts = new long[4];
      FastEvmNative.fevm_result_summary(batch, 0, status, error, gasLeft, refund, created, counts);
      if (status[0] != STATUS_SUCCESS && status[0] != STATUS_REVERT && status[0] != STATUS_HALT) {
        fallbacks.incrementAndGet();
        return false;
      }
      final byte[] out = new byte[(int) counts[3]];
      FastEvmNative.fevm_result_output(batch, 0, out);
      complete(frame, batch, status[0], error[0], gasLeft[0], refund[0], counts, Bytes.wrap(out));
      executed.incrementAndGet();
      return true;
    } finally {
      FastEvmNative.fevm_batch_destroy(batch);
    }
  }

  private static void complete(
      final MessageFrame frame,
      final Pointer batch,
      final int status,
      final int error,
      final long gasLeft,
      final long refund,
      final long[] counts,
      final Bytes output) {
    final WorldUpdater updater = frame.getWorldUpdater();
    if (status == STATUS_SUCCESS) {
      applyDiff(frame, updater, batch, counts);
      if (refund > 0) {
        frame.incrementGasRefund(refund);
      }
      frame.setGasRemaining(gasLeft);
      frame.setOutputData(output);
      frame.setState(MessageFrame.State.COMPLETED_SUCCESS);
      // AbstractMessageProcessor.completedSuccess
      updater.commit();
      frame.getMessageFrameStack().removeFirst();
      frame.notifyCompletion();
      return;
    }
    // The engine already rolled back the frame's changes: mirror revert()/exceptionalHalt().
    updater.revert();
    updater.commit();
    frame.clearLogs();
    frame.clearGasRefund();
    frame.rollback();
    if (status == STATUS_REVERT) {
      frame.setGasRemaining(gasLeft);
      frame.setRevertReason(output);
      frame.setOutputData(output);
    } else {
      frame.setExceptionalHaltReason(Optional.of(haltReason(error)));
      frame.clearGasRemaining();
      frame.clearOutputData();
    }
    frame.setState(MessageFrame.State.COMPLETED_FAILED);
    frame.getMessageFrameStack().removeFirst();
    frame.notifyCompletion();
  }

  private static void applyDiff(
      final MessageFrame frame,
      final WorldUpdater updater,
      final Pointer batch,
      final long[] counts) {
    final byte[] addr = new byte[20];
    final int[] flags = new int[1];
    final long[] nonce = new long[1];
    final byte[] balance = new byte[32];
    for (int i = 0; i < counts[0]; i++) {
      final long codeLen =
          FastEvmNative.fevm_result_account(batch, 0, i, addr, flags, nonce, balance, null);
      byte[] code = null;
      if ((flags[0] & ACC_CODE) != 0 && codeLen > 0) {
        code = new byte[(int) codeLen];
        FastEvmNative.fevm_result_account(batch, 0, i, addr, flags, nonce, balance, code);
      }
      final Address a = Address.wrap(Bytes.wrap(addr.clone()));
      final MutableAccount acct = updater.getOrCreate(a);
      if ((flags[0] & ACC_CREATED) != 0) {
        frame.addCreate(a);
      }
      if ((flags[0] & ACC_BALANCE) != 0) {
        acct.setBalance(Wei.wrap(Bytes.wrap(balance.clone())));
      }
      if ((flags[0] & ACC_NONCE) != 0) {
        acct.setNonce(nonce[0]);
      }
      if ((flags[0] & ACC_CODE) != 0) {
        acct.setCode(code == null ? Bytes.EMPTY : Bytes.wrap(code));
      }
      if ((flags[0] & ACC_DESTRUCTED) != 0) {
        frame.addSelfDestruct(a);
      }
      // FEVM_ACC_TOUCHED needs nothing more: getOrCreate marks the account touched (EIP-158).
    }
    final byte[] key = new byte[32];
    final byte[] value = new byte[32];
    for (int i = 0; i < counts[1]; i++) {
      FastEvmNative.fevm_result_slot(batch, 0, i, addr, key, value);
      final MutableAccount acct = updater.getOrCreate(Address.wrap(Bytes.wrap(addr.clone())));
      acct.setStorageValue(
          UInt256.fromBytes(Bytes32.wrap(key.clone())),
          UInt256.fromBytes(Bytes32.wrap(value.clone())));
    }
    final int[] nTopics = new int[1];
    final byte[] topics = new byte[128];
    for (int i = 0; i < counts[2]; i++) {
      final long dataLen = FastEvmNative.fevm_result_log(batch, 0, i, addr, nTopics, topics, null);
      final byte[] data = new byte[(int) dataLen];
      FastEvmNative.fevm_result_log(batch, 0, i, addr, nTopics, topics, data);
      final List<LogTopic> ts = new ArrayList<>(nTopics[0]);
      for (int t = 0; t < nTopics[0]; t++) {
        ts.add(LogTopic.wrap(Bytes32.wrap(topics, 32 * t).copy()));
      }
      frame.addLog(new Log(Address.wrap(Bytes.wrap(addr.clone())), Bytes.wrap(data), ts));
    }
  }

  private static ExceptionalHaltReason haltReason(final int error) {
    return switch (error) {
      case 1 -> ExceptionalHaltReason.INSUFFICIENT_GAS;
      case 2 -> ExceptionalHaltReason.INVALID_OPERATION;
      case 3 -> ExceptionalHaltReason.INSUFFICIENT_STACK_ITEMS;
      case 4 -> ExceptionalHaltReason.TOO_MANY_STACK_ITEMS;
      case 5 -> ExceptionalHaltReason.INVALID_JUMP_DESTINATION;
      case 6 -> ExceptionalHaltReason.ILLEGAL_STATE_CHANGE;
      case 7 -> ExceptionalHaltReason.INVALID_RETURN_DATA_BUFFER_ACCESS;
      case 12 -> ExceptionalHaltReason.CODE_TOO_LARGE;
      case 14 -> ExceptionalHaltReason.INVALID_CODE;
      case 15 -> ExceptionalHaltReason.PRECOMPILE_ERROR;
      default -> ExceptionalHaltReason.INSUFFICIENT_GAS;
    };
  }

  /** Serves engine state requests from the frame's world updater. */
  private static final class Host implements FastEvmNative.FetchCallback {
    private final MessageFrame frame;
    private final PrecompileContractRegistry precompiles;
    private final byte[] addr = new byte[20];
    private final byte[] key = new byte[32];
    boolean failed;

    Host(final MessageFrame frame, final PrecompileContractRegistry precompiles) {
      this.frame = frame;
      this.precompiles = precompiles;
    }

    @Override
    public int invoke(final Pointer ctx, final Pointer sink, final Pointer reqs, final int n) {
      try {
        final WorldUpdater updater = frame.getWorldUpdater();
        for (int i = 0; i < n; i++) {
          final int kind = FastEvmNative.fevm_request_kind(reqs, i);
          FastEvmNative.fevm_request_address(reqs, i, addr);
          final Address a = Address.wrap(Bytes.wrap(addr.clone()));
          switch (kind) {
            case REQ_ACCOUNT -> {
              final Account acct = updater.get(a);
              final int warm = frame.isAddressWarm(a) ? 1 : 0;
              if (acct == null) {
                FastEvmNative.fevm_sink_account_flat(sink, i, 0, 0, warm, 0, null, null, null, 0);
              } else {
                final byte[] code = acct.getCode().toArrayUnsafe();
                FastEvmNative.fevm_sink_account_flat(
                    sink,
                    i,
                    1,
                    1,
                    warm,
                    acct.getNonce(),
                    word(acct.getBalance().toBytes()),
                    acct.getCodeHash().getBytes().toArrayUnsafe(),
                    code,
                    code.length);
              }
            }
            case REQ_STORAGE -> {
              FastEvmNative.fevm_request_key(reqs, i, key);
              final Bytes32 k = Bytes32.wrap(key.clone());
              final Account acct = updater.get(a);
              UInt256 cur = UInt256.ZERO;
              UInt256 orig = UInt256.ZERO;
              if (acct != null) {
                cur = acct.getStorageValue(UInt256.fromBytes(k));
                orig = acct.getOriginalStorageValue(UInt256.fromBytes(k));
              }
              final Boolean warm = frame.getWarmedUpStorage().get(a, k);
              FastEvmNative.fevm_sink_storage_flat(
                  sink,
                  i,
                  cur.toBytes().toArrayUnsafe(),
                  orig.toBytes().toArrayUnsafe(),
                  warm != null && warm ? 1 : 0);
            }
            case REQ_BLOCKHASH -> {
              final long number = FastEvmNative.fevm_request_number(reqs, i);
              final Hash h = frame.getBlockHashLookup().apply(frame, number);
              FastEvmNative.fevm_sink_blockhash_flat(
                  sink, i, h == null ? new byte[32] : h.getBytes().toArrayUnsafe());
            }
            case REQ_PRECOMPILE -> {
              final long gas = FastEvmNative.fevm_request_gas(reqs, i);
              final byte[] in = new byte[(int) FastEvmNative.fevm_request_input_len(reqs, i)];
              FastEvmNative.fevm_request_input(reqs, i, in);
              final PrecompiledContract pc = precompiles.get(a);
              int status = 1;
              long left = 0;
              byte[] out = new byte[0];
              if (pc != null) {
                final Bytes input = Bytes.wrap(in);
                final long req = pc.gasRequirement(input);
                if (req <= gas) {
                  final PrecompiledContract.PrecompileContractResult r =
                      pc.computePrecompile(input, frame);
                  if (r.state() == MessageFrame.State.COMPLETED_SUCCESS) {
                    status = 0;
                    left = r.isRefundGas() ? gas : gas - req;
                    out = r.output() == null ? new byte[0] : r.output().toArrayUnsafe();
                  }
                }
              }
              FastEvmNative.fevm_sink_precompile(sink, i, status, left, out, out.length);
            }
            default -> {
              failed = true;
              return 1;
            }
          }
        }
        return 0;
      } catch (final RuntimeException e) {
        LOG.debug("fastevm host callback failed", e);
        failed = true;
        return 1;
      }
    }
  }
}

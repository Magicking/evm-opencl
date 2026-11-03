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

import com.sun.jna.Callback;
import com.sun.jna.Native;
import com.sun.jna.NativeLibrary;
import com.sun.jna.Pointer;

/** JNA direct mapping of libfastevm's flat FFI API (see fastevm.h). */
@SuppressWarnings({"checkstyle:MethodName", "checkstyle:ParameterName"})
final class FastEvmNative {
  private FastEvmNative() {}

  /** Host state callback: answer every request through the fevm_sink_* functions. */
  interface FetchCallback extends Callback {
    int invoke(final Pointer ctx, final Pointer sink, final Pointer reqs, final int n);
  }

  static boolean load(final String path) {
    final NativeLibrary lib =
        path == null ? NativeLibrary.getInstance("fastevm") : NativeLibrary.getInstance(path);
    Native.register(FastEvmNative.class, lib);
    return true;
  }

  static native int fevm_abi_version();

  static native Pointer fevm_engine_create_flat(
      final int backend,
      final int device,
      final int cpuThreads,
      final long laneArenaBytes,
      final int maxRounds);

  static native void fevm_engine_destroy(final Pointer engine);

  static native Pointer fevm_batch_create_flat(
      final Pointer engine,
      final byte[] coinbase,
      final long number,
      final long timestamp,
      final long gasLimit,
      final byte[] prevRandao,
      final byte[] baseFee,
      final byte[] blobBaseFee,
      final byte[] chainId,
      final int fork);

  static native long fevm_batch_add_flat(
      final Pointer batch,
      final int kind,
      final byte[] sender,
      final byte[] recipient,
      final byte[] value,
      final long gas,
      final byte[] input,
      final long inputLen,
      final byte[] origin,
      final byte[] gasPrice,
      final byte[] blobHashes,
      final int nBlobHashes,
      final int useHostWarmFlags,
      final int senderNoncePreincremented);

  static native int fevm_batch_execute_flat(
      final Pointer batch, final Pointer ctx, final FetchCallback fetch);

  static native void fevm_batch_destroy(final Pointer batch);

  static native int fevm_request_kind(final Pointer reqs, final int i);

  static native void fevm_request_address(final Pointer reqs, final int i, final byte[] out20);

  static native void fevm_request_key(final Pointer reqs, final int i, final byte[] out32);

  static native long fevm_request_number(final Pointer reqs, final int i);

  static native long fevm_request_gas(final Pointer reqs, final int i);

  static native long fevm_request_input_len(final Pointer reqs, final int i);

  static native void fevm_request_input(final Pointer reqs, final int i, final byte[] out);

  static native void fevm_sink_account_flat(
      final Pointer sink,
      final int idx,
      final int exists,
      final int hasStorage,
      final int warm,
      final long nonce,
      final byte[] balance,
      final byte[] codeHash,
      final byte[] code,
      final long codeLen);

  static native void fevm_sink_storage_flat(
      final Pointer sink,
      final int idx,
      final byte[] current,
      final byte[] original,
      final int warm);

  static native void fevm_sink_blockhash_flat(final Pointer sink, final int idx, final byte[] hash);

  static native void fevm_sink_precompile(
      final Pointer sink,
      final int idx,
      final int status,
      final long gasLeft,
      final byte[] out,
      final long outLen);

  static native void fevm_result_summary(
      final Pointer batch,
      final int lane,
      final int[] status,
      final int[] error,
      final long[] gasLeft,
      final long[] refund,
      final byte[] created20,
      final long[] counts4);

  static native void fevm_result_output(final Pointer batch, final int lane, final byte[] out);

  static native long fevm_result_account(
      final Pointer batch,
      final int lane,
      final int i,
      final byte[] addr20,
      final int[] flags,
      final long[] nonce,
      final byte[] balance32,
      final byte[] codeOut);

  static native void fevm_result_slot(
      final Pointer batch,
      final int lane,
      final int i,
      final byte[] addr20,
      final byte[] key32,
      final byte[] value32);

  static native long fevm_result_log(
      final Pointer batch,
      final int lane,
      final int i,
      final byte[] addr20,
      final int[] nTopics,
      final byte[] topics128,
      final byte[] dataOut);
}

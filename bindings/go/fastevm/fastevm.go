// Package fastevm is a cgo binding for libfastevm, the batch EVM execution
// engine (CPU reference backend and CUDA backend).
//
// The package has no dependency on any Ethereum client: callers provide state
// through the Host interface and receive state diffs in Result.
//
// Linking: by default the package links ../../../build/libfastevm.so (with an
// rpath). Override with CGO_LDFLAGS / CGO_CFLAGS when installed elsewhere.
package fastevm

/*
#cgo CFLAGS: -I${SRCDIR}/../../../include
#cgo LDFLAGS: -L${SRCDIR}/../../../build -lfastevm -Wl,-rpath,${SRCDIR}/../../../build
#include <stdlib.h>
#include <string.h>
#include "fastevm.h"

extern int fastevmGoFetch(void* ctx, fevm_sink* sink, fevm_request* reqs, uint32_t n);

static fevm_host fastevm_make_host(uintptr_t h) {
	fevm_host x;
	x.ctx = (void*)h;
	x.fetch = (int (*)(void*, fevm_sink*, const fevm_request*, uint32_t))fastevmGoFetch;
	return x;
}
*/
import "C"

import (
	"errors"
	"runtime"
	"runtime/cgo"
	"sync"
	"unsafe"
)

type Address [20]byte
type Word [32]byte // big-endian 256-bit value

type Fork uint32

const (
	Cancun Fork = C.FEVM_FORK_CANCUN
	Prague Fork = C.FEVM_FORK_PRAGUE
	Osaka  Fork = C.FEVM_FORK_OSAKA
)

type Backend uint32

const (
	BackendCPU Backend = C.FEVM_BACKEND_CPU
	BackendGPU Backend = C.FEVM_BACKEND_GPU
)

type Status uint32

const (
	StatusSuccess  Status = C.FEVM_STATUS_SUCCESS
	StatusRevert   Status = C.FEVM_STATUS_REVERT
	StatusHalt     Status = C.FEVM_STATUS_HALT
	StatusFailure  Status = C.FEVM_STATUS_FAILURE
	StatusFallback Status = C.FEVM_STATUS_FALLBACK
)

// Error codes (fevm_error).
const (
	ErrNone              = C.FEVM_ERR_NONE
	ErrOutOfGas          = C.FEVM_ERR_OUT_OF_GAS
	ErrInvalidOpcode     = C.FEVM_ERR_INVALID_OPCODE
	ErrStackUnderflow    = C.FEVM_ERR_STACK_UNDERFLOW
	ErrStackOverflow     = C.FEVM_ERR_STACK_OVERFLOW
	ErrBadJump           = C.FEVM_ERR_BAD_JUMP
	ErrStaticViolation   = C.FEVM_ERR_STATIC_VIOLATION
	ErrReturnDataOOB     = C.FEVM_ERR_RETURNDATA_OOB
	ErrInsufficientFunds = C.FEVM_ERR_INSUFFICIENT_BALANCE
	ErrDepth             = C.FEVM_ERR_DEPTH
	ErrNonceOverflow     = C.FEVM_ERR_NONCE_OVERFLOW
	ErrCollision         = C.FEVM_ERR_CONTRACT_COLLISION
	ErrCodeSize          = C.FEVM_ERR_CODE_SIZE
	ErrInitCodeSize      = C.FEVM_ERR_INITCODE_SIZE
	ErrInvalidCodePrefix = C.FEVM_ERR_INVALID_CODE_PREFIX
	ErrPrecompile        = C.FEVM_ERR_PRECOMPILE
	ErrGasUintOverflow   = C.FEVM_ERR_GAS_UINT_OVERFLOW
	ErrResources         = C.FEVM_ERR_RESOURCES
	ErrHost              = C.FEVM_ERR_HOST
)

// Account diff flags.
const (
	AccBalance    = C.FEVM_ACC_BALANCE
	AccNonce      = C.FEVM_ACC_NONCE
	AccCode       = C.FEVM_ACC_CODE
	AccCreated    = C.FEVM_ACC_CREATED
	AccDestructed = C.FEVM_ACC_DESTRUCTED
	AccTouched    = C.FEVM_ACC_TOUCHED
)

type Config struct {
	Backend        Backend
	Device         int
	CPUThreads     uint32
	LaneArenaBytes uint64
	MaxRounds      uint32
}

type BlockContext struct {
	Coinbase    Address
	Number      uint64
	Timestamp   uint64
	GasLimit    uint64
	PrevRandao  Word
	BaseFee     Word
	BlobBaseFee Word
	ChainID     Word
	Fork        Fork
}

type AccessTuple struct {
	Address Address
	Keys    []Word
}

type Message struct {
	Create      bool
	Sender      Address
	Recipient   Address
	Value       Word
	Gas         uint64
	Input       []byte
	Origin      Address
	GasPrice    Word
	BlobHashes  []Word
	AccessList  []AccessTuple
	UseHostWarm bool
}

type AccountInfo struct {
	Exists     bool
	HasStorage bool
	Warm       bool
	Nonce      uint64
	Balance    Word
	CodeHash   Word
	Code       []byte
}

type PrecompileResult struct {
	OK      bool
	GasLeft uint64
	Output  []byte
}

// Host supplies state on demand. Methods are called from the goroutine running
// Batch.Execute; lane is the index of the requesting message.
type Host interface {
	Account(lane uint32, addr Address) AccountInfo
	Storage(lane uint32, addr Address, key Word) (current, original Word, warm bool)
	BlockHash(lane uint32, number uint64) Word
	Precompile(lane uint32, addr Address, input []byte, gas uint64) PrecompileResult
}

type AccountDiff struct {
	Address  Address
	Flags    uint32
	Nonce    uint64
	Balance  Word
	CodeHash Word
	Code     []byte
}

type SlotDiff struct {
	Address Address
	Key     Word
	Value   Word
}

type Log struct {
	Address Address
	Topics  []Word
	Data    []byte
}

type Result struct {
	Status   Status
	Error    uint32
	GasLeft  uint64
	Refund   int64
	Output   []byte
	Created  Address
	Accounts []AccountDiff
	Slots    []SlotDiff
	Logs     []Log
	Steps    uint64
}

type Stats struct {
	Rounds          uint32
	Requests        uint64
	ExecSeconds     float64
	HostSeconds     float64
	TransferSeconds float64
	TotalSeconds    float64
	CPURetriedLanes uint64 // lanes that exceeded GPU arena limits and re-ran on the CPU backend
}

// Engine wraps fevm_engine. It is safe to use from multiple goroutines as long
// as each goroutine uses its own Batch.
type Engine struct {
	e  *C.fevm_engine
	mu sync.Mutex // the CPU/GPU backends keep per-execution scratch state
}

func GPUAvailable() bool { return C.fevm_gpu_available() != 0 }

func NewEngine(cfg Config) (*Engine, error) {
	var c C.fevm_config
	c.backend = C.fevm_backend(cfg.Backend)
	c.device = C.int(cfg.Device)
	c.cpu_threads = C.uint32_t(cfg.CPUThreads)
	c.lane_arena_bytes = C.uint64_t(cfg.LaneArenaBytes)
	c.max_rounds = C.uint32_t(cfg.MaxRounds)
	var cerr *C.char
	e := C.fevm_engine_create(&c, &cerr)
	if e == nil {
		msg := "fastevm: engine creation failed"
		if cerr != nil {
			msg = "fastevm: " + C.GoString(cerr)
		}
		return nil, errors.New(msg)
	}
	eng := &Engine{e: e}
	runtime.SetFinalizer(eng, func(x *Engine) { x.Close() })
	return eng, nil
}

func (e *Engine) Close() {
	if e.e != nil {
		C.fevm_engine_destroy(e.e)
		e.e = nil
	}
}

type Batch struct {
	eng  *Engine
	b    *C.fevm_batch
	host Host
}

func (e *Engine) NewBatch(blk *BlockContext) *Batch {
	var c C.fevm_block_ctx
	copyAddr(&c.coinbase, blk.Coinbase)
	c.number = C.uint64_t(blk.Number)
	c.timestamp = C.uint64_t(blk.Timestamp)
	c.gas_limit = C.uint64_t(blk.GasLimit)
	copyWord(&c.prev_randao, blk.PrevRandao)
	copyWord(&c.base_fee, blk.BaseFee)
	copyWord(&c.blob_base_fee, blk.BlobBaseFee)
	copyWord(&c.chain_id, blk.ChainID)
	c.fork = C.fevm_fork(blk.Fork)
	b := &Batch{eng: e, b: C.fevm_batch_create(e.e, &c)}
	runtime.SetFinalizer(b, func(x *Batch) { x.Close() })
	return b
}

func (b *Batch) Close() {
	if b.b != nil {
		C.fevm_batch_destroy(b.b)
		b.b = nil
	}
}

func copyAddr(dst *C.fevm_address, a Address) {
	C.memcpy(unsafe.Pointer(&dst.bytes[0]), unsafe.Pointer(&a[0]), 20)
}
func copyWord(dst *C.fevm_bytes32, w Word) {
	C.memcpy(unsafe.Pointer(&dst.bytes[0]), unsafe.Pointer(&w[0]), 32)
}

// Add appends a message and returns its lane index.
func (b *Batch) Add(m *Message) int {
	// All memory handed to C is C-allocated: fevm_batch_add copies it.
	var c C.fevm_message
	if m.Create {
		c.kind = C.FEVM_MSG_CREATE
	} else {
		c.kind = C.FEVM_MSG_CALL
	}
	copyAddr(&c.sender, m.Sender)
	copyAddr(&c.recipient, m.Recipient)
	copyAddr(&c.origin, m.Origin)
	copyWord(&c.value, m.Value)
	copyWord(&c.gas_price, m.GasPrice)
	c.gas = C.uint64_t(m.Gas)
	var frees []unsafe.Pointer
	defer func() {
		for _, p := range frees {
			C.free(p)
		}
	}()
	if len(m.BlobHashes) > 0 {
		p := C.malloc(C.size_t(32 * len(m.BlobHashes)))
		frees = append(frees, p)
		hs := unsafe.Slice((*Word)(p), len(m.BlobHashes))
		copy(hs, m.BlobHashes)
		c.blob_hashes = (*C.fevm_bytes32)(p)
		c.n_blob_hashes = C.uint32_t(len(m.BlobHashes))
	}
	if len(m.AccessList) > 0 {
		p := C.malloc(C.size_t(unsafe.Sizeof(C.fevm_access_entry{})) * C.size_t(len(m.AccessList)))
		frees = append(frees, p)
		es := unsafe.Slice((*C.fevm_access_entry)(p), len(m.AccessList))
		for i, t := range m.AccessList {
			copyAddr(&es[i].address, t.Address)
			es[i].n_keys = C.uint32_t(len(t.Keys))
			es[i].keys = nil
			if len(t.Keys) > 0 {
				kp := C.malloc(C.size_t(32 * len(t.Keys)))
				frees = append(frees, kp)
				ks := unsafe.Slice((*Word)(kp), len(t.Keys))
				copy(ks, t.Keys)
				es[i].keys = (*C.fevm_bytes32)(kp)
			}
		}
		c.access_list = (*C.fevm_access_entry)(p)
		c.n_access_list = C.uint32_t(len(m.AccessList))
	}
	if m.UseHostWarm {
		c.use_host_warm_flags = 1
	}
	// The input is passed as a direct argument (Go memory without pointers) and
	// copied by the engine; the struct itself only holds C pointers.
	var in *C.uint8_t
	if len(m.Input) > 0 {
		in = (*C.uint8_t)(unsafe.Pointer(&m.Input[0]))
	}
	return int(C.fevm_batch_add_input(b.b, &c, in, C.uint64_t(len(m.Input))))
}

// Summary returns a lane's status and remaining gas without copying its diff.
func (b *Batch) Summary(i int) (Status, uint64) {
	return Status(C.fevm_batch_result_status(b.b, C.uint32_t(i))), uint64(C.fevm_batch_result_gas_left(b.b, C.uint32_t(i)))
}

// PreloadAccount seeds the batch state cache.
func (b *Batch) PreloadAccount(addr Address, info *AccountInfo) {
	var ca C.fevm_address
	copyAddr(&ca, addr)
	ci := toCInfo(info)
	var code *C.uint8_t
	if len(info.Code) > 0 {
		code = (*C.uint8_t)(unsafe.Pointer(&info.Code[0]))
	}
	C.fevm_batch_preload_account(b.b, &ca, &ci, code, C.uint64_t(len(info.Code)))
}

func (b *Batch) PreloadStorage(addr Address, key, value Word) {
	var ca C.fevm_address
	var ck, cv C.fevm_bytes32
	copyAddr(&ca, addr)
	copyWord(&ck, key)
	copyWord(&cv, value)
	C.fevm_batch_preload_storage(b.b, &ca, &ck, &cv)
}

func toCInfo(info *AccountInfo) C.fevm_account_info {
	var ci C.fevm_account_info
	if info.Exists {
		ci.exists = 1
	}
	if info.HasStorage {
		ci.has_storage = 1
	}
	if info.Warm {
		ci.warm = 1
	}
	ci.nonce = C.uint64_t(info.Nonce)
	copyWord(&ci.balance, info.Balance)
	copyWord(&ci.code_hash, info.CodeHash)
	return ci
}

// Execute runs all messages. host may be nil if all state was preloaded.
func (b *Batch) Execute(host Host) (int, error) {
	b.host = host
	h := cgo.NewHandle(b)
	defer h.Delete()
	ch := C.fastevm_make_host(C.uintptr_t(h))
	b.eng.mu.Lock()
	rc := C.fevm_batch_execute(b.b, &ch)
	b.eng.mu.Unlock()
	if rc != 0 {
		return int(rc), errors.New("fastevm: batch execution failed")
	}
	return 0, nil
}

func (b *Batch) Stats() Stats {
	var s C.fevm_batch_stats
	C.fevm_batch_stats_get(b.b, &s)
	return Stats{
		Rounds:          uint32(s.rounds),
		Requests:        uint64(s.requests),
		ExecSeconds:     float64(s.exec_seconds),
		HostSeconds:     float64(s.host_seconds),
		TransferSeconds: float64(s.transfer_seconds),
		TotalSeconds:    float64(s.total_seconds),
		CPURetriedLanes: uint64(s.cpu_retried_lanes),
	}
}

// Result copies lane i's result into Go memory.
func (b *Batch) Result(i int) *Result {
	r := C.fevm_batch_result(b.b, C.uint32_t(i))
	if r == nil {
		return nil
	}
	out := &Result{
		Status:  Status(r.status),
		Error:   uint32(r.error),
		GasLeft: uint64(r.gas_left),
		Refund:  int64(r.refund),
		Steps:   uint64(r.steps),
	}
	C.memcpy(unsafe.Pointer(&out.Created[0]), unsafe.Pointer(&r.created_address.bytes[0]), 20)
	if r.output_len > 0 {
		out.Output = C.GoBytes(unsafe.Pointer(r.output), C.int(r.output_len))
	}
	if r.n_accounts > 0 {
		accs := unsafe.Slice(r.accounts, int(r.n_accounts))
		out.Accounts = make([]AccountDiff, len(accs))
		for k := range accs {
			a := &accs[k]
			d := &out.Accounts[k]
			C.memcpy(unsafe.Pointer(&d.Address[0]), unsafe.Pointer(&a.address.bytes[0]), 20)
			C.memcpy(unsafe.Pointer(&d.Balance[0]), unsafe.Pointer(&a.balance.bytes[0]), 32)
			C.memcpy(unsafe.Pointer(&d.CodeHash[0]), unsafe.Pointer(&a.code_hash.bytes[0]), 32)
			d.Flags = uint32(a.flags)
			d.Nonce = uint64(a.nonce)
			if a.code_len > 0 {
				d.Code = C.GoBytes(unsafe.Pointer(a.code), C.int(a.code_len))
			}
		}
	}
	if r.n_slots > 0 {
		ss := unsafe.Slice(r.slots, int(r.n_slots))
		out.Slots = make([]SlotDiff, len(ss))
		for k := range ss {
			C.memcpy(unsafe.Pointer(&out.Slots[k].Address[0]), unsafe.Pointer(&ss[k].address.bytes[0]), 20)
			C.memcpy(unsafe.Pointer(&out.Slots[k].Key[0]), unsafe.Pointer(&ss[k].key.bytes[0]), 32)
			C.memcpy(unsafe.Pointer(&out.Slots[k].Value[0]), unsafe.Pointer(&ss[k].value.bytes[0]), 32)
		}
	}
	if r.n_logs > 0 {
		ls := unsafe.Slice(r.logs, int(r.n_logs))
		out.Logs = make([]Log, len(ls))
		for k := range ls {
			l := &ls[k]
			d := &out.Logs[k]
			C.memcpy(unsafe.Pointer(&d.Address[0]), unsafe.Pointer(&l.address.bytes[0]), 20)
			d.Topics = make([]Word, int(l.n_topics))
			for t := range d.Topics {
				C.memcpy(unsafe.Pointer(&d.Topics[t][0]), unsafe.Pointer(&l.topics[t].bytes[0]), 32)
			}
			if l.data_len > 0 {
				d.Data = C.GoBytes(unsafe.Pointer(l.data), C.int(l.data_len))
			}
		}
	}
	return out
}

//export fastevmGoFetch
func fastevmGoFetch(ctx unsafe.Pointer, sink *C.fevm_sink, reqs *C.fevm_request, n C.uint32_t) C.int {
	b := cgo.Handle(uintptr(ctx)).Value().(*Batch)
	if b.host == nil {
		return 1
	}
	rs := unsafe.Slice(reqs, int(n))
	for i := range rs {
		r := &rs[i]
		var addr Address
		C.memcpy(unsafe.Pointer(&addr[0]), unsafe.Pointer(&r.address.bytes[0]), 20)
		lane := uint32(r.lane)
		idx := C.uint32_t(i)
		switch r.kind {
		case C.FEVM_REQ_ACCOUNT:
			info := b.host.Account(lane, addr)
			ci := toCInfo(&info)
			var code *C.uint8_t
			if len(info.Code) > 0 {
				code = (*C.uint8_t)(unsafe.Pointer(&info.Code[0]))
			}
			C.fevm_sink_account(sink, idx, &ci, code, C.uint64_t(len(info.Code)))
		case C.FEVM_REQ_STORAGE:
			var key Word
			C.memcpy(unsafe.Pointer(&key[0]), unsafe.Pointer(&r.key.bytes[0]), 32)
			cur, orig, warm := b.host.Storage(lane, addr, key)
			var cc, co C.fevm_bytes32
			copyWord(&cc, cur)
			copyWord(&co, orig)
			var w C.uint8_t
			if warm {
				w = 1
			}
			C.fevm_sink_storage(sink, idx, &cc, &co, w)
		case C.FEVM_REQ_BLOCKHASH:
			h := b.host.BlockHash(lane, uint64(r.number))
			var ch C.fevm_bytes32
			copyWord(&ch, h)
			C.fevm_sink_blockhash(sink, idx, &ch)
		case C.FEVM_REQ_PRECOMPILE:
			var input []byte
			if r.input_len > 0 {
				input = C.GoBytes(unsafe.Pointer(r.input), C.int(r.input_len))
			}
			res := b.host.Precompile(lane, addr, input, uint64(r.gas))
			status := C.int(1)
			if res.OK {
				status = 0
			}
			var out *C.uint8_t
			if len(res.Output) > 0 {
				out = (*C.uint8_t)(unsafe.Pointer(&res.Output[0]))
			}
			C.fevm_sink_precompile(sink, idx, status, C.uint64_t(res.GasLeft), out, C.uint64_t(len(res.Output)))
		}
	}
	return 0
}

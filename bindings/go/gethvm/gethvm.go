// Package gethvm plugs the fastevm engine into go-ethereum through the
// vm.ExternalEngine hook (see integrations/geth.patch).
//
// Every top-level message (depth 0) runs on fastevm as a batch of one; state is
// read lazily from the EVM's StateDB and the resulting diff is written back.
// Messages the engine cannot run (unsupported fork, arena exhaustion, ...) fall
// back to the built-in interpreter.
package gethvm

import (
	"errors"
	"math/big"
	"os"
	"sync"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/core/vm"
	"github.com/fastevm/fastevm/bindings/go/fastevm"
	"github.com/holiman/uint256"
)

// Engine implements vm.ExternalEngine.
type Engine struct {
	cfg  fastevm.Config
	pool sync.Pool

	mu    sync.Mutex
	Stats Counters
}

// Counters track how messages were handled.
type Counters struct {
	Executed       uint64
	Fallbacks      uint64
	Skipped        uint64            // unsupported fork
	FallbackErrors map[uint32]uint64 // fastevm error code -> count
}

// New creates an engine using the given fastevm configuration.
func New(cfg fastevm.Config) *Engine {
	e := &Engine{cfg: cfg}
	e.pool.New = func() any {
		eng, err := fastevm.NewEngine(e.cfg)
		if err != nil {
			panic(err)
		}
		return eng
	}
	return e
}

// FromEnv builds an engine from FASTEVM_BACKEND (cpu|gpu, default cpu).
func FromEnv() *Engine {
	cfg := fastevm.Config{Backend: fastevm.BackendCPU, CPUThreads: 1}
	if os.Getenv("FASTEVM_BACKEND") == "gpu" {
		cfg.Backend = fastevm.BackendGPU
	}
	return New(cfg)
}

// Install sets the engine as vm.DefaultEngine.
func Install(e *Engine) { vm.DefaultEngine = e }

func (e *Engine) count(f func(c *Counters)) {
	e.mu.Lock()
	f(&e.Stats)
	e.mu.Unlock()
}

func word(b *big.Int) fastevm.Word {
	var w fastevm.Word
	if b != nil {
		u, _ := uint256.FromBig(b)
		if u != nil {
			w = u.Bytes32()
		}
	}
	return w
}

func u256Word(u *uint256.Int) fastevm.Word {
	if u == nil {
		return fastevm.Word{}
	}
	return u.Bytes32()
}

func (e *Engine) Execute(evm *vm.EVM, m *vm.EngineMessage) (vm.EngineResult, bool) {
	rules := evm.Rules()
	var fork fastevm.Fork
	switch {
	case rules.IsAmsterdam || rules.IsEIP4762 || rules.IsUBT:
		e.count(func(c *Counters) { c.Skipped++ })
		return vm.EngineResult{}, false
	case rules.IsOsaka:
		fork = fastevm.Osaka
	case rules.IsPrague:
		fork = fastevm.Prague
	case rules.IsCancun:
		fork = fastevm.Cancun
	default:
		e.count(func(c *Counters) { c.Skipped++ })
		return vm.EngineResult{}, false
	}
	ctx := &evm.Context
	blk := fastevm.BlockContext{
		Coinbase:    fastevm.Address(ctx.Coinbase),
		Number:      ctx.BlockNumber.Uint64(),
		Timestamp:   ctx.Time,
		GasLimit:    ctx.GasLimit,
		BaseFee:     word(ctx.BaseFee),
		BlobBaseFee: word(ctx.BlobBaseFee),
		ChainID:     word(evm.ChainConfig().ChainID),
		Fork:        fork,
	}
	if ctx.Random != nil {
		blk.PrevRandao = fastevm.Word(*ctx.Random)
	}
	msg := fastevm.Message{
		Create:      m.Create,
		Sender:      fastevm.Address(m.Caller),
		Recipient:   fastevm.Address(m.To),
		Value:       u256Word(m.Value),
		Gas:         m.Gas,
		Input:       m.Input,
		Origin:      fastevm.Address(evm.TxContext.Origin),
		GasPrice:    u256Word(evm.TxContext.GasPrice),
		UseHostWarm: true,
	}
	for _, h := range evm.TxContext.BlobHashes {
		msg.BlobHashes = append(msg.BlobHashes, fastevm.Word(h))
	}
	eng := e.pool.Get().(*fastevm.Engine)
	defer e.pool.Put(eng)
	batch := eng.NewBatch(&blk)
	defer batch.Close()
	batch.Add(&msg)
	host := &stateHost{evm: evm, db: evm.StateDB}
	if _, err := batch.Execute(host); err != nil {
		e.count(func(c *Counters) { c.Fallbacks++ })
		return vm.EngineResult{}, false
	}
	r := batch.Result(0)
	if r == nil || r.Status == fastevm.StatusFallback {
		e.count(func(c *Counters) {
			c.Fallbacks++
			if r != nil {
				if c.FallbackErrors == nil {
					c.FallbackErrors = make(map[uint32]uint64)
				}
				c.FallbackErrors[r.Error]++
			}
		})
		return vm.EngineResult{}, false
	}
	applyResult(evm, r)
	e.count(func(c *Counters) { c.Executed++ })
	res := vm.EngineResult{Ret: r.Output, GasLeft: r.GasLeft}
	if m.Create {
		res.Created = common.Address(r.Created)
	}
	switch r.Status {
	case fastevm.StatusSuccess:
	case fastevm.StatusRevert:
		res.Err = vm.ErrExecutionReverted
	case fastevm.StatusFailure:
		res.Failed = true
		res.Ret = nil
		res.Created = common.Address{}
		res.Err = mapError(r.Error)
	default:
		res.Err = mapError(r.Error)
		res.Ret = nil
		if r.Error == fastevm.ErrCollision {
			res.Created = common.Address{}
		}
	}
	return res, true
}

var errUnknown = errors.New("fastevm: execution halted")

func mapError(code uint32) error {
	switch code {
	case fastevm.ErrOutOfGas:
		return vm.ErrOutOfGas
	case fastevm.ErrInvalidOpcode:
		return &vm.ErrInvalidOpCode{}
	case fastevm.ErrStackUnderflow:
		return &vm.ErrStackUnderflow{}
	case fastevm.ErrStackOverflow:
		return &vm.ErrStackOverflow{}
	case fastevm.ErrBadJump:
		return vm.ErrInvalidJump
	case fastevm.ErrStaticViolation:
		return vm.ErrWriteProtection
	case fastevm.ErrReturnDataOOB:
		return vm.ErrReturnDataOutOfBounds
	case fastevm.ErrInsufficientFunds:
		return vm.ErrInsufficientBalance
	case fastevm.ErrDepth:
		return vm.ErrDepth
	case fastevm.ErrNonceOverflow:
		return vm.ErrNonceUintOverflow
	case fastevm.ErrCollision:
		return vm.ErrContractAddressCollision
	case fastevm.ErrCodeSize:
		return vm.ErrMaxCodeSizeExceeded
	case fastevm.ErrInitCodeSize:
		return vm.ErrMaxInitCodeSizeExceeded
	case fastevm.ErrInvalidCodePrefix:
		return vm.ErrInvalidCode
	case fastevm.ErrGasUintOverflow:
		return vm.ErrGasUintOverflow
	case fastevm.ErrPrecompile:
		return vm.ErrOutOfGas
	}
	return errUnknown
}

// applyResult writes the engine's state diff into the StateDB.
func applyResult(evm *vm.EVM, r *fastevm.Result) {
	db := evm.StateDB
	for i := range r.Accounts {
		d := &r.Accounts[i]
		addr := common.Address(d.Address)
		if d.Flags&fastevm.AccCreated != 0 {
			if !db.Exist(addr) {
				db.CreateAccount(addr)
			}
			db.CreateContract(addr)
		}
		if d.Flags&fastevm.AccBalance != 0 {
			want := new(uint256.Int).SetBytes32(d.Balance[:])
			cur := db.GetBalance(addr)
			switch want.Cmp(cur) {
			case 1:
				db.AddBalance(addr, new(uint256.Int).Sub(want, cur), tracing.BalanceChangeTransfer)
			case -1:
				db.SubBalance(addr, new(uint256.Int).Sub(cur, want), tracing.BalanceChangeTransfer)
			default:
				db.AddBalance(addr, new(uint256.Int), tracing.BalanceChangeTouchAccount)
			}
		} else if d.Flags&fastevm.AccTouched != 0 {
			db.AddBalance(addr, new(uint256.Int), tracing.BalanceChangeTouchAccount)
		}
		if d.Flags&fastevm.AccNonce != 0 {
			db.SetNonce(addr, d.Nonce, tracing.NonceChangeUnspecified)
		}
		if d.Flags&fastevm.AccCode != 0 {
			db.SetCode(addr, d.Code, tracing.CodeChangeContractCreation)
		}
		if d.Flags&fastevm.AccDestructed != 0 {
			db.SelfDestruct(addr)
		}
	}
	for i := range r.Slots {
		s := &r.Slots[i]
		db.SetState(common.Address(s.Address), common.Hash(s.Key), common.Hash(s.Value))
	}
	if r.Refund > 0 {
		db.AddRefund(uint64(r.Refund))
	} else if r.Refund < 0 {
		db.SubRefund(uint64(-r.Refund))
	}
	number := evm.Context.BlockNumber.Uint64()
	for i := range r.Logs {
		l := &r.Logs[i]
		topics := make([]common.Hash, len(l.Topics))
		for t := range l.Topics {
			topics[t] = common.Hash(l.Topics[t])
		}
		db.AddLog(&types.Log{Address: common.Address(l.Address), Topics: topics, Data: l.Data, BlockNumber: number})
	}
}

// stateHost serves engine state requests from the EVM's StateDB.
type stateHost struct {
	evm *vm.EVM
	db  vm.StateDB
}

func (h *stateHost) Account(lane uint32, a fastevm.Address) fastevm.AccountInfo {
	addr := common.Address(a)
	info := fastevm.AccountInfo{
		Exists: h.db.Exist(addr),
		Warm:   h.db.AddressInAccessList(addr),
	}
	if !info.Exists {
		return info
	}
	// Storage emptiness cannot be proven cheaply mid-block (pending writes are not
	// in the trie root yet), so always let the engine ask for slots.
	info.HasStorage = true
	info.Nonce = h.db.GetNonce(addr)
	info.Balance = h.db.GetBalance(addr).Bytes32()
	info.Code = h.db.GetCode(addr)
	info.CodeHash = fastevm.Word(h.db.GetCodeHash(addr))
	return info
}

func (h *stateHost) Storage(lane uint32, a fastevm.Address, key fastevm.Word) (fastevm.Word, fastevm.Word, bool) {
	cur, orig := h.db.GetStateAndCommittedState(common.Address(a), common.Hash(key))
	_, warm := h.db.SlotInAccessList(common.Address(a), common.Hash(key))
	return fastevm.Word(cur), fastevm.Word(orig), warm
}

func (h *stateHost) BlockHash(lane uint32, n uint64) fastevm.Word {
	res := h.evm.Context.GetHash(n)
	// Mirror opBlockhash: stateless witnesses must carry the ancestor header.
	if witness := h.db.Witness(); witness != nil {
		witness.AddBlockHash(n)
	}
	return fastevm.Word(res)
}

func (h *stateHost) Precompile(lane uint32, a fastevm.Address, input []byte, gas uint64) fastevm.PrecompileResult {
	addr := common.Address(a)
	p, ok := h.evm.Precompile(addr)
	if !ok {
		return fastevm.PrecompileResult{}
	}
	ret, left, err := vm.RunPrecompiledContract(h.db, p, addr, input, vm.NewGasBudget(gas, 0), nil, h.evm.Rules(), h.evm.PrecompileCache())
	if err != nil {
		return fastevm.PrecompileResult{}
	}
	return fastevm.PrecompileResult{OK: true, GasLeft: left.ExecutionGas, Output: ret}
}

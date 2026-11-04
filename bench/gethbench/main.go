// gethbench measures batch throughput of N independent EVM messages
// (distinct senders, same contract, same pre-state) on:
//
//	-engine geth         go-ethereum's interpreter, one StateDB per worker goroutine
//	-engine fastevm-cpu  fastevm CPU backend through the Go binding
//	-engine fastevm-gpu  fastevm CUDA backend through the Go binding
//
// It prints one JSON line with best/median wall time over -repeat runs.
package main

import (
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"math/big"
	"os"
	"runtime"
	"sort"
	"sync"
	"time"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/core/rawdb"
	"github.com/ethereum/go-ethereum/core/state"
	"github.com/ethereum/go-ethereum/core/tracing"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/core/vm"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"
	"github.com/ethereum/go-ethereum/triedb"
	"github.com/fastevm/fastevm/bindings/go/fastevm"
	"github.com/holiman/uint256"
)

type corpusItem struct {
	Name  string `json:"name"`
	Code  string `json:"code"`
	Input string `json:"input"`
	Gas   uint64 `json:"gas"`
}

var contract = common.HexToAddress("0x000000000000000000000000000000000000c0de")

func sender(i int) common.Address { return common.BigToAddress(big.NewInt(int64(0x100000 + i))) }

func osakaConfig() *params.ChainConfig {
	c := *params.MergedTestChainConfig
	c.AmsterdamTime = nil
	c.BogotaTime = nil
	return &c
}

func main() {
	var (
		corpus  = flag.String("corpus", "", "corpus item JSON")
		engine  = flag.String("engine", "geth", "geth | fastevm-cpu | fastevm-gpu")
		n       = flag.Int("n", 1000, "messages per batch")
		threads = flag.Int("threads", runtime.NumCPU(), "worker goroutines (geth) / CPU threads (fastevm-cpu)")
		repeat  = flag.Int("repeat", 5, "measured repetitions")
		arena   = flag.Uint64("arena", 0, "fastevm lane arena bytes (0 = backend default)")
	)
	flag.Parse()
	raw, err := os.ReadFile(*corpus)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	var item corpusItem
	if err := json.Unmarshal(raw, &item); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	code, _ := hex.DecodeString(item.Code)
	input, _ := hex.DecodeString(item.Input)

	var run func() (gasUsed uint64, extra map[string]any)
	switch *engine {
	case "geth":
		run = gethRunner(code, input, item.Gas, *n, *threads)
	case "fastevm-cpu", "fastevm-gpu":
		run = fastevmRunner(code, input, item.Gas, *n, *threads, *engine == "fastevm-gpu", *arena)
	default:
		fmt.Fprintln(os.Stderr, "unknown engine")
		os.Exit(2)
	}
	run() // warmup
	var times []float64
	var gas uint64
	var extra map[string]any
	for r := 0; r < *repeat; r++ {
		t0 := time.Now()
		gas, extra = run()
		times = append(times, time.Since(t0).Seconds())
	}
	sort.Float64s(times)
	best, median := times[0], times[len(times)/2]
	out := map[string]any{
		"engine": *engine, "name": item.Name, "batch": *n, "threads": *threads,
		"best_s": best, "median_s": median, "msgs_per_s": float64(*n) / median,
		"gas_used": gas, "mgas_per_s": float64(gas) / median / 1e6,
	}
	for k, v := range extra {
		out[k] = v
	}
	b, _ := json.Marshal(out)
	fmt.Println(string(b))
}

func gethRunner(code, input []byte, gas uint64, n, threads int) func() (uint64, map[string]any) {
	cfg := osakaConfig()
	blockCtx := vm.BlockContext{
		CanTransfer: func(db vm.StateDB, a common.Address, v *uint256.Int) bool { return db.GetBalance(a).Cmp(v) >= 0 },
		Transfer: func(db vm.StateDB, from, to common.Address, v *uint256.Int, _ *params.Rules) {
			db.SubBalance(from, v, tracing.BalanceChangeTransfer)
			db.AddBalance(to, v, tracing.BalanceChangeTransfer)
		},
		GetHash:     func(uint64) common.Hash { return common.Hash{} },
		BlockNumber: big.NewInt(1),
		Time:        1,
		GasLimit:    gas,
		BaseFee:     big.NewInt(0),
		BlobBaseFee: big.NewInt(0),
		Random:      &common.Hash{},
	}
	type worker struct {
		db  *state.StateDB
		evm *vm.EVM
	}
	workers := make([]*worker, threads)
	for t := range workers {
		tdb := triedb.NewDatabase(rawdb.NewMemoryDatabase(), nil)
		db, _ := state.New(types.EmptyRootHash, state.NewDatabase(tdb, nil))
		db.SetCode(contract, code, tracing.CodeChangeUnspecified)
		db.SetNonce(contract, 1, tracing.NonceChangeUnspecified)
		db.Finalise(params.Rules{})
		evm := vm.NewEVM(blockCtx, db, cfg, vm.Config{})
		workers[t] = &worker{db: db, evm: evm}
	}
	rules := workers[0].evm.Rules()
	precompiles := vm.ActivePrecompiles(rules)
	return func() (uint64, map[string]any) {
		var wg sync.WaitGroup
		gasUsed := make([]uint64, threads)
		for t := 0; t < threads; t++ {
			wg.Add(1)
			go func(t int) {
				defer wg.Done()
				w := workers[t]
				for i := t; i < n; i += threads {
					s := sender(i)
					snap := w.db.Snapshot()
					w.db.Prepare(rules, s, common.Address{}, &contract, precompiles, nil)
					w.evm.SetTxContext(vm.TxContext{Origin: s, GasPrice: new(uint256.Int)})
					_, left, _ := w.evm.Call(s, contract, input, vm.NewGasBudget(gas, 0), new(uint256.Int))
					gasUsed[t] += gas - left.ExecutionGas
					w.db.RevertToSnapshot(snap)
				}
			}(t)
		}
		wg.Wait()
		var total uint64
		for _, g := range gasUsed {
			total += g
		}
		return total, nil
	}
}

// memHost answers state requests for accounts that were not preloaded (none exist).
type memHost struct{}

func (memHost) Account(uint32, fastevm.Address) fastevm.AccountInfo { return fastevm.AccountInfo{} }
func (memHost) Storage(uint32, fastevm.Address, fastevm.Word) (fastevm.Word, fastevm.Word, bool) {
	return fastevm.Word{}, fastevm.Word{}, false
}
func (memHost) BlockHash(uint32, uint64) fastevm.Word { return fastevm.Word{} }
func (memHost) Precompile(uint32, fastevm.Address, []byte, uint64) fastevm.PrecompileResult {
	return fastevm.PrecompileResult{}
}

func fastevmRunner(code, input []byte, gas uint64, n, threads int, gpu bool, arena uint64) func() (uint64, map[string]any) {
	cfg := fastevm.Config{Backend: fastevm.BackendCPU, CPUThreads: uint32(threads), LaneArenaBytes: arena}
	if gpu {
		cfg.Backend = fastevm.BackendGPU
	}
	eng, err := fastevm.NewEngine(cfg)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	blk := fastevm.BlockContext{Number: 1, Timestamp: 1, GasLimit: gas, Fork: fastevm.Osaka}
	blk.ChainID[31] = 1
	codeHash := fastevm.Word(crypto.Keccak256Hash(code))
	msgs := make([]fastevm.Message, n)
	for i := range msgs {
		s := fastevm.Address(sender(i))
		msgs[i] = fastevm.Message{Sender: s, Origin: s, Recipient: fastevm.Address(contract), Gas: gas, Input: input}
	}
	return func() (uint64, map[string]any) {
		b := eng.NewBatch(&blk)
		defer b.Close()
		b.PreloadAccount(fastevm.Address(contract), &fastevm.AccountInfo{Exists: true, Nonce: 1, CodeHash: codeHash, Code: code})
		for i := range msgs {
			b.PreloadAccount(msgs[i].Sender, &fastevm.AccountInfo{})
			b.Add(&msgs[i])
		}
		if _, err := b.Execute(memHost{}); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		var total uint64
		fallbacks := 0
		for i := 0; i < n; i++ {
			st, left := b.Summary(i)
			if st == fastevm.StatusFallback {
				fallbacks++
			}
			total += gas - left
		}
		st := b.Stats()
		return total, map[string]any{"rounds": st.Rounds, "exec_s": st.ExecSeconds, "transfer_s": st.TransferSeconds,
			"host_s": st.HostSeconds, "engine_total_s": st.TotalSeconds, "fallbacks": fallbacks,
			"cpu_retried": st.CPURetriedLanes}
	}
}

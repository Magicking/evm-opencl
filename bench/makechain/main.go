// makechain writes a synthetic Osaka chain for the block-import benchmark (workload C):
// <out>/genesis.json and <out>/chain.rlp, built with go-ethereum's core.GenerateChain so headers
// carry valid state, receipt and request roots that any client can import.
//
//	-workload erc20     blocks full of ERC20-style transfers (distinct senders); a -conflict
//	                    fraction sends to one hot recipient (shared storage slot)
//	-workload mixed     transfers interleaved with 256-bit arithmetic and keccak loops
//
// Contracts are the bench/corpus programs (erc20_transfer, arith_loop, keccak_loop).
package main

import (
	"crypto/ecdsa"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"maps"
	"math/big"
	"os"
	"path/filepath"

	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/consensus/beacon"
	"github.com/ethereum/go-ethereum/consensus/ethash"
	"github.com/ethereum/go-ethereum/core"
	"github.com/ethereum/go-ethereum/core/types"
	"github.com/ethereum/go-ethereum/crypto"
	"github.com/ethereum/go-ethereum/params"
	"github.com/ethereum/go-ethereum/rlp"
)

type corpusItem struct {
	Code  string `json:"code"`
	Input string `json:"input"`
}

func load(dir, name string) (code, input []byte) {
	raw, err := os.ReadFile(filepath.Join(dir, name+".json"))
	must(err)
	var it corpusItem
	must(json.Unmarshal(raw, &it))
	code, err = hex.DecodeString(it.Code)
	must(err)
	input, err = hex.DecodeString(it.Input)
	must(err)
	return code, input
}

func must(err error) {
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func key(i int) *ecdsa.PrivateKey {
	var b [32]byte
	big.NewInt(int64(i + 1)).FillBytes(b[:])
	k, err := crypto.ToECDSA(b[:])
	must(err)
	return k
}

var (
	erc20Addr  = common.HexToAddress("0x00000000000000000000000000000000000e2c20")
	arithAddr  = common.HexToAddress("0x000000000000000000000000000000000000a417")
	keccakAddr = common.HexToAddress("0x000000000000000000000000000000000000ecca")
	hotAddr    = common.HexToAddress("0x00000000000000000000000000000000000000f0")
)

// transfer(to, amount) calldata for the corpus ERC20 program.
func transferInput(to common.Address, amount uint64) []byte {
	in := make([]byte, 4+64)
	copy(in, []byte{0xa9, 0x05, 0x9c, 0xbb})
	copy(in[4+12:4+32], to[:])
	new(big.Int).SetUint64(amount).FillBytes(in[4+32 : 4+64])
	return in
}

func main() {
	var (
		corpus   = flag.String("corpus", "bench/corpus", "corpus directory")
		out      = flag.String("out", "build/chain", "output directory")
		blocks   = flag.Int("blocks", 20, "number of blocks")
		gasLimit = flag.Uint64("gas", 60_000_000, "block gas limit")
		workload = flag.String("workload", "erc20", "erc20 | mixed")
		conflict = flag.Float64("conflict", 0, "fraction of transfers to one hot recipient")
		senders  = flag.Int("senders", 20000, "funded sender accounts")
	)
	flag.Parse()
	erc20Code, _ := load(*corpus, "erc20_transfer")
	arithCode, arithIn := load(*corpus, "arith_loop")
	keccakCode, keccakIn := load(*corpus, "keccak_loop")

	config := *params.MergedTestChainConfig
	config.ChainID = big.NewInt(1337)
	config.AmsterdamTime = nil
	config.BogotaTime = nil
	alloc := types.GenesisAlloc{
		erc20Addr:  {Code: erc20Code, Nonce: 1},
		arithAddr:  {Code: arithCode, Nonce: 1},
		keccakAddr: {Code: keccakCode, Nonce: 1},
	}
	maps.Copy(alloc, core.SystemContractAllocs())
	for a, acc := range alloc {
		if acc.Balance == nil { // reth's genesis parser requires an explicit balance
			acc.Balance = new(big.Int)
			alloc[a] = acc
		}
	}
	keys := make([]*ecdsa.PrivateKey, *senders)
	funds, _ := new(big.Int).SetString("1000000000000000000000000", 10)
	for i := range keys {
		keys[i] = key(i)
		alloc[crypto.PubkeyToAddress(keys[i].PublicKey)] = types.Account{Balance: funds}
	}
	genesis := &core.Genesis{
		Config:     &config,
		GasLimit:   *gasLimit,
		Difficulty: big.NewInt(0),
		BaseFee:    big.NewInt(params.InitialBaseFee),
		Timestamp:  0,
		Alloc:      alloc,
	}

	signer := types.LatestSigner(&config)
	nonces := make([]uint64, len(keys))
	next := 0 // round-robin sender
	txn := 0
	mk := func(b *core.BlockGen, to common.Address, input []byte, gas uint64) bool {
		if b.Gas() < gas {
			return false
		}
		s := next
		next = (next + 1) % len(keys)
		tx := types.MustSignNewTx(keys[s], signer, &types.DynamicFeeTx{
			ChainID:   config.ChainID,
			Nonce:     nonces[s],
			GasTipCap: big.NewInt(1),
			GasFeeCap: big.NewInt(100 * params.GWei),
			Gas:       gas,
			To:        &to,
			Data:      input,
		})
		nonces[s]++
		b.AddTx(tx)
		txn++
		return true
	}
	hot := 0
	recipient := func(i int) common.Address {
		// Deterministic conflict pattern: every k-th transfer hits the hot slot.
		if *conflict > 0 && float64(hot+1)/float64(i+1) <= *conflict {
			hot++
			return hotAddr
		}
		return common.BigToAddress(big.NewInt(int64(0x5000000 + i)))
	}
	engine := beacon.New(ethash.NewFaker())
	_, chain, _ := core.GenerateChainWithGenesis(genesis, engine, *blocks, func(n int, b *core.BlockGen) {
		b.SetCoinbase(common.HexToAddress("0x000000000000000000000000000000000000c0b0"))
		for i := 0; ; i++ {
			var ok bool
			switch {
			case *workload == "mixed" && i%10 == 3:
				ok = mk(b, arithAddr, arithIn, 2_000_000)
			case *workload == "mixed" && i%10 == 7:
				ok = mk(b, keccakAddr, keccakIn, 800_000)
			default:
				ok = mk(b, erc20Addr, transferInput(recipient(txn), 1000), 100_000)
			}
			if !ok {
				break
			}
		}
	})

	must(os.MkdirAll(*out, 0o755))
	gj, err := json.MarshalIndent(genesis, "", " ")
	must(err)
	must(os.WriteFile(filepath.Join(*out, "genesis.json"), gj, 0o644))
	f, err := os.Create(filepath.Join(*out, "chain.rlp"))
	must(err)
	var gas uint64
	for _, blk := range chain {
		must(rlp.Encode(f, blk))
		gas += blk.GasUsed()
	}
	must(f.Close())
	meta := map[string]any{
		"blocks": len(chain), "txs": txn, "gas_used": gas, "gas_limit": *gasLimit,
		"workload": *workload, "conflict": *conflict, "hot_transfers": hot,
	}
	mj, _ := json.Marshal(meta)
	must(os.WriteFile(filepath.Join(*out, "meta.json"), mj, 0o644))
	fmt.Println(string(mj))
}

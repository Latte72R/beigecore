# Store Buffer・Load forwarding・8段相当パイプライン化メモ

## 目的

`feat/out-of-order` の `722161a` を基準に、次の2点を同時に改善した。

1. Store完了待ちとLoad待ちを減らしてCoreMarkのサイクル数を約40万まで下げる。
2. サイクル短縮で露出した長い組合せ経路を、7〜10段の範囲を意識して切り直す。

変更は、まず既存の不自然な待ち段を外してサイクル数を測り、その後に必要な場所だけ
登録段を戻す順番で行った。最終構成は、すべての命令に固定の8サイクルを課す構成では
なく、FIFOとIssue Queueを境界に使った**実効8段のelastic pipeline**である。

## 最終結果

| 構成 | CoreMark cycles | 合成クリティカルパス | ISA test |
|---|---:|---:|---:|
| 変更前 `722161a` | 506,847 | 4.870 ns | - |
| Store Buffer初版 | 467,795 | 4.870 ns | 67/67 |
| 古い待ち段を接続した版 | 459,625 | 6.580 ns | 67/67 |
| サイクル優先・再分割前 | 396,904 | 6.820 ns | 67/67 |
| **最終8段相当版** | **404,523** | **5.620 ns / 45 levels** | **67/67** |

最終版は再分割前より7,619 cycles、1.92%増えた。一方、クリティカルパスは
6.820 nsから5.620 nsへ1.200 ns、17.6%短くなった。変更前と比べると
102,326 cycles、20.2%短縮し、クリティカルパスは0.750 ns長い。

合成規模は以下の通り。

- 220,365 gates
- 28,127 flip-flops
- 274,609,806.00 um^2
- 118.7360 mW（Makefileの100 MHz、activity 0.10設定）

面積の大部分は推定RAMが占めるため、総面積差を見る際はRAMを分けて考える必要がある。

## 最終的な段構成

1. **Fetch request**
   命令メモリへ8-byte単位の要求を送る。
2. **Instruction memory response / Fetch FIFO**
   応答アドレスと64-bit命令列を保持する。
3. **Align / RVC / early prediction**
   命令境界を選び、RVCを展開し、分岐・JAL・JALRに必要な最小限のpredecodeを行う。
4. **Decode / Rename / Dispatch**
   完全な命令decode、RAT参照、物理レジスタ割当、ROB・各Issue Queueへの投入を行う。
5. **Issue / Physical Register File read**
   readyな命令を選び、source operandを読む。
6. **Execute / Address generation**
   ALU・分岐判定、またはLoad/Store実効アドレスを生成する。
7. **Memory / Store CAM registered result**
   older StoreがあるLoadではStore Buffer CAM結果を登録する。メモリ応答時に登録済み
   forwarding値を選ぶ。
8. **ROB commit / Store Buffer drain**
   ROBをin-order commitし、commit済みStoreをバックグラウンドでメモリへ書き出す。

Fetch FIFOとIssue FIFOは空のときfall-throughできる。通常LoadにもStore CAM段を強制すると
CoreMarkが436,457 cyclesまで増えたため、older StoreがないLoadにはdirect fast pathを残した。
したがって段数は命令種別とbackpressureで変わる。

## Store Buffer

`src/store_buffer.veryl` に4-entry Store Bufferを追加した。各entryは以下を保持する。

- 8-byte境界を含むStore address
- byte laneへshift済みのStore data
- byte write mask
- ROB tag
- commit済みかを示す`committed`

Store命令は実行時にメモリへ書かず、アドレスとデータをStore Bufferへ入れた時点でROB上の
実行完了になる。対応StoreがROB headへ到達するとentryを`committed`にして、ROBはメモリ
応答を待たずにretireする。commit済み先頭entryは、その後データポートが空いたときに
順番を守ってdrainする。

分岐rollbackではROB tagを使って若い未commit Storeだけを削除する。CSR trapなどのflushでも
commit済みentryはarchitectural stateなので保持し、未commit entryだけを捨てる。

データポートはLoad用MEMUとStore Buffer drainで共有する。commit済みStoreのdrain中は
Store Buffer側を選択し、新規Load要求を開始しない。

## Load-to-Store Forwarding

Loadのアドレスとbyte maskを4つのStore Buffer entryへ比較する。複数entryが一致する場合は、
ROB順で最も若いolder Storeを採用する。

- Loadの全byteを1つのolder Storeが覆う場合は、そのentryからforwardする。
- 一部byteだけが重なる場合はメモリ値とのbyte mergeを行わず、該当するolder Storeが
  drainするまで待つ。
- older Store Buffer entryがないLoadはStore CAMを通らずMEMUへ直接進む。

初期の登録CAM版では、部分一致まで通常メモリへ進めたため`rv64ui-p-sb`と`rv64ui-p-sh`が
失敗した。最終版では部分一致を`load_stage_blocked`として登録し、older Storeがなくなって
からLoadを再開する。完全一致forwardingと通常Loadのfast pathは維持している。

## Load段の切り直し

サイクル優先版では、Issue選択、PRF read、Load address加算、Store Buffer CAM、MEMU要求が
同じ組合せ経路に入った。部分一致判定をLoad grantへ直接戻すだけでは6.210 nsとなり、
CAMからデータメモリ制御までが再びクリティカルになった。

そこで以下を登録するLoad専用段を追加した。

- `load_stage_entry`
- `load_stage_addr`
- `load_stage_blocked`
- `load_stage_forward_valid`
- `load_stage_forward_data`

older StoreがあるLoadだけこの段に入り、次サイクル以降にMEMU要求を開始する。older Storeが
ないLoadは`load_direct_start`で同じサイクルにMEMUを開始する。この選択により、CAM経路を
切りながらCoreMarkを404,523 cyclesに抑えた。

## Fetchと分岐予測

従来は完全な`inst_decoder`の結果から予測redirectを生成していた。最終版では
`inst_fetcher`内でopcodeとB/J immediateだけを生成する軽量predecodeを行う。

予測結果の`pred_taken`と`pred_target`は命令と一緒にIssue FIFOへ保存する。Fetch redirectは
命令がIssue FIFOへ受理された時点で行うため、backendのdispatch readyを待たない。Bimodal
predictorとBTBのquery PCもこの早期predecode側から送る。

分岐ミス時の訂正FetchはALU判定から直接命令RAMへ返さず、既存の
`rob_rollback_request`と`rob_rollback_request_pc`を通す。これにより分岐比較から命令RAMまでの
経路を切った。この変更によるCoreMark増加は小さく、変更時点の比較で397,128から
397,318 cyclesへの190 cyclesだった。

早期予測に合わせ、Konataの`PRED`イベントもcoreのdispatch位置から`inst_fetcher`の
Issue FIFO受理位置へ移した。変換器は早期予測時点ではfrontend内に若い命令がないことを
反映し、以前発生していた大量の`unmatched X`警告を出さない。

## FIFOとIssue Queue

`fifo.veryl`へ`FALL_THROUGH` parameterを追加した。FIFOが空なら入力を出力へ直接渡し、
同じサイクルにconsumerが受理した場合はentryへ保存しない。

Fetch FIFOとIssue FIFOでfall-throughを有効にし、命令メモリ応答から空FIFOへ入るだけの
bubbleを削除した。これが459,625 cyclesから396,904 cyclesへ近づける主要因の1つである。

`issue_queue.veryl`には`ALLOW_REPLACE` parameterを追加した。popとpushが同時に起きる場合に
空slotを1サイクル待たず再利用できる。Load Queueでは必要に応じて置換を抑制できる。

## MEMU要求開始

`memunit.veryl`は`Init`状態で有効な命令を受けると、同じサイクルにMembus要求を出す。
以前は要求内容を登録してから`WaitReady`で要求を始めていたため、すべてのLoadに固定の
1-cycle待ちが入っていた。

requestが同サイクルにacceptされた場合は直接`WaitValid`へ入り、acceptされなければ
`WaitReady`へ移る。要求アドレス、mask、AMO属性は応答まで内部registerに保持する。

## 途中で外した不要な境界

再分割前に以下を接続し、各変更をCoreMarkとISA testで確認した。

- Store Buffer CAM結果を一律1サイクル待つ境界
- Load Issue Queueのpop後にreplaceを禁止するbubble
- MEMUが要求を始めるまでの固定1-cycle待ち
- CSR実行結果を保持する`csru_active`
- 旧登録CAM方式に残っていた未使用version state

一方、以下はprotocolまたはarchitectural stateを保持するため残した。

- outstanding memory transactionを保持する`memu_active`
- multi-cycle MDUのactive entry
- ROB tail walk、RAT/free-list修復、全Queue squashを同期するrollback state
- CSR・fence・system命令用の`serial_pending`
- 実装可能な分岐回復範囲を制限する`branch_pending`

## 変更ファイル

- `src/core.veryl`
  Store Buffer統合、commit/drain制御、Load CAM段、forwarding、早期予測interface、登録済み
  rollback Fetchを実装。
- `src/store_buffer.veryl`
  4-entry Store Buffer、CAM、forwarding、partial overlap block、squash、非同期drainを実装。
- `src/core_inst_if.veryl`
  predictor queryと予測metadata信号を追加。
- `src/inst_fetcher.veryl`
  軽量predecode、早期prediction redirect、予測metadata保持を実装。
- `src/fifo.veryl`
  optional fall-throughを追加。
- `src/issue_queue.veryl`
  pop/push同時置換をparameter化。
- `src/memunit.veryl`
  新規memory requestを同サイクルに開始可能に変更。
- `test/konata.py`
  早期予測時点のtrace処理へ更新。

## 検証方法

最終版で以下を実行した。

```text
make bench
  cycles: 404523
  Konata trace: results/konata.log

make synth
  timing: 5.620 ns
  levels: 45
  critical path: frontend fetch FIFO / RVC / prediction / instruction RAM

make test
  rv64ui-p: 53 / 53
  rv64um-p: 13 / 13
  rv64uc-p:  1 / 1
```

最終クリティカルパスはFetch FIFO、RVC展開、予測target生成、次の命令RAM要求である。
Store Buffer CAMからデータメモリ要求への経路、および分岐実行から命令RAMへの経路は
クリティカルパスから外れた。

`make synth`の値はSkyWater SKY130 HD、tt_025C_1v80を使った概算で、wire loadを含まない。
配置配線後の周波数保証ではなく、RTL間の相対比較として扱う。

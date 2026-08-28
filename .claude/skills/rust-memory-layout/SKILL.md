---
name: rust-memory-layout
description: Rust で「長寿命かつ挿入後は不変」なデータ (キャッシュエントリ、in-memory テーブル、解析済みレコード、DO/Worker の常駐 state) を大量に保持するときのメモリレイアウト最適化チェックリスト。Cloudflare 1.1.1.1 の DNS キャッシュ最適化 (エントリ 953→420 B、-56%、しかも insert +43% / lookup -19%) から抽出した 5 手法と測り方。(1) 不変なら `Vec<T>`/`String` を `Box<[T]>`/`Box<str>` に (capacity 8 B + 余剰 heap を捨てる)、(2) 並列する複数リストは 1 本 + `u16` オフセット、bool 群は bitflags でパディングも削る、(3) 大半が同じ値のフィールドは `Option<Box<_>>` で省略し読み出し時に復元、(4) enum は最大 variant のサイズになる → 大きく稀な variant だけ `Box` する、(5) 最終形は wire/serialized 形式の `Box<[u8]>` で連続保持 (allocator size class と CPU キャッシュ局所性の両方を解く)。計測は `size_of::<T>()` + `GlobalAlloc` ラッパ + resident memory。トリガー: 「メモリ使用量を減らしたい」「RSS が増え続ける」「struct のサイズ」「size_of」「enum が大きい」「Box<[T]>」「Vec の capacity」「パディング」「repr」「jemalloc」「キャッシュに何百万件持つ」「HashMap の値が重い」「DO の storage/メモリ上限」「Cloud Run の instance memory 削減」等、Rust の常駐データ量が問題になる場面で必ず参照。
---

# rust-memory-layout

Rust で「一度作ったら変更しない」データを大量に持つ構造 (cache、in-memory index、
解析済みレコード、常駐 state) のメモリを削るときの手順と判断基準。

出典: [How we saved 100 terabytes of memory by optimizing 1.1.1.1's DNS cache](https://blog.cloudflare.com/dns-cache-memory-optimization-1111/) (Cloudflare, 2026-08-27)。
250 億エントリ規模の話だが、手法自体はエントリ数 × 1 バイトが効くあらゆる構造に当てはまる。

## 適用判定 (最初に確認)

以下がすべて Yes なら本 skill の手法が効く。

- 対象の値は **挿入後に mutate しない** (更新は丸ごと置換)
- エントリ数が **万〜億**、または 1 instance の RSS の主因になっている
- 読み出し側で **キー (or 文脈) が手元にある** (省略したフィールドを復元できる)

No が混じる場合 (頻繁に push する、件数が少ない) は、削っても得られるのは
数 KB で、可読性を落とす価値がない。**先に測ってから手を付ける**。

## 測り方 (手法より先にこれ)

1. **静的サイズ**: `std::mem::size_of::<CacheEntry>()` / `size_of::<Record>()` /
   `size_of::<RecordData>()` を test か `cargo run --example` で出力する。
   enum は `size_of` だけで問題が見える (下記 手法 4)。
2. **動的 (heap) サイズ**: `GlobalAlloc` を wrap したカウンタ allocator を
   ベンチ用に入れ、1 エントリ挿入あたりの **allocation 回数と合計バイト** を取る。
   本番トラフィック分布に寄せたダミーデータで埋める (1.1.1.1 は A 56% / AAAA 25% / TXT 19%)。
3. **本番 RSS**: p90/p98/p99 の resident memory をロールアウト前後で見る。
   再起動直後は cache が空なので **plateau で比較する** (初期の落ち込みは実力ではない)。
4. 同時に **insert throughput と lookup latency** も取る。メモリを削ると
   allocation が減って速くなるのが普通で、遅くなったら手法 4 の副作用 (下記) を疑う。

## 手法 1: 不変なら `Vec<T>` → `Box<[T]>`、`String` → `Box<str>`

`Vec` は ptr + len + capacity の 24 B。挿入後に伸びないなら capacity の 8 B と、
growth 戦略で取り過ぎた heap の余剰 (cap 8 で len 5 = 3 slot 無駄) が純粋な損。
`Box<[T]>` / `Box<str>` は 16 B で余剰なし。

```rust
// before
pub struct CacheEntry { answers: Vec<Record>, errors: Vec<ExtendedError>, name: String, .. }

// after
pub struct CacheEntry { answers: Box<[Record]>, errors: Box<[ExtendedError]>, name: Box<str>, .. }
```

- 変換は `vec.into_boxed_slice()` / `string.into_boxed_str()` (shrink されて再確保が
  走ることがあるので、**組み立て中は Vec、格納直前に Box** が定石)
- フィールドが 8 本あれば 64 B/entry。1.1.1.1 ではこれだけで 15 TB
- 副作用なし。**最初にやる**

## 手法 2: 並列リストを 1 本にまとめてオフセットで区切る

answer / authority / additional のように「同じ型の複数セクション」は、
3 本の `Box<[T]>` (16 B × 3) ではなく **1 本 + 区切りオフセット** にする。
件数が `u16` に収まるならオフセットは 2 B。

```rust
pub struct CacheEntry {
    records: Box<[Record]>,   // 全セクション連結
    authority_start: u16,     // records[authority_start..additional_start] が authority
    additional_start: u16,
    ..
}
```

- 16 B × 2 → 2 B × 2 で 28 B/entry
- **bool が複数あれば `bitflags` で 1 バイトに畳む**。bool 自体は 1 B でも、
  alignment のパディングが消えて struct が **bool の合計以上に縮む**ことがある
- 順序が意味を持つならこの形でよい。ランダムアクセスが要るなら手法 5 の前に立ち止まる

## 手法 3: 大半が同じ値のフィールドは省略して読み出し時に復元

DNS の record owner は大半がクエリ名と同じ。同じなら持たず、違うときだけ持つ。

```rust
pub struct Record {
    owner: Option<Box<Name>>,  // None = キーの名前と同じ。Some = CNAME 先など別名
    ..
}
```

- レコードは self-contained でなくなるが、lookup 時にキーは必ず手元にあるので
  復元コストはゼロに近い
- 適用条件: 「読み出し文脈から復元できる」かつ「同値率が高い (目安 8 割以上)」
- 同種の例: tenant_id / company_code のようにキーに含まれる値を値側にも重複して
  持っているケース。**値側から消す**

## 手法 4: enum は最大 variant のサイズになる → 大きく稀な variant だけ Box

Rust の enum は常に **最大 variant + tag + padding** のサイズ。
`RecordData` は NAPTR (136 B) に引きずられて 144 B、A (4 B) / AAAA (16 B) が 8 割超
なのに毎回 120 B 以上のパディングを持っていた。

```rust
pub enum RecordData {
    A(Ipv4Addr),          // 小さく頻出 → inline
    Aaaa(Ipv6Addr),
    Txt(Box<Txt>),        // 大きい/稀 → heap
    Naptr(Box<Naptr>),
    Svcb(Box<Svcb>),
}
```

- enum は 24 B に。A/AAAA は 120 B/record 削減、TXT 等も heap 側が実サイズ
- 最大 variant (NAPTR) は pointer + allocation overhead 分**むしろ増える**。
  稀なら許容。**頻度分布を見て決める**
- `size_of` が 100 B を超える enum、または variant 間のサイズ差が 5 倍以上なら疑う。
  `clippy::large_enum_variant` が同じことを警告する

### Box 化の副作用 (ここで止まらない理由)

1. **allocator の size class 切り上げ**: jemalloc は近いサイズをビンに丸める。
   32 B 要求は 32 B ビンで無駄ゼロ、40 B 要求は 48 B ビンで 8 B 無駄。
   小さな Box が大量にあると、この端数が積み上がる
2. **局所性の悪化**: Box 化した variant は heap のあちこちに散る。読むたびに
   pointer を追って別の cache line を fetch する。エントリ数が増えるほど効く

この 2 つが lookup latency を押し上げる。手法 5 で両方を消す。

## 手法 5: serialized (wire) 形式の `Box<[u8]>` で連続保持

解析済み enum のリストではなく、**各レコードを「2 B 長さプレフィックス + 生バイト」で
連結した 1 本の `Box<[u8]>`** にする。

```rust
pub struct CacheEntry {
    // [len:u16][record bytes][len:u16][record bytes]...
    record_data: Box<[u8]>,
    ..
}
```

- 手法 4 の enum overhead も個別 Box も消え、データが連続するので CPU キャッシュに乗る
- 出力側は多くの型で **memcpy で済む** (A/AAAA/TXT/DNSSEC 系)。名前圧縮が要る
  CNAME/NS/MX/SOA だけ parse する。1.1.1.1 では lookup latency がこれ単体で 5% 改善
- トレードオフ: **ランダムアクセス不可、順次走査のみ**。round-robin のような
  「n 番目を取る」操作は走査になるが、1 エントリあたりの件数が小さければ無視できる
- 「レスポンス全体を wire 形式で持つ」まで行くと、条件付きで変わる部分 (DNSSEC の
  DO flag 有無など) のために 2 系統 cache するか出力時にフィルタが要る。
  **可変部分は構造化フィールドに残し、固定部分だけ生バイト**が中間解

### 組み立て時の allocation を 1 回にする

サイズは serialize してみるまで分からない。**再利用する scratch buffer** に書いてから
`Box<[u8]>` を確保して 1 回 `memcpy` する。

```rust
struct Builder { scratch: Vec<u8> }  // 挿入間で使い回す。一度伸びたら再確保されない

impl Builder {
    fn build(&mut self, records: &[Record]) -> Box<[u8]> {
        self.scratch.clear();
        for r in records { r.write_to(&mut self.scratch); }
        self.scratch.as_slice().into()   // 実サイズぴったりの 1 allocation
    }
}
```

`Vec<u8>` を `into_boxed_slice()` で shrink するのと違い、allocator が元の
allocation の尻尾を回収できない問題を避けられる。1.1.1.1 では insert throughput +13%。

## 適用順と期待値

| 順 | 手法 | 効果 | 副作用 |
|---|---|---|---|
| 1 | Vec/String → Box | 8 B/field + 余剰 heap | なし |
| 2 | リスト統合 + bitflags | 数十 B/entry、パディング減 | ランダムアクセス性はそのまま |
| 3 | 同値フィールド省略 | field 分 + heap alloc 1 回/record | 読み出しに文脈が要る |
| 4 | 大 variant を Box | 頻出 variant で 100 B 級 | size class 端数、局所性悪化 |
| 5 | 生バイト連続保持 | 4 の副作用を消して更に縮む + 速くなる | 順次走査のみ |

1〜2 は機械的で安全。3 は設計判断。4 は `size_of` を見て決め、
やるなら 5 までセットで考える (4 で止まると遅くなることがある)。

## ippoan での当てはめ

- `rust-ichibanboshi` / `rust-alc-api` の in-memory キャッシュや解析済み CSV 行、
  `HashMap<Key, Vec<Row>>` 形の常駐データ: まず `size_of` と allocation/entry を測る
- Cloudflare Workers / DO (Rust wasm) の常駐 state: 128 MB 制限に当たる前に
  手法 1・4 で enum と Vec を見直す
- Cloud Run の instance memory を下げたい: RSS の plateau で比較する。再起動直後の
  数値で判断しない

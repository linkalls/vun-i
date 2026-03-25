# vun-i Refactoring Spec: Bun-Compatible Direct Hardlink Architecture

## Goal

`bun install` の完全代替として、**cold で pnpm より速く**、**warm で bun より速く**。

### Target Benchmarks (Windows)

| Scenario | 現状 | 目標 |
|---|---|---|
| true-cold | 2307ms | < 1294ms (pnpm 超え) |
| warm | 1216ms | < 389ms (bun 超え) |

***

## Root Cause Analysis

### なぜ今遅いか

vun-i は **2層ストア構造**（pnpm 式）を bun のキャッシュ形式の上に乗せてるのが根本原因なのだ ：

```
【現状のフロー】
cache/react@19.0.0@@@1/
  → link_package_dir()        ← 中間ストアにコピー（遅い）
  → node_modules/.bun/react@19.0.0/node_modules/react/
  → link_path_recursive()     ← ファイル1個ずつ逐次リンク（遅い）
  → node_modules/react/
```

さらに Windows で symlink 失敗 → `cmd /c mklink /J` で **`cmd.exe` を毎回起動**してるのが致命的なのだ 。

### bun がやってること

```
【bun のフロー】
~/.bun/install/cache/react@19.0.0@@@1/
  → os.link() 並列一括   ← 中間層なし、直接 hardlink
  → node_modules/react/
```

***

## 変更内容（ファイル別）

### `linker.v` ← 一番重要

**削除する：**
- `link_path_recursive()` → 並列版に置き換え
- `try_symlink_or_junction()` の `cmd /c mklink /J` 部分 → **完全排除**
- `link_store_dependency()` / `link_hidden_store_dependency()` → 中間ストア不要になる

**追加する：**

```v
fn hardlink_dir_parallel(src_dir string, dest_dir string) ! {
    os.mkdir_all(dest_dir)!
    entries := os.ls(src_dir)!
    mut threads := []thread !{}
    for entry in entries {
        if entry == 'node_modules' { continue }
        src := os.join_path(src_dir, entry)
        dest := os.join_path(dest_dir, entry)
        threads << spawn hardlink_entry(src, dest)
    }
    for t in threads { t.wait()! }
}

fn hardlink_entry(src string, dest string) ! {
    if os.is_dir(src) {
        hardlink_dir_parallel(src, dest)!
        return
    }
    os.mkdir_all(os.dir(dest))!
    os.link(src, dest) or { os.cp(src, dest)! }  // cmd.exe 一切なし
}
```

### `resolve.v` ← 中間ストアを廃止

`install_store_package()` を `install_package_direct()` に置き換え。キャッシュから `node_modules` に**直接 hardlink** するのだ ：

```v
fn install_package_direct(mut ctx InstallContext, cache_dir string, ...) ! {
    // dedup チェック（既存の mutex ロック流用）
    source_dir := package_cache_dir(cache_dir, installed_pkg.pkg)
    dest_dir := os.join_path('node_modules', installed_pkg.pkg.name)

    hardlink_dir_parallel(source_dir, dest_dir)!  // 直 hardlink

    // 依存も並列で再帰
    mut threads := []thread !{}
    for dep_name, _ in installed_pkg.pkg.dependencies {
        threads << spawn install_package_direct(mut ctx, ...)
    }
    for t in threads { t.wait()! }
}
```

### `store.v` ← 不要な関数を削除

| 関数 | 対応 |
|---|---|
| `store_package_root()` | 削除 |
| `store_node_modules_dir()` | 削除 |
| `store_package_target()` | 削除 |
| `hidden_store_node_modules_dir()` | 削除 |
| `store_key_for()` / `fnv1a64()` | **残す**（dedup 用） |
| `relative_path()` | **残す**（`.bin/` symlink 用） |
| `bun_cache_folder_name()` | **残す**（キャッシュ互換） |

### `main.v` ← 2フェーズに単純化

streaming `ready_chan` を廃止してシンプルな2段階に ：

```
Phase 1: prefetch_all()     ← 並列ダウンロード＋展開（既存流用）
Phase 2: hardlink_all()     ← 並列直 hardlink
```

### `cache.v` ← ほぼ触らない ✅

`extract_tgz_native()` の parallel I/O は**そのまま**。`_streaming` 系のバリアントだけ削除なのだ。

***

## 触らないもの

| | 理由 |
|---|---|
| キャッシュ形式（`@@@1`） | bun 互換必須 |
| `bun_cache_dir()` | `~/.bun/install/cache` 固定 |
| `registry.v` | 解決ロジック正常 |
| `extract_tgz_native()` | 既に最適 |

***

## 期待効果

| 変更 | warm 削減 | cold 削減 |
|---|---|---|
| 中間ストア層の廃止 | -400ms | -100ms |
| `hardlink_dir_parallel` 並列化 | -400ms | -200ms |
| `cmd.exe` 起動排除 (Windows) | -200ms | -200ms |
| main ループ簡略化 | -50ms | -50ms |
| **合計** | **~-1050ms** | **~-550ms** |

- warm: 1216 - 1050 ≈ **166ms**（bun 389ms 撃破 ✅）
- cold: 2307 - 550 ≈ **1757ms**（pnpm 超えはネットワーク最適化が追加で必要）

***

## 実装順序

1. `linker.v` — `hardlink_dir_parallel` 追加、`cmd.exe` 排除
2. `resolve.v` — `install_package_direct` に置き換え
3. `store.v` — 不要関数削除
4. `main.v` — 2フェーズ化
5. `cache.v` — streaming 系削除

# muse-space-async-jobs

Meta のパーソナル AI エージェント **Muse** の「スペース」（fullstack web artifact）に、
**非同期ジョブキューを持たせるための再利用可能な設計パターンとスキル** です。

> An async job queue pattern for Muse Spaces: the Space's own DB as the source of
> truth, a JSONL signal file as the trigger, a polling hook as the dispatcher, and
> an agent worker that claims jobs with compare-and-swap transitions.

## 問題：スペースには非同期ジョブの仕組みがない

スペースは「Web アプリ＋自前 DB＋同期アクション」でできていて、次のものが標準では存在しません。

- 裏で動き続けるワーカー
- DB の変化をエージェントに知らせるイベント
- ジョブキュー

そのため「スペースで注文を受けたら、エージェントが裏で制作して納品する」のような
処理は、そのままでは作れません。このリポジトリのパターンは、既存の部品
（ファイル書き込み・監視フック・cron・スペースのアクション）だけでそれを実現します。

## アーキテクチャ

```
[Producer = スペース]
   │ ① DB にジョブ登録（status=queued）※ここが正本
   │ ② 信号ファイルに 1 行追記 {"event_id": UUID, "job_id": ..., "event": "queued"}
   ▼
~/hooks/state/<producer>-signal.jsonl        ← 信号は「ヒント」にすぎない
   │ ③ 監視フック（bash・30〜60 秒ポーリング）が新着 event_id を検知して wake
   ▼
[Worker = エージェント]
   │ ④ アクション経由で正本を総確認（信号の ID に頼らない）
   │ ⑤ claim（条件付き遷移＋トークン）→ 処理 → complete → 納品
   ▼
[Reconciler = 低頻度 cron]（ティア A のみ）
      詰まった queued の回収、放置された claimed の報告
```

登場人物：Producer / Job Store（正本）/ Signal Log / Dispatcher / Worker /
Reconciler / Delivery。

## 中核原則（4つ）

1. **信号はヒント、正本は DB** — 信号を信用しない。壊れても消えても実害がない形にする。
2. **claim がロック、token が持ち主確認** — すべての状態遷移を CAS
   （期待状態と一致したときだけ書く）で行い、claimed 以降は `claimed_by`
   トークンの一致を必須とする。
3. **at-least-once 前提** — 二度起きることを防ぐのではなく、二度起きても壊れないように作る。
4. **自動リトライしない** — 失敗は failed で止めて人間が見える形にする。再投入は明示操作だけ。

この原則が机上でないことは、参照実装の運用初日に踏んだ実事故で検証されています：
検証用サンドボックス DB のジョブ ID が本番の信号ファイルの seen 記録を汚染し、
本物のジョブの信号が握り潰されかけましたが、ワーカーの「正本総確認」が最終防衛線として
機能して実害ゼロで復旧できました。この事故から、冪等キーをジョブ ID から
イベントごとの UUID（`event_id`）に分離する設計が生まれています。

## 状態機械（標準形）

```
        ┌─ cancelled（draft / queued からのみ、CAS）
draft ─→ queued ─→ claimed ─→ done
（任意）              └─────→ failed ─→ queued（手動 requeue のみ）
```

ドメイン側の表示名は英語標準キーへの対応表で写像します。

## 使い方（Muse への導入）

このリポジトリの中身を、自分の Muse のカスタムスキルとして配置します。

```
~/workspace/custom-skills/space_async_jobs/
├── SKILL.md
├── skill.yaml
└── templates/
    ├── action-contract.md        # CAS アクション契約と emit 雛形
    ├── hook-script.sh            # フックスクリプト雛形
    ├── worker-prompt.md          # ワーカー指示文雛形
    ├── reconciler-prompt.md      # Reconciler 指示文雛形
    └── verification-checklist.md # 上線前チェック＋実測テスト＋復旧ランブック
```

配置すれば、Muse がスキル検索でこのパターンを引けるようになります。
あとは「スペースに非同期ジョブを付けたい」と頼むときに、スキルに沿って
正本の設計・信号・フック・ワーカーが組み上がります。

## 適用すべきでないケース

- 同期アクションで数秒で終わる処理
- 数秒オーダーの遅延要求（ポーリングでは原理的に無理）
- スペースの外へのファイル書き込みが実測で通らなかったスペース
- 支払い・投稿など外部副作用の exactly-once が要るもの
  （本方式の保証は at-least-once 配送＋claim による実質 1 回処理まで）
- 高頻度・大量のジョブ（信号ファイルの全走査が先に限界に来る）

## ステータスと既知の制限

- 参照実装（注文フォームのスペース＋音声制作ワーカー）で E2E 疎通済みの運用パターンです。
- 参照実装側のステータス更新は現状まだ無条件更新で、CAS 契約への移行は今後の課題です
  （スキル側は契約を「あるべき形」として規定しています）。
- チェックリスト内の実測テスト 3 件（claim 原子性の並行テスト、フックの wake 多重性、
  sandbox / 本番の環境差分）は手順として codify 済みで、環境ごとの実施を推奨します。

## ライセンス

MIT License. See [LICENSE](LICENSE).

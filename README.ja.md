<p align="center"><sub><a href="README.md">English</a> · <a href="README.zh-CN.md">简体中文</a> · <b>日本語</b> · <a href="README.ru.md">Русский</a></sub></p>

<!-- translation of README.md, source sha256: cd214fcd1c0e -->

<p align="center"><sub>これは英語版 README の翻訳です。内容が異なる場合は英語版が正しいものとします。誤りに気づいたら <a href="https://github.com/mountain-beaver/vps-forge/issues">issue</a> でお知らせください。</sub></p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/banner-dark.svg">
    <img alt="vps-forge：AI エージェントがサーバーをハードニングし、鍵はあなたの手元に残ります。すべての変更は arm、変更、新しいログイン、コミットの順に進み、そうならなければ 5:00 にロールバックされます。完成したサーバー：SSH は鍵認証のみ、ファイアウォールは 22、80、443 のみ開放、fail2ban 有効、リストアを検証済みのバックアップ、スマートフォンへのアラート。" src="docs/assets/banner-light.svg" width="100%">
  </picture>
</p>

<p align="center">
  <b>AI コーディングエージェントにサーバーの構築を頼めば、本番環境を任せられるサーバーが手に入ります。</b><br>
  Debian と Ubuntu の VPS の構築、ハードニング、監査のためのオープンな <a href="https://agentskills.io">Agent Skill</a> です。<br>
  Claude Code、Codex、Cursor、GitHub Copilot、Gemini CLI、OpenCode など、スキルを読み込めるエージェントで動作します。
</p>

<p align="center">
  <a href="https://github.com/mountain-beaver/vps-forge/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/mountain-beaver/vps-forge?color=0B7A55&style=flat-square"></a>
  <a href="https://github.com/mountain-beaver/vps-forge/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/mountain-beaver/vps-forge/actions/workflows/ci.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-59616B?style=flat-square"></a>
  <a href="https://agentskills.io"><img alt="Agent Skills standard" src="https://img.shields.io/badge/Agent%20Skills-SKILL.md-121417?style=flat-square"></a>
  <img alt="Debian 12 and 13, Ubuntu 22.04, 24.04 and 26.04" src="https://img.shields.io/badge/Debian%2012%20%7C%2013-Ubuntu%2022.04%20%7C%2024.04%20%7C%2026.04-59616B?style=flat-square">
</p>

<p align="center">
  <a href="#クイックスタート">クイックスタート</a> ·
  <a href="#依頼の例と結果">使用例</a> ·
  <a href="#危険な変更はすべて自動で元に戻ります">5 分後の自動ロールバック</a> ·
  <a href="#ベンチマーク">ベンチマーク</a> ·
  <a href="#faq">FAQ</a>
</p>

VPS を借りれば、エージェントはもう SSH で入ってアプリを動かすところまではできます。ただ、たいてい抜け落ちるのは、後になって初めて気づく部分です。スキャンで不合格になる SSH の暗号設定、一度も有効化されていないファイアウォール、誰も BAN しない fail2ban、誰かがログインしても届かないアラート。あるいは、自分のログインを熱心に試しすぎて、あなたの IP を BAN させてしまうこともあります。

vps-forge は、この仕事全体を正しい順序で、危険な手順にはすべて安全網を張ったうえで進める方法をエージェントに教えます。サーバーは堅牢化され、バックアップされ、監視され、ドキュメント化された状態になります。そして SSH、ファイアウォール、sudo、PAM への変更はどれも、あなたがまだログインできることを確認できなければ自動でロールバックされます。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/bench/chart-hero-dark.svg">
    <img alt="完成したサーバーのチェックリストスコア（100 点満点）。外部からのチェックに合格した割合で、シナリオごとに 15 回の実行の平均。本番の Docker サーバー：スキルなし 79、スキルあり 99。新規 VPS から本番環境へ：88 対 100。SSH ポートの変更：88 対 100。これはベンチマーク時のスキルによるもので、この限定的な依頼にもベースライン全体を適用していました。1.1.0 以降は依頼されたことだけを行いますが、その再計測はしていません。sudo ユーザーのある新規 VPS：92 対 100。" src="docs/bench/chart-hero-light.svg" width="880">
  </picture>
</p>

<p align="center"><sub>実際の VM 上で Claude Opus 5.5 を 120 回実行し、スキルと同じ作者が書いたジャッジ（採点プログラム）でサーバーの外側から採点しました。差の約 70% は、スキル自身のデフォルトと一致する 3 つのチェックによるものです。<a href="#ベンチマーク">計測方法とその限界</a>。</sub></p>

## 動作の様子

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/replay-dark.svg">
    <img alt="新規の Debian 13 VPS で実際に行ったベンチマーク実行のリプレイ。ユーザーは日次バックアップとスマートフォンへのアラート付きで Docker アプリ用の本番サーバーを依頼し、自分はオフラインだと伝えます。続いてエージェント自身の進捗メッセージが並びます。事前調査と初期監査（100 点中 78 点）、安全網、新しい接続から検証した SSH のハードニング、ファイアウォール、fail2ban、Docker のポート確認、リストアを検証したバックアップ、スマートフォンへのアラート、そして最終監査で 100 点中 100 点。" src="docs/assets/replay-light.svg" width="880">
  </picture>
</p>

## クイックスタート

**1. スキルをインストールします**。使っているエージェントに合わせて選んでください。ほとんどのエージェントは次の 1 コマンドで対応できます。

```bash
npx skills add mountain-beaver/vps-forge -g
```

どのエージェント向けにインストールするかを尋ねられます。`-g` を付けるとユーザー単位でインストールされ、どのフォルダーでもエージェントがスキルを見つけられます。付けなければ現在のプロジェクトだけにインストールされます。このコマンドはオープンな [`skills`](https://github.com/vercel-labs/skills) インストーラーのもので、Node.js 22.20 以降が必要です。Node がない場合は、下の GitHub CLI か zip を使ってください。インストールできたかは、エージェントに「どんなスキルがある？」と聞いて、`vps-forge` があるかで確認できます。そして作業中は、ひとつのサインに注目してください。エージェントは SSH やファイアウォールを変更する前に、必ず `vps-forge-deadman arm` を実行します。arm せずにどちらかを変更したら、スキルが読み込まれていないので止めてください（[FAQ](#faq)）。

**2. サーバーについてエージェントに話しかけます**。特別な言い回しは要りません。

> 203.0.113.10 の VPS を買ったばかりで、root でログインしています。app.example.com で動かす Docker アプリ用に、バックアップとスマホへのアラート付きで、ちゃんとした本番サーバーにしてください。

エージェントはスキルを読み込み、短い質問を最大 4 つ行い、計画を示してから、フェーズごとに作業を進めます。ログインにはあなた自身の SSH 鍵を使い、エージェント専用の鍵は持ちません。その鍵だけを登録した管理ユーザーを作成し、新しいログインが成功したことを確認してから root ログインを無効にします。

> [!IMPORTANT]
> **大切なサーバーで使う前に**：プロバイダーのスナップショットを取り、プロバイダーの Web コンソール（VNC またはシリアル）の場所を確認しておいてください。エージェントは最初の危険な手順の前に、あなたがコンソールの場所を把握しているかを確認します。変更によって SSH が切断された場合は、[デッドマンスイッチ](#危険な変更はすべて自動で元に戻ります)（一定時間内に解除されなければ変更を自動で元に戻す仕組み）がタイマー（デフォルトは 5 分、長い変更では 10 分）で変更をロールバックし、それ以外はコンソールで対処できます。初めてなら、使い捨てのサーバーで試してください。

<details>
<summary><b>Claude Code</b>：プラグインとしてインストール</summary>

```bash
claude plugin marketplace add mountain-beaver/vps-forge
claude plugin install vps-forge@vps-forge
```

セッション内では `/plugin marketplace add mountain-beaver/vps-forge` で同じことができ、そのあと `/plugin` で選択します。後で更新するには `claude plugin update vps-forge@vps-forge` を実行します。
</details>

<details>
<summary><b>Codex, Cursor, GitHub Copilot, Gemini CLI, Antigravity, OpenCode, Windsurf, Cline, Amp, Roo</b>：エージェントごとにインストール</summary>

インストーラーにエージェントを指定し、ユーザー全体にインストールするなら `-g` も付けます。

```bash
npx skills add mountain-beaver/vps-forge -g -a codex
```

| エージェント | `-a` の値 |
|---|---|
| Codex | `codex` |
| Cursor | `cursor` |
| GitHub Copilot | `github-copilot` |
| Gemini CLI | `gemini-cli` |
| Antigravity | `antigravity` |
| OpenCode | `opencode` |
| Windsurf | `windsurf` |
| Cline | `cline` |
| Amp | `amp` |
| Roo Code | `roo` |

約 80 のエージェントの全一覧は、インストーラーの [エージェント一覧表](https://github.com/vercel-labs/skills/blob/main/docs/agents.md) にあります。
</details>

<details>
<summary><b>GitHub CLI</b>：<code>gh skill install</code></summary>

```bash
gh skill install mountain-beaver/vps-forge vps-forge --agent cursor --scope user
```

`--agent` には `claude-code`、`codex`、`cursor`、`github-copilot`、`gemini-cli`、`opencode` などの名前を指定します。すべての名前は `gh skill install --help` で確認できます。リリースを固定するには `--pin v1.0.0` を使います。
</details>

<details>
<summary><b>Claude.ai と Claude Desktop</b>：zip をアップロード</summary>

[最新リリース](https://github.com/mountain-beaver/vps-forge/releases/latest) から `vps-forge-skill.zip` をダウンロードし、Settings → Capabilities → Skills → "Upload skill" からアップロードします。コード実行を有効にしておく必要があります。

チャットアプリはサーバーに SSH 接続できないため、そこではスキルは **スクリプトモード** で動作します。まず読み取り専用の監査が渡されるので、それを実行して結果を貼り付けます。その後、段階ごとに短いスクリプトが 1 つずつ渡されます。SSH やファイアウォールを変更する前には、スクリプトがいったん止まり、2 つ目のターミナルからログインするよう求めます。そのログインに失敗すれば、サーバーが自分でその手順を元に戻します。すべてを自分で実行するので、エージェントが知っているのはあなたが貼り付けた内容だけです。また、外部からのチェックには Mac、Linux、WSL のいずれかのターミナルが必要です。
</details>

<details>
<summary><b>その他のエージェント</b>：フォルダーをコピー</summary>

```bash
git clone https://github.com/mountain-beaver/vps-forge
mkdir -p ~/.agents/skills && cp -r vps-forge/skills/vps-forge ~/.agents/skills/   # またはエージェントのスキルフォルダー
```

エージェントがスキルにまったく対応していない場合は、`skills/vps-forge/SKILL.md` を読んでそれに従うよう指示してください。スキルはただの Markdown と bash です。
</details>

## 依頼の例と結果

| 依頼すること | エージェントが行うこと |
|---|---|
| 「この新しい VPS に Docker アプリを載せて。HTTPS 付きで」 | あなたの鍵を登録した管理ユーザー、root とパスワードログインの無効化、22/80/443 だけを開けたファイアウォール、TLS 付きの Caddy、検証済みのバックアップ、アラート。 |
| 「サーバーを監査して。何も変更しないで」 | 重大度順に並べた読み取り専用のレポートと、改善計画。 |
| 「SSH を 2222 に移して fail2ban を入れて。それ以外は何もしないで」 | 依頼どおりのことだけを安全に行い、残りの作業は一行で提案します。 |
| 「アラートをスマホに送って」 | ログイン、失敗、ディスクの容量不足、バックアップについて、ntfy、Telegram、Webhook でアラートを送ります。 |
| 「SSH は Tailscale 経由だけにして」 | VPN 経由のログインが成功してから、公開 SSH を閉じます。 |
| 「サーバーがハッキングされていない？」 | 侵害の有無をチェックします。兆候が見つかれば作業を止め、再構築を案内します。 |
| 「この VPS を Coolify 用に準備して」 | 同じハードニングを行いますが、root にはパネル用に鍵ログインを残し、80/443 はパネルのプロキシに任せ、ダッシュボードのポートはドメインで動作を確認できたら閉じます。Dokploy、CapRover、Kamal、Dokku にも対応します。 |

## 完成したサーバーの状態

| 領域 | 完成したサーバーでは |
|---|---|
| **アクセス** | あなたの鍵だけを登録した管理ユーザー。root ログインとパスワードログインは無効で、`AllowGroups` も設定済みです。SSH の暗号設定はモダンかつバージョンに応じたものなので、`ssh-audit` に合格します。 |
| **ファイアウォール** | ufw または nftables で、デフォルト拒否、IPv4 と IPv6 で同じルール。Docker が公開するポートもカバーし、あなた自身の IP は常に最初に通します。 |
| **侵入対策** | systemd バックエンドと recidive jail を使う fail2ban。起動する前に、あなたの IP を除外リストに入れておきます。paranoid レベルでは CrowdSec。 |
| **アップデート** | 無人セキュリティアップデート。スキルが追加するベンダーリポジトリ（Caddy、Tailscale、CrowdSec、同意すれば Docker）も対象です。needrestart と、任意の再起動ウィンドウ。 |
| **Web とアプリ** | localhost にバインドした Docker、TLS とセキュリティヘッダー付きの Caddy または nginx、データベースとワーカー用のプロファイル。 |
| **バックアップ** | 別のボリュームまたはオブジェクトストレージへの restic バックアップをタイマーで実行し、合格が必須のリストアテスト付き。Postgres、MySQL、SQLite は先にダンプし、稼働中のままコピーすることはありません。 |
| **アラート** | SSH ログインと異常時にスマートフォンへアラート。重複排除とハートビート付き。 |
| **日々の運用** | 状態を表示する motd、etckeeper で git 管理された `/etc`、開いているすべてのポートを説明する `SERVER.md`。cloud-init のエクスポートを使えば、次のサーバーをまったく同じ構成で作れます。 |

<details>
<summary>レベルとプロファイル</summary>

| | **baseline** | **hardened**（デフォルト） | **paranoid** |
|---|---|---|---|
| SSH | 鍵認証のみ、root 不可、`AllowGroups` | + モダンな KEX と暗号（利用可能なら耐量子）、ed25519 ホスト鍵、`ssh-audit` で問題なし | + FIDO2 または TOTP、SSH は VPN 経由のみ |
| ファイアウォール | デフォルト拒否 | + IPv6 も同等に、Docker 用ルール、プロバイダーのファイアウォール | + Web は Cloudflare 経由のみ、送信通信の見直し |
| 侵入対策 | fail2ban | + recidive | CrowdSec |
| アップデート | 無人セキュリティアップデート | + needrestart、Livepatch | + 再起動ウィンドウ |
| バックアップ | restic と検証済みのリストア | + 削除に強いリポジトリ、週次チェック | + 2 つ目のオフサイトリポジトリ |
| アラート | 死活監視 | + スマートフォンへのアラート、ハートビート | + ダイジェスト |

プロファイルはどのレベルとも組み合わせられます：`web`、`docker`、`vpn`、`db`、`worker`、`game`。
</details>

## 危険な変更はすべて自動で元に戻ります

`sshd` やファイアウォールの変更を 1 つ間違えるだけで、サーバーに到達できなくなることがあります。そこで、SSH、ファイアウォール、sudo、PAM への変更はすべて **デッドマンスイッチ** の中で実行します。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/deadman-diagram-dark.svg">
    <img alt="デッドマンスイッチの図。アーム：設定のスナップショットを取り、5 分のタイマーを開始。変更：sshd、ファイアウォール、sudo、PAM を編集。検証：まったく新しい接続で再ログイン。解除：ログインに成功すればタイマーを止め、変更を確定。ログインが拒否されると誰も解除できず、5:00 にすべての変更がスナップショットから元に戻されます。再起動後も同様です。" src="docs/assets/deadman-diagram-light.svg" width="880">
  </picture>
</p>

1. `deadman.sh arm` が設定のスナップショットを取り、5 分の systemd タイマーを開始します。
2. エージェントが変更を加え、検証します（`sshd -t`、`visudo -c`、`nft -c`）。
3. 古い接続を再利用できない **新しい** 接続で、もう一度ログインします。
4. そのログインが成功した場合にのみ、タイマーを解除します。

新しいログインに失敗しても、ほかに何かをする必要はありません。タイマーがスナップショットを復元し、fail2ban によるあなたの BAN を解除し、サービスを元の状態に戻します。スイッチがアームされた状態でサーバーが再起動した場合も、起動時に同じ処理を行います。

サーバーの外にあるものは元に戻せません。プロバイダーのパネルで設定するファイアウォール（Hetzner、DigitalOcean、AWS のセキュリティグループ）や、プロバイダー側のネットワーク変更がそれにあたります。こうした変更では、エージェントはまず新しいルールを追加し、新しいログインが成功することを確かめてから古いルールを削除します。そのため、ミスがあっても余分なルールが開いたままになるだけで、締め出されることはありません。ロールバックはすべて `vps-forge-deadman` としてジャーナルに記録され、スマートフォンへのアラートを設定済みなら、優先度の高い「Deadman fired」のプッシュ通知も送られます。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/assets/deadman-dark.svg">
    <img alt="デッドマンスイッチの動作を記録したもの。管理者がスイッチを 1 分でアームし、自分自身を締め出す sshd のルールを追加しますが、sshd -t は通ります。新しい SSH ログインは拒否されるため、誰も解除しません。タイマーが切れると状態が ROLLED BACK と表示され、次のログインは再び成功します。" src="docs/assets/deadman.svg" width="880">
  </picture>
</p>

**信用できませんか？ それなら壊してみてください**。スイッチはただの bash スクリプトなので、エージェントなしで試せます。使い捨てのサーバーに sudo 権限のあるユーザーでログインし、このセッションを開いたまま次を実行します。

```bash
curl -fsSLO https://raw.githubusercontent.com/mountain-beaver/vps-forge/v1.1.1/skills/vps-forge/scripts/deadman.sh
less deadman.sh                                                       # root で実行する前に中身を読む
sudo install -m 755 deadman.sh /usr/local/sbin/vps-forge-deadman
sudo vps-forge-deadman arm 1                                          # 1 分後にロールバック
echo 'AllowUsers deploy' | sudo tee /etc/ssh/sshd_config.d/50-users.conf   # あなたは "deploy" ではない
sudo sshd -t && sudo systemctl reload ssh                             # 設定は正しいので適用される
```

これで、手元のマシンからの新しいログイン（`ssh -o ControlPath=none you@server`）は拒否されるため、誰も解除できません。1 分待つと、開いたままのセッションで `sudo vps-forge-deadman status` が `ROLLED BACK` と表示し、`50-users.conf` は消え、新しいログインも再び成功します。実際の運用では、危険な変更の前に `arm` を実行し、新しいログインが成功したら `disarm` を実行します。予備のサーバーがなければ、`make deadman-systemd` で、これに加えて壊れたファイアウォール、アーム中の再起動、ufw と fail2ban のケースを podman コンテナ内で試せます。

これは設計上の保証であり、ベンチマークで証明できるものではありません。Opus はもともと慎重なので、どちらの条件でも締め出しは起きませんでした。ベンチマークが実際に計測したのはニアミスです。スキルなしでは、エージェントは作業中に 60 回中 7 回、自分の管理者 IP を fail2ban に BAN させてしまいました。スキルありでは 60 回中 0 回でした。

このスキルが守るほかのルール：
- **書き込む前に読む**。稼働中のサーバーではまず監査を行い、あなたが承認するまで何も変更しません。
- **シークレットはチャットを通さない**。パスワードやトークンはサーバー上で生成してモード 600 で保存し、引数ではなく標準入力でツールに渡します。
- **バージョンは推測せず確認する**。OpenSSH のアルゴリズム、Ubuntu 24.04 のソケットアクティベーションによる SSH、fail2ban のバックエンドは、どれもリリースごとに異なります。
- **既知の落とし穴に対処済み**。たとえば次のようなものです。
  - cloud-init の `50-cloud-init.conf` は、`99-` のドロップインがあっても黙ってパスワードを再び有効にします。sshd は最初に読んだ値を採用するからです。
  - Debian 12 以降には `auth.log` がないため、fail2ban がログを見つけられません。
  - Docker は ufw を素通りしてポートを公開します。

## ベンチマーク

テストの内容：Claude Opus 5.5 に、同じサーバーで同じタスクを 2 回与えます。1 回は単体で、もう 1 回は vps-forge ありで実行します。
- **サーバー**：Debian 12/13 と Ubuntu 22.04/24.04/26.04 の公式クラウドイメージから構築した、実際の QEMU VM。
- **繰り返し**：各セルを 3 回実行。
- **ユーザーは応答できない**：プロンプトで、ユーザーはオフラインで質問に答えられないと伝えます。

そのうえで、別のジャッジが各サーバーを外部から、再起動の前と後にチェックします。ジャッジはスキル自身のスクリプトを一切使いません。チェック項目は次のとおりです。
- ユーザーの鍵でログインできるか
- sshd が提示する認証方式、root がログインできるか、`ssh-audit` の結果
- どのポートが応答するか
- ブルートフォースの送信元が本当に BAN されるか
- バックアップからアプリのデータを復元できるか
- アラートが届くか

締め出された場合は 0 点です。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/bench/chart-checks-dark.svg">
  <img alt="条件間で結果が異なる外部チェックをすべて示した図。1 回の実行を 1 マスで表し、スキルなしとスキルありを比較。スキル自身のデフォルト：ssh-audit で問題なし 4/60 対 60/60、新しい SSH ログインのアラート 16/30 対 30/30、root ログイン無効 30/60 対 57/60。それ以外：ホストファイアウォール有効 46/60 対 60/60、攻撃者が BAN される 50/60 対 60/60、ブルートフォース対策が有効 52/60 対 60/60。起きてはならないこと：エージェントが自分の IP を BAN 7/60 対 0/60、締め出しは両方とも 0/60。ほかの 18 チェックはすべての実行で合格したため省略。" src="docs/bench/chart-checks-light.svg" width="880">
</picture>

| | スキルなし | vps-forge あり |
|---|---:|---:|
| `ssh-audit` で失敗なし | 4 / 60 | **60 / 60** |
| 新しい SSH ログインでアラート | 16 / 30 | **30 / 30** |
| ホストファイアウォールが有効 | 46 / 60 | **60 / 60** |
| ブルートフォースの送信元が実際に BAN される | 50 / 60 | **60 / 60** |
| root が SSH でログインできない | 30 / 60 | **57 / 60** |
| アプリのデータを復元できるバックアップ | 30 / 30 | 30 / 30 |
| エージェントの作業中に管理者自身の IP が BAN された | 7 / 60 | **0 / 60** |
| 管理者が締め出された | 0 / 60 | 0 / 60 |

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/bench/chart-grid-dark.svg">
  <img alt="ディストリビューションとシナリオごとの平均スコア（スキルなしとスキルあり）と、3 回それぞれの結果。スキルなしでは各セルが 78〜95。スキルありではすべてのセルが 100 で、例外は Ubuntu 22.04（95）と Ubuntu 24.04（98）の本番 Docker サーバーのみ。" src="docs/bench/chart-grid-light.svg" width="880">
</picture>

**効果がない部分と、注意すべき点**
- **Opus は単体でも十分優秀です**。スキルなしでも 79〜92 点で、手を加える前のサーバーの 25〜42 点から大きく上がります。スキルが埋めるのは最後の 8〜20 点で、それは後になって問題になる部分です。`ssh-audit` に合格する SSH の暗号設定、誰かがログインしたときのアラート、本当に有効になっているファイアウォール、本当に BAN する fail2ban。
- **一般的な監査スコアはほとんど変わりません**。Lynis のスコアはスキルの有無でほぼ同じです：69 対 71、72 対 72、64 対 72、73 対 72。差が出るのは上のチェック項目であって、汎用的なハードニング指標ではありません。
- **バックアップ**。Opus は単体でも、頼まれれば動作するバックアップを作ります。両条件のすべての実行で、アプリのデータを復元できました。
- **差の大部分はスキル自身のデフォルトによるものです**。3 つのチェックは、スキルがどのみち行う選択をそのまま反映しています。`ssh-audit` で問題がないこと、root でログインできないこと、SSH ログインのたびにアラートが出ることです。これらを除くと、新規 VPS の 2 シナリオは 100 対 100 と 100 対 100、本番サーバーは 91 対 100、SSH ポートの変更は 93 対 100 になります。これが差の約 70% にあたります。
- **そのデフォルト以外に残る差**：既存の本番サーバーで攻撃者を実際に BAN する fail2ban（スキルなしで 15 回中 6 回、スキルありで 15 回中 15 回）、ユーザーが頼んでいないホストファイアウォール、そして自分自身を BAN しないこと（自己 BAN はスキルなしで 60 回中 7 回、スキルありで 60 回中 0 回）。
- **root ログインは判断が分かれます**。ジャッジは、root がまだ鍵でログインできるサーバーを不合格にします。スキルなしの実行がこのチェックで不合格になった 2 つのシナリオでは、プロンプトに「ユーザーは現在 root でログインしている」とあるため、鍵認証のみの root ログインを残すことにも理があります。このチェックだけを除くと、スコアはスキルなしで 85〜93、スキルありで 100 です。
- **質問と承認はテストしていません**。どのプロンプトも、ユーザーはオフラインなのでエージェントが自分で判断するよう伝えているため、スキルのヒアリングの質問と承認の手順は一度も実行されていません。実際のユーザーが使うときは、こちらが通常のモードです。
- **時間もコストも余計にかかります**。実行時間の中央値は 3〜6 分ではなく 5〜8 分でした。スキルがスナップショットを取り、デッドマンスイッチをアームし、すべての変更を新しい接続から検証するためです。API の定価で、1 回の実行コストの中央値はスキルありで $1.87、スキルなしで $0.62 と約 3 倍で、さらにスキルの指示がエージェントのコンテキストに加わります。
- **ベンチマーク時のスキルは、チェックリスト形式の依頼が求める以上のことをしていました**。あるシナリオでは、SSH を 2222 に移す、sudo ユーザーを追加する、パスワードと root のログインを無効にする、fail2ban をインストールする、自動アップデートを有効にする、ということだけを依頼します。スキルなしのスコアは 88 です。Opus は 5 つすべてを行いますが、サーバーは `ssh-audit` に不合格で、ホストファイアウォールもありません。どちらもプロンプトでは触れられていない項目です。ベンチマーク時のスキルはそれでも hardened のベースラインを適用し、100 点を取りました。1.1.0 以降はそうしません。限定的な依頼には、依頼された作業と残りの提案だけを返します。つまり、この 100 点は古い挙動を表したもので、新しい挙動はベンチマークしていません。
- **シナリオは初見ではありません**。以前のバージョンのスキルは、最初の 3 シナリオで 92、100、89 点でした。その 45 回のうち 12 回で、エージェント自身のテストログインが、設定したばかりの fail2ban に引っかかりました。スキルはまさにその失敗を踏まえて改訂されたため、この 3 シナリオはもはやブラインドテストになっていません。4 つ目の、sudo ユーザーだけがある新規 VPS のシナリオは改訂後に追加したもので、こちらも 100 点です。
- **スキルはジャッジがチェックする項目を狙っています**。スキルは `ssh-audit` で問題がない状態を目指しており、ジャッジも `ssh-audit` を実行します。上で汎用的な Lynis の指標を並べて示しているのはそのためです。
- **サンプルは少なく、ジャッジは 1 つだけです**。各ディストリビューションとシナリオは条件ごとに 3 回ずつ実行し、ジャッジはスキルと同じ作者が書いたものです。誰でも検証できるよう、テストハーネスは公開しています。
- **ベンチマークしたモデルは 1 つで、もう 1 つはスポットチェックのみです**。本格的なベンチマークは Claude Opus 5.5 だけです。GLM-5.3 はスポットチェックを行いました。ZCode デスクトップアプリで手動実行し、Debian 13 上の 2 シナリオで条件ごとに 1 回ずつです。スコアは新規 VPS で 79 → 100、本番サーバーで 67 → 100 で、締め出しも自己 BAN もありませんでした。スキルなしでは Opus と同じデフォルトを取りこぼし、本番サーバーでは fail2ban も自動アップデートも設定しませんでした。スキルのデフォルトに当たる 3 つのチェックを除いても、94 対 100、77 対 100 です。4 回の実行は逸話にすぎず、ベンチマークではありません：[チェックごとの結果](docs/bench/glm-5.3.md)。ほかのエージェントやモデルはテストしていません。

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/bench/chart-spot-dark.svg">
  <img alt="Debian 13 での GLM-5.3 のスポットチェックと Claude Opus 5.5 の比較。新規 VPS から本番環境へ：Opus はスキルなしで 84、89、89、スキルありで 3 回とも 100。GLM-5.3 は 79 と 100。本番 Docker サーバー：Opus は 73、80、87、スキルありで 3 回とも 100。GLM-5.3 は 67 と 100。" src="docs/bench/chart-spot-light.svg" width="880">
</picture>

ベンチマークはリリース前のスキルで実行しました。バージョン 1.0.1 で変わったのはテキストだけです。バージョン 1.1.0 では、ベンチマークがほとんど、あるいはまったく評価していない部分の挙動が変わりました。限定的な依頼への対応、一時的な sudo 権限付与の期限、アプリのデータを確認するリストア訓練、Kubernetes ノードとハイパーバイザーホストでの作業中止です。バージョン 1.1.1 で変わったのは README、その画像、パッケージングだけです。それ以降の変更（CHANGELOG の Unreleased に記載されたデプロイパネル、スクリプトモード、控えめになったログインアラート、`extend`）もベンチマークしていません。すべての変更は [CHANGELOG.md](CHANGELOG.md) に記載しています。シナリオ、ハーネス、実行の再現に必要なものはすべて [`bench/`](bench/README.md) にあります。実行ごとの結果は [`docs/bench/results.md`](docs/bench/results.md) と [`results.json`](docs/bench/results.json) にあります。

## FAQ

<details>
<summary><b>AI エージェントにサーバー上で root としてコマンドを実行させても安全ですか？</b></summary>

スキルなしよりスキルありのほうが安全で、それこそがこのスキルの目的です。アクセスを断ちかねない変更は、上で説明したデッドマンスイッチの中で実行されます。設定の変更は etckeeper によって `/etc` の git にコミットされるので、元に戻せます。すでに本番稼働しているサーバーでは、エージェントはまず監査を行い、あなたが承認するまで何も変更しません。それでも、プロバイダーのスナップショットと Web コンソールはすぐ使えるようにしておいてください。
</details>

<details>
<summary><b>エージェントはどの鍵でログインしますか？ root ログインは残りますか？</b></summary>

あなたの鍵です。エージェントは通常あなたのマシン上で動き、あなたと同じ方法で接続するため、エージェント専用の鍵は持ちません。現在 root でログインしているなら、そこから始めて、接続に使っている鍵だけを登録した管理ユーザーを作り、新しい接続からそのログインを確認してから、root ログインとパスワードログインを無効にします。root ログインを残すのは、デプロイツールに必要だとあなたが伝えた場合だけです。

`sudo` でパスワードを求めるかどうかは、あなたが選べます。パスワードなしの sudo のほうが簡単ですが、その場合は鍵を盗まれるだけで root を取られます。パスワードありの sudo では、エージェントは一時的なパスワードなしの権限で作業します。この権限はタイマーにより 4 時間後に、再起動をまたいでも失効し、エージェント自身も一番最後の手順で削除します。エージェントをあなたのマシンではなくクラウドのサンドボックスから実行した場合は、最後にファイアウォール、fail2ban、sshd の許可リストから自分の IP も削除します。何かが残っていれば `audit.sh` が指摘します。
</details>

<details>
<summary><b>固めすぎて、作業の邪魔になりませんか？</b></summary>

どこまで固めるかはあなたが選べます。`baseline` は鍵認証のみ、root 無効、デフォルト拒否のファイアウォール、fail2ban です。デフォルトの `hardened` は、モダンな SSH 暗号、Docker を考慮したファイアウォールルール、アラートを追加します。SSH を VPN の内側に置いたり FIDO2 を追加したりするのは `paranoid` だけです。「SSH を移して fail2ban を入れて」のような限定的な依頼には、そのとおりのことだけを行い、残りは一行で提案します。エージェントは SSH ポートの変更、パスワードログインの無効化、自動再起動の有効化の前に確認を求めます。ただし、自分で判断するよう指示した場合は除きます。`SERVER.md` には、開いているすべてのポートとその理由が記載されます。
</details>

<details>
<summary><b>サーバー管理者ではありませんが、使えますか？</b></summary>

はい、まさにそういう人のためのスキルです。エージェントは変更のたびに、何をなぜ行うのかを一行で説明し、質問すればきちんと答えます。最後にはサーバー上に `SERVER.md` が残ります。そこには、何が動いているか、どのポートがなぜ開いているか、バックアップの保存先と復元方法が書かれています。
</details>

<details>
<summary><b>どのエージェントやモデルで動きますか？</b></summary>

[Agent Skills](https://agentskills.io) を読み込めて、シェルコマンドを実行できるエージェントなら使えます：Claude Code、Codex、Cursor、GitHub Copilot、Gemini CLI、Antigravity、OpenCode、Windsurf、Cline、Amp、Roo Code など。シェルのないチャットアプリではスクリプトモードになります。Claude Opus 5.5 は本格的なベンチマーク済み、ZCode 上の GLM-5.3 は 4 回のスポットチェック済みです。ほかのエージェントでの結果は、ぜひ issue で教えてください。
</details>

<details>
<summary><b>エージェントがスキルを使っていないようです。どうすればいいですか？</b></summary>

SSH やファイアウォールを変更する前に止めてください。スキルがなければデッドマンスイッチもありません。スキルが使われているかは作業の様子でわかります。スキルが読み込まれていれば、エージェントは短い質問をいくつかし、計画を示し、プロバイダーの Web コンソールの場所をあなたが知っているか確認し、SSH やファイアウォールを変更する前に必ず `vps-forge-deadman arm` を実行します。`arm` なしで SSH やファイアウォールを変更したら、それはスキルが読み込まれていない確かなサインです。よくある原因：
- **別のプロジェクトにインストールされている**。`-g` を付けないと、`npx skills add` は現在のフォルダーにしかインストールしません。`-g` を付けて再インストールするか、そのフォルダーでエージェントを起動してください。
- **インストール前にセッションを開始していた**。エージェントはセッション開始時にスキル一覧を読み込むので、新しいセッションを開いてください。
- **Claude Code のプラグイン**：`/plugin` で `vps-forge` がインストールされ、有効になっているか確認してください。
- **Claude.ai と Claude Desktop**：Settings → Capabilities → Skills でスキルをオンにし、コード実行も有効にしておく必要があります。
- **依頼がサーバー作業らしく聞こえなかった**。はっきり伝えてください：「vps-forge スキルを使って 203.0.113.10 をハードニングして」。
</details>

<details>
<summary><b>対応しているサーバーは？</b></summary>

Debian 12 と 13、Ubuntu 22.04、24.04、26.04 で、プロバイダーは問いません：Hetzner、DigitalOcean、Vultr、Linode、OVH、AWS（EC2 と Lightsail）、Oracle Cloud、あるいは机の下のマシンでも構いません。x86 でも ARM でも動きます。Oracle Cloud に組み込まれた `iptables` の reject ルールなど、それぞれの落とし穴も把握しています。エージェントはあなたのマシンから SSH で作業します。RHEL 系のサポートはロードマップにあります。
</details>

<details>
<summary><b>費用はかかりますか？</b></summary>

スキルは無料です。MIT ライセンスで、アカウントも有料プランもありません。ただし、エージェントの使用量は増えます。ベンチマークでは、API の定価で 1 回の実行コストの中央値がスキルありで $1.87、スキルなしで $0.62 でした。エージェントがより多くの作業をし、すべての手順を検証するためです。サブスクリプションプランでは、利用上限の消費が増える形で現れます。
</details>

<details>
<summary><b>それでも締め出されたら？</b></summary>

タイマーを待ってください。アームされたデッドマンスイッチは、デフォルトで 5 分後、長い変更では 10 分後に、自動で変更をロールバックします。いつ実行されるかは、プロバイダーのコンソールから `vps-forge-deadman status` で確認できます。その間にサーバーが再起動した場合は、起動時にロールバックが実行されます。それでも入れない場合は、プロバイダーの Web パネルでファイアウォールを確認してください。そこはスイッチでは元に戻せません。そのうえでプロバイダーの Web コンソール（VNC またはシリアル）を開き、`vps-forge-deadman restore` を実行するか、`/etc` の最後の etckeeper コミットを取り消してください。
</details>

<details>
<summary><b>更新や削除はどうすればいいですか？</b></summary>

**スキルを更新する**：`npx skills update -g vps-forge`（プロジェクト単位でインストールした場合は `-g` なし）、Claude Code プラグインなら `claude plugin update vps-forge@vps-forge`、または `gh skill update vps-forge`、あるいは新しい zip をアップロードします。

**スキルを削除する**：`npx skills remove -g vps-forge`、`claude plugin uninstall vps-forge@vps-forge`、またはフォルダーを削除します。これでサーバー側は何も変わりません。ハードニングはそのまま残り、それが狙いです。

**サーバー上の変更を元に戻す**：すべての変更は `/etc` のコミットになっているので（`sudo git -C /etc log`）、一つずつ確認して取り消せます。スキルが追加したファイルは名前に `vps-forge` を含み、`sudo find /etc /usr/local /var/lib -name '*vps-forge*'` で一覧できます。例外は `/usr/local/bin/vps-notify`、`/etc/restic/`、そして `/etc/pam.d/sshd` 内の `pam_exec` の 1 行です。`install-alerts.sh --uninstall` でアラートをきれいに削除できます。fail2ban、restic、Caddy など、スキルがインストールしたパッケージは `apt purge` で削除できます。SSH とファイアウォールのファイルの削除は、ほかの危険な変更と同じく、デッドマンスイッチの中で行ってください。
</details>

<details>
<summary><b>外部にデータを送信しますか？</b></summary>

いいえ。スキルとそのスクリプトにテレメトリはありません。アラートは、あなたが設定した ntfy のトピック、Telegram のチャット、Webhook にだけ送られます。外部からのスキャンはあなた自身のマシンから実行し、`ssh-audit` はオプトインです。
</details>

<details>
<summary><b>AI エージェントなしでスクリプトだけ使えますか？</b></summary>

はい。`audit.sh` は単体で動く読み取り専用の監査スクリプトです。

```bash
curl -fsSLO https://raw.githubusercontent.com/mountain-beaver/vps-forge/v1.1.1/skills/vps-forge/scripts/audit.sh
less audit.sh          # root で何かを実行する前に中身を読む
sudo bash audit.sh     # 読み取り専用。--json で機械可読な出力
```

`deadman.sh`、`external-check.sh`、`install-alerts.sh` も単体で動きます。どれにも `--help` があります。
</details>

## リポジトリの中身

```
skills/vps-forge/
├── SKILL.md              ワークフロー、安全ルール、レベル、完了の定義
├── references/           フェーズごとに 1 ファイル、必要なときだけ読み込む
├── scripts/
│   ├── audit.sh          読み取り専用の監査：70 以上のチェック、スコア、JSON
│   ├── deadman.sh        SSH、ファイアウォール、sudo、PAM のスナップショットと自動ロールバック
│   ├── external-check.sh 手元のマシンからの外部チェック：ポート、SSH 認証、TLS、ssh-audit
│   └── install-alerts.sh vps-notify：ntfy、Telegram、Webhook によるアラート
├── assets/               検証済みテンプレート：sshd、sysctl、fail2ban、apt、Docker、Caddy、
│                         restic、Cloudflare 同期、motd、SERVER.md、cloud-init
└── evals/                挙動のテストケース
```

すべてのテンプレートは、それを読み込むツール自身によって CI でチェックしています（`sshd -t`、`fail2ban-client -t`、`caddy validate`、`cloud-init schema`、`systemd-analyze verify`、`dockerd --validate`）。対象は Debian 12/13 と Ubuntu 22.04/24.04/26.04 です。`audit.sh` は既知の良いサーバーと悪いサーバーに対してテストし、何も変更しないことをチェックサムで証明しています。デッドマンスイッチのロールバックは、CI 上の実際の systemd でテストしています。アームし、SSH かファイアウォールを壊し、待ってから、すべてが元に戻ったことを確認します。再起動をまたぐケースも含みます。

## コントリビュート

issue やプルリクエストを歓迎します。特に、ディストリビューションごとのエッジケース、プロバイダー固有の癖、ほかのエージェントでのベンチマーク結果は大歓迎です。セットアップ方法は [CONTRIBUTING.md](CONTRIBUTING.md) にあります。`make test` は root なしで数秒で終わり、`make ci` はすべてのコンテナスイートを実行します。スキルが誰かを締め出したり、サーバーを弱くしたりする可能性を見つけたら、[SECURITY.md](SECURITY.md) の手順に従って非公開で報告してください。

vps-forge のおかげで一晩の作業やサーバーが救われたなら、スターを付けてもらえると、ほかの人がこのプロジェクトを見つけやすくなります。

## ライセンス

[MIT](LICENSE)。このスキルは root としてサーバーに変更を加えます。慎重に動くよう作られていますが、システムの責任はあなたにあります。スナップショットとコンソールへのアクセスを確保し、スキルが実行する内容を読んでください。

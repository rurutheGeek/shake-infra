# 3. 監視基盤の構築とDiscordアラート連携手順

## 監視基盤の導入理由
サーバーを運用していく中で、CPU使用率の高騰、メモリ不足、ストレージ枯渇、あるいはサービスダウンなどの異常を早期に検知することは極めて重要である。
各サーバーにExporterと呼ばれるエージェントを配置し、Prometheusで定期的にメトリクス（稼働データ）を収集し、Grafanaで美しく可視化することで、「システムの健康状態をリアルタイムで把握」「障害発生時の迅速な原因究明（トラブルシューティング）」「将来的なリソース拡張の計画立案」が容易になる。

本フェーズでは、Raspberry Pi 3台（shakeserver, tarakoserver, negitoroserver）を用いた監視基盤の構築と、既存サービスからの移行、および高可用性のための自動フェイルオーバー機構の構築を行う。

### この章で追加・変更されるディレクトリ構成
※末尾に * が付いているものは、この章で新しく追加・変更されるディレクトリ・ファイルです。
```text
iac-workspace
├── ansible
│   ├── files
│   │   └── monitoring *
│   │       ├── alertmanager.yml *
│   │       ├── failover_webhook.py *
│   │       ├── monitoring-compose.yml *
│   │       ├── prometheus.yml *
│   │       └── prometheus_rules.yml *
│   ├── playbooks
│   │   ├── create_ansible_user.yml
│   │   └── install_tailscale.yml
│   ├── roles
│   │   ├── common
│   │   │   └── tasks
│   │   │       └── main.yml
│   │   ├── exporters *
│   │   │   └── tasks *
│   │   │       └── main.yml *
│   │   ├── monitoring *
│   │   │   ├── handlers *
│   │   │   ├── tasks *
│   │   │   │   └── main.yml *
│   │   │   └── templates *
│   │   │       └── failover-webhook.service.j2 *
│   │   └── ups_exporter *
│   │       ├── handlers *
│   │       └── tasks *
│   │           └── main.yml *
│   ├── site.yml
│   └── templates
├── local_config
│   ├── ansible
│   │   └── credentials
│   └── terraform
├── toggle_maintenance.sh *
└── terraform
    ├── main.tf *
    └── worker_scripts *
        ├── failover_worker.js *
        └── maintenance.html *
```

### 利用可能になるコマンド・サービス
- Grafanaダッシュボード: http://100.X.X.3:3000 (初期ID/Pass: admin/admin) にアクセスし、各サーバーのリソース状況やUPSのステータス、コンテナ稼働状況を確認できる。
- Prometheusターゲット状態: http://100.X.X.3:9090/targets で監視エージェントの死活状態を確認できる。
- 手動フェイルオーバーコマンド: ルートディレクトリで [toggle_maintenance.sh](../toggle_maintenance.sh) on (または off) を実行することで、Cloudflare Workersを用いたメンテナンス画面への切り替えとDiscord通知を即座に行える。
- 自動フェイルオーバー: 障害発生時に自動で上記のメンテナンス画面切り替えが行われ、復旧時に自動で解除される。



### UPS監視の構成詳細
- 使用機器: Raspberry Pi 5, Geekworm X120X UPSボード
- データ取得方式:
    - バッテリー電圧および容量: I2Cバス（アドレス 0x36）のレジスタから読み取り。
    - 外部電源（AC）ステータス: GPIO（ピン 6）の押下状態（PLD）から電源喪失を検知。
- 技術構成: prometheus_client, smbus2, rpi-lgpio（Pi 5対応GPIOバックエンド）を使用するPythonスクリプト。高速なPythonパッケージマネージャである uv を用いて専用の仮想環境を構築する。
- 権限とエラー対策: スクリプトをルート権限なしで実行するため、実行ユーザー（ansible_admin）を i2c および gpio グループに追加する。また、lgpio ライブラリが作成する通知用パイプファイル（.lgd-nfy）の書き込み権限エラーを防ぐため、実行ディレクトリ全体の所有権を実行ユーザーに再帰的に設定した上でSystemdサービスとして稼働させる。
### 2.1 監視エージェントの一括導入
全3台のRaspberry Pi（Pi 5, Pi 4, Zero 2 W）に、ハードウェアの負荷情報を公開するための prometheus-node-exporter を導入する。
1. 以下のコードを [roles/exporters/tasks/main.yml](../ansible/roles/exporters/tasks/main.yml) として作成する。
```bash
mkdir -p ~/iac-workspace/ansible/roles/exporters/tasks
```
```bash
---
# exporters/tasks/main.yml
- name: Node Exporterのインストール
  ansible.builtin.apt:
    name: prometheus-node-exporter
    state: present
    update_cache: true

- name: サービスの有効化と起動
  ansible.builtin.systemd:
    name: prometheus-node-exporter
    enabled: true
    state: started
```
2. マスターPlaybook ([site.yml](../ansible/site.yml)) に [exporters](../ansible/roles/exporters) Roleを追加し、実行する。
[site.yml](../ansible/site.yml)
```yaml
---
- name: 共通設定と自動アップデートの適用
  hosts: all
  become: true
  roles:
    - common

- name: 監視エージェントの一括導入
  hosts: all
  become: true
  roles:
    - exporters
```

```bash
ansible-playbook -i local_config/ansible/inventory.ini ansible/site.yml
```
### 2.2 メインサーバーへのUPS Exporterデプロイ
メインサーバー（shakeserver）に接続されたUPSから稼働情報を取得し、Prometheusメトリクスとして公開するカスタムエクスポーターを導入する。
1. ディレクトリを作成する。
```bash
mkdir -p ~/iac-workspace/ansible/roles/ups_exporter/{tasks,handlers}
```
2. 以下のコードを [roles/ups_exporter/tasks/main.yml](../ansible/roles/ups_exporter/tasks/main.yml) として作成する。
[roles/ups_exporter/tasks/main.yml](../ansible/roles/ups_exporter/tasks/main.yml)
```yaml
---
# ups_exporter/tasks/main.yml
- name: 必要なパッケージのインストール
  ansible.builtin.apt:
    name:
      - git
      - i2c-tools
      - ufw
      - curl
    state: present
    update_cache: true

- name: Uvのインストール
  ansible.builtin.shell: |
    set -o pipefail
    curl -LsSf https://astral.sh/uv/install.sh | sh
  args:
    creates: /root/.local/bin/uv
    executable: /bin/bash

- name: Uvバイナリへのシンボリックリンク作成
  ansible.builtin.file:
    src: /root/.local/bin/uv
    dest: /usr/local/bin/uv
    state: link

- name: 実行ユーザーを i2c と gpio グループに追加
  ansible.builtin.user:
    name: "{{ run_user }}"
    groups: i2c,gpio
    append: true

- name: リポジトリのクローン # noqa: latest[git]
  ansible.builtin.git:
    repo: "{{ repo_url }}"
    dest: "{{ install_dir }}"
    force: true
    version: HEAD

- name: 監視用ディレクトリの所有権をユーザーに変更
  ansible.builtin.file:
    path: "{{ install_dir }}"
    state: directory
    owner: "{{ run_user }}"
    group: "{{ run_user }}"
    recurse: true

- name: Uv venvによるPython仮想環境の作成
  ansible.builtin.command: uv venv {{ install_dir }}/venv
  args:
    creates: "{{ install_dir }}/venv"

- name: Uvによる依存関係のインストール
  ansible.builtin.command: uv pip install --python {{ install_dir }}/venv -r {{ install_dir }}/requirements.txt
  register: uv_result
  changed_when: "'Installed' in uv_result.stdout or 'Uninstalled' in uv_result.stdout"

- name: Systemdサービスファイルの配置
  ansible.builtin.copy:
    src: "{{ install_dir }}/ups-exporter.service"
    dest: /etc/systemd/system/ups-exporter.service
    remote_src: true
    mode: "0644"
  notify: Restart ups-exporter

- name: サービスの有効化と起動
  ansible.builtin.systemd:
    name: ups-exporter
    enabled: true
    state: started
    daemon_reload: true

- name: UFWでポート9101の開放 (Tailscaleネットワーク内)
  community.general.ufw:
    rule: allow
    port: "9101"
    proto: tcp
```
3. マスターPlaybook ([site.yml](../ansible/site.yml)) に変数を渡してRoleを追加し、デプロイを実行する。
[site.yml](../ansible/site.yml) (追記部分)
```yaml
- name: メインサーバーのUPS監視とDB/Minecraft/Webの構成
  hosts: home_node1
  become: true
  vars:
    repo_url_ups: "https://github.com/rurutheGeek/ups-exporter.git"
    install_dir_ups: "/opt/ups-exporter"
    run_user_ups: "ansible_admin"
  roles:
    - role: ups_exporter
      vars:
        repo_url: "{{ repo_url_ups }}"
        install_dir: "{{ install_dir_ups }}"
        run_user: "{{ run_user_ups }}"
```

```bash
ansible-playbook -i local_config/ansible/inventory.ini ansible/site.yml
```
### 2.3 監視サーバーへの監視スタックデプロイ
1. 全ノードのNode Exporter、shakeserverのUPS Exporter、およびBlackbox Exporterによるポート80の死活監視を定義する。
    作業ディレクトリを作成する。
```bash
mkdir -p ~/iac-workspace/ansible/files/monitoring
```
    以下のコードを [files/monitoring/prometheus.yml](../ansible/files/monitoring/prometheus.yml) として作成する。
```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'node_exporter'
    static_configs:
      - targets:
        - '100.X.X.1:9100'
        - '100.X.X.2:9100'
        - 'localhost:9100'

  - job_name: 'blackbox'
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
        - http://100.X.X.2:80
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - target_label: __address__
        replacement: 'localhost:9115'

  - job_name: 'ups_exporter'
    static_configs:
      - targets:
        - '100.X.X.2:9101'
```
2. 【ホストネットワークモード（network_mode: "host"）を採用する目的】
   Dockerのデフォルトネットワーク（ブリッジモード）では、コンテナとホストマシンの間に仮想的なルーターが挟まるため、特定のVPN環境（Tailscaleなど）からコンテナ内部への通信が正しくルーティングされず、接続がタイムアウトする現象が発生しやすい。ホストネットワークモードを採用することで、コンテナがホストマシンのネットワークインターフェースを直接利用できるようになり、複雑なルーティング問題を回避してTailscale経由での確実な通信を保証する。

   DockerとTailscaleのルーティング制限によるタイムアウトを回避するため、コンテナ群はホストネットワークモードで起動する。
   以下のコードを [files/monitoring/monitoring-compose.yml](../ansible/files/monitoring/monitoring-compose.yml) として作成する。
```yaml
services:
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    network_mode: "host"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    restart: unless-stopped

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    network_mode: "host"
    volumes:
      - grafana_data:/var/lib/grafana
    restart: unless-stopped

  blackbox_exporter:
    image: prom/blackbox-exporter:latest
    container_name: blackbox_exporter
    network_mode: "host"
    restart: unless-stopped

volumes:
  prometheus_data:
  grafana_data:
```
3. ディレクトリを作成し、監視スタックのRole [roles/monitoring/tasks/main.yml](../ansible/roles/monitoring/tasks/main.yml) を作成する。
```bash
mkdir -p ~/iac-workspace/ansible/roles/monitoring/{tasks,handlers}
```
`[roles/monitoring/tasks/main.yml](../ansible/roles/monitoring/tasks/main.yml)`
```yaml
---
# monitoring/tasks/main.yml
- name: Dockerインストールスクリプトの実行
  ansible.builtin.shell: |
    set -o pipefail
    curl -fsSL https://get.docker.com | sh
  args:
    creates: /usr/bin/docker
    executable: /bin/bash

- name: Docker Compose V2 プラグインのインストール
  ansible.builtin.apt:
    name: docker-compose-plugin
    state: present
    update_cache: true

- name: 監視用ポート（Prometheus 9090, Grafana 3000）の開放
  community.general.ufw:
    rule: allow
    port: "{{ item }}"
    proto: tcp
  loop:
    - "9090"
    - "3000"

- name: 監視用ディレクトリの作成
  ansible.builtin.file:
    path: /opt/monitoring
    state: directory
    owner: ansible_admin
    mode: "0755"

- name: 設定ファイルの配置
  ansible.builtin.copy:
    src: "files/monitoring/{{ item }}"
    dest: /opt/monitoring/{{ item }}
    mode: "0644"
  loop:
    - prometheus.yml
    - monitoring-compose.yml
  notify: Restart monitoring containers

- name: コンテナの起動 (Docker Compose V2)
  community.docker.docker_compose_v2:
    project_src: /opt/monitoring
    files:
      - monitoring-compose.yml
    state: present
    wait: true
```
4. マスターPlaybook (site.yml) に監視サーバーへのRoleを追加し、デプロイを実行する。
site.yml (追記部分)
```yaml
- name: 監視サーバーへの監視スタックデプロイ
  hosts: home_node2
  become: true
  roles:
    - monitoring
```

```bash
ansible-playbook -i local_config/ansible/inventory.ini ansible/site.yml
```

### 2.4 稼働確認とGrafanaでの可視化設定
Prometheusにデータが届いていることを確認し、Grafanaでグラフを表示させる。
#### 2.4.1 Prometheusでの確認
1. ブラウザで Prometheus http://192.168.X.3:9090/targets を開く。
2. node_exporter ジョブ配下の3つのターゲットがすべて UP になっていることを確認する。
    - 100.X.X.1:9100 (negitoroserver)
    - 100.X.X.2:9100 (shakeserver)
    - localhost:9100 (tarakoserver)
#### 2.4.2 Grafanaの初期設定
1. ブラウザでGrafana http://100.X.X.3:3000 にアクセスしログインする（初期ID/パスワード：admin / admin）。
2. 言語設定の変更: プロフィールアイコンからProfile設定へ移動し、Languageを日本語に変更する。
3. Data Sourceの追加: Connections > Data sources > Add data source から Prometheus を選択。URLに http://localhost:9090 を入力して Save & test を実行する。
4. Node Exporterダッシュボードのインポート: 左メニュー ダッシュボード > 新規 > インポート を選択。1860 を入力してLoadし、Data Sourceに登録したPrometheusを指定してImportを実行する。
5. UPS監視用パネルの追加: 新規ダッシュボードを作成し、以下のPromQLクエリを指定してパネルを追加する。
    - バッテリー残量: ups_battery_capacity_percent
    - 電源ステータス: ups_external_power_status
    - 電圧: ups_voltage_volts

---

### 2.5 Discord Webhook による即時外部通知とコンテナ死活監視の構成

Prometheusによるデータ収集だけでなく、バックアップ処理の実行成否（圧縮エラー、アップロードエラー）や、稼働中のBotコンテナ（ubsleepy_bot）自体の突然の異常停止を即時かつ能動的に検知して管理者に通知するため、Discord Webhookを用いたリアルタイムアラート通知機構を導入します。

#### 1. Discord Webhook URL の作成および取得手順
アラートの送信先となる Discord の Webhook を取得します。

1. Webhook 通知を受け取りたい Discord サーバーのテキストチャンネル（例: #system-alerts）の設定アイコン（歯車マーク）をクリックする。
2. チャンネル設定の左側メニューから「連携サービス」を選択する。
3. 「ウェブフックを作成」をクリックする（すでにウェブフックがある場合は「ウェブフックを管理」から「新しいウェブフック」をクリック）。
4. ウェブフックの編集画面で、表示名（例: shakeserver-monitor）を設定し、対象のテキストチャンネルが正しいことを確認する。
5. 「ウェブフックURLをコピー」をクリックしてクリップボードにコピーし、手元に保存する。

#### 2. Webhookの変数抽象化による管理の柔軟化
通知先のURLは公開リポジトリ上に流出させないよう、機密変数ファイル local_config/ansible/credentials/vault.yml で ubsleepy_backup_discord_webhook 変数として定義し、暗号化して管理します。マニュアル 1 に従って vault.yml に以下のように設定します。

local_config/ansible/credentials/vault.yml
```yaml
ubsleepy_backup_discord_webhook: "https://discordapp.com/api/webhooks/YOUR_DUMMY_WEBHOOK_URL"
```

#### 3. 死活監視およびWebhook送信処理の実装仕様

バックアップ実行時に、スクリプト内で docker inspect コマンドを用いて ubsleepy_bot コンテナの稼働状態（.State.Running）をチェックし、停止またはコンテナが存在しない場合にアラートを即時発報する。

また、圧縮処理（tar）やR2へのアップロード処理（aws s3 cp）の成否判定にもWebhook送信処理（curlによるJSONポスト送信）を組み込んでおり、エラー発生時は赤色、コンテナ停止時は橙色、バックアップ正常完了時は緑色でDiscordに埋め込みメッセージ（embeds）を送信する。

#### 4. Dockerデーモンソケットへのアクセス権限調整
Systemdタイマーにより定期キックされるバックアップサービスが、一般ユーザー（ansible_admin）のままで docker inspect を実行した際、Dockerのソケットファイル（/var/run/docker.sock）への読み書き権限不足（permission denied）によって死活チェックが失敗し、誤アラートが送信される問題を防止するため、Systemdサービス定義テンプレート [roles/ubsleepy_backup/templates/ubsleepy-backup.service.j2](../iac-workspace/ansible/roles/ubsleepy_backup/templates/ubsleepy-backup.service.j2) にてプロセスの実行グループを docker グループに修正している。

```ini
User=ansible_admin
Group=docker
```

---

### 2.6 cAdvisor による Docker コンテナの健康状態監視と Grafana 可視化

Dockerコンテナ（ubsleepy_botコンテナなど）のCPU使用率、メモリ消費量、ディスクI/O、ネットワーク流量、およびコンテナ自体の詳細なリソース健康状態をリアルタイムで監視するため、Google製のコンテナ監視エージェントであるcAdvisor（Container Advisor）を導入し、PrometheusおよびGrafanaと統合する。

#### 1. cAdvisor エージェントのデプロイとポート競合の回避
監視エージェントロール exporters にて、ホストに Docker がインストールされているかを自動検出し、Docker 稼働ホスト（shakeserver）において cAdvisor を Docker コンテナとして自動デプロイする構成としている。

一般的に cAdvisor が使用するデフォルトの 8080 ポートは他の Web アプリケーションなどで競合しやすいため、本システムでは公開ポートを 8090 にマッピングし、ポート競合を防止する堅牢な設計を採用している。また、ファイアウォール（UFW）で 8090 ポートの通信を開放している。

[roles/exporters/tasks/main.yml](../iac-workspace/ansible/roles/exporters/tasks/main.yml)
```yaml
- name: cAdvisorコンテナの起動
  community.docker.docker_container:
    name: cadvisor
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    state: started
    restart_policy: unless-stopped
    privileged: true
    devices:
      - "/dev/kmsg:/dev/kmsg"
    ports:
      - "8090:8080"
    volumes:
      - "/:/rootfs:ro"
      - "/var/run:/var/run:ro"
      - "/sys:/sys:ro"
      - "/var/lib/docker/:/var/lib/docker:ro"
      - "/dev/disk/:/dev/disk:ro"
  when: exporters_docker_check.rc == 0
```

#### 2. Prometheus へのスクレイプジョブの追加
監視サーバー上の prometheus.yml に cadvisor ジョブを追加し、メインサーバー（100.116.167.59:8090）から15秒周期で自動スクレイプ（メトリクス収集）を行うよう設定している。

[files/monitoring/prometheus.yml](../iac-workspace/ansible/files/monitoring/prometheus.yml)
```yaml
  - job_name: 'cadvisor'
    static_configs:
      - targets:
          - '100.116.167.59:8090'
```

#### 3. 監視構成のデプロイ適用（実機への反映方法）
定義した各種設定ファイルを実機に配布し、エージェントを自動起動して監視システムに反映するには、以下のいずれかのデプロイ処理を実行する。

監視関連の設定（cAdvisorのデプロイ、Prometheus設定の更新）のみを高速で個別適用する場合：
```bash
ansible-playbook -i iac-workspace/local_config/ansible/inventory.ini -e @iac-workspace/local_config/ansible/vars.yml -e @iac-workspace/local_config/ansible/credentials/vault.yml iac-workspace/ansible/site.yml --tags exporters,monitoring
```

インフラ全体に本番反映を行う場合：
ラッパースクリプトを実行し、メインメニューから [2] デプロイ反映フェーズ を選択後、サブメニューから [1] 本番反映実行（全サービスの一括展開）を選択する。
```bash
./iac-workspace/run_playbook.sh
```

#### 4. Grafana でのダッシュボードインポートによる健康状態の可視化
Prometheusに収集されたcAdvisorメトリクスをGrafanaで視覚的に監視するため、以下の手順でコンテナ専用ダッシュボードを構築する。

- 監視サーバーのGrafana（http://100.X.X.3:3000）にログインする。
- 左側メニューのダッシュボードメニューから新規インポートを選択する。
- ダッシュボードのインポート画面で、コンテナ健康状態可視化用として著名なテンプレートID 14282（または179）を入力してロードする。
- データソースとしてPrometheusを指定してダッシュボードを作成する。
- 作成されたダッシュボードにより、稼働中のコンテナ（ubsleepy_botなど）個別のCPU使用率、メモリ制限に対する消費率、ディスクおよびネットワークI/Oの健康状態がグラフィカルに表示され、稼働コンテナの異常をリアルタイムに把握できるようになる。

---

### 3.7 Cloudflare Workersと連携した自動フェイルオーバーの構築

#### 1. 目的
自宅サーバーのダウン時（停電やネットワーク障害など）、Cloudflare側のエッジサーバー（Workers）で任意のメンテナンス画面（HTTP 503）を即座に代理応答させるゼロコストの高可用性機構を構築する。Prometheusの死活監視と連携することで、ダウン検知および復旧時のルーティング切り替えを完全自動化する。

#### 2. Cloudflare WorkersスクリプトとTerraformの構成
表示させるメンテナンス画面のHTML/JSファイル構成と、Terraformによるデプロイの仕組みを構築する。

1. 作業ディレクトリ内に [worker_scripts](../iac-workspace/terraform/worker_scripts) ディレクトリを作成し、メンテナンス画面のHTMLファイルとルーティング用Workerスクリプトを配置する。このHTMLの内容を編集することで、ユーザーが独自にデザインした任意の503ページを表示させることができる。
   [iac-workspace/terraform/worker_scripts/maintenance.html](../iac-workspace/terraform/worker_scripts/maintenance.html)
   [iac-workspace/terraform/worker_scripts/failover_worker.js](../iac-workspace/terraform/worker_scripts/failover_worker.js)
2. [terraform/main.tf](../iac-workspace/terraform/main.tf) に cloudflare_workers_script および cloudflare_workers_route リソースを追記し、変数 maintenance_mode によってトラフィックのルーティング先を自宅サーバーからWorkersへ動的に切り替えられるよう構成する。

#### 3. 手動切り替えおよびDiscord通知スクリプトの作成
運用操作を簡略化するため、Terraform変数の上書き適用とDiscordへのステータス通知を同時に行うシェルスクリプト toggle_maintenance.sh を作成する。このスクリプトは on または off を引数として受け取り、即座にインフラ構成を変更する。
iac-workspace/toggle_maintenance.sh

#### 4. Alertmanagerによるダウン自動検知とWebhook連携
Prometheusの blackbox_exporter を活用し、「30秒間応答がなければダウンとみなす」ルールを定義する。

1. [files/monitoring/prometheus_rules.yml](../iac-workspace/ansible/files/monitoring/prometheus_rules.yml) を作成し、HTTPステータスチェックに基づく ProxyDown アラートのルールを記述する。
2. [files/monitoring/alertmanager.yml](../iac-workspace/ansible/files/monitoring/alertmanager.yml) を構成し、上記アラート発火（firing）時および復旧（resolved）時に、ローカルのWebhookレシーバーへ通知を送信するよう設定する。

#### 5. Webhookレシーバー（自動切り替えブリッジ）の実装
Alertmanagerからの通知を受け取り、自動で toggle_maintenance.sh を叩くWebhookレシーバーを構築する。

1. [files/monitoring/failover_webhook.py](../iac-workspace/ansible/files/monitoring/failover_webhook.py) を作成し、HTTP POSTを受け取ってアラートステータスを解析するPythonスクリプトを実装する。
2. Ansibleロール [monitoring](../iac-workspace/ansible/roles/monitoring) 内で、このPythonスクリプトを failover-webhook.service という名前のsystemdサービスとして登録し、バックグラウンドで常時稼働させる。

#### 6. 動作テスト手順
構築した仕組みが正常に動作するか確認する。
1. 手動テスト: ./iac-workspace/toggle_maintenance.sh on を実行し、ドメインにアクセスして設定したメンテナンス画面が表示されること、Discordに通知が飛ぶことを確認する。その後 off で元に戻す。
2. 自動テスト: プロキシサーバーのNginxコンテナを停止する、またはUFWでポートを塞ぐなどして擬似的なダウン状態を作る。約30秒後に自動でメンテナンス画面に切り替わり、復旧させると元に戻ることを確認する。

---

### 3.8 Grafana Loki + Promtail によるログ集約

Prometheus は数値メトリクスを収集するが、コンテナや OS のテキストログは各ノードに分散したまま `journalctl` や `docker logs` でしか確認できない。Loki + Promtail を導入することで、全ノードのログを Grafana 上で一元検索できるようになる（Splunk の OSS 代替）。

#### 構成

| コンポーネント | 役割 | ポート |
|---|---|---|
| Loki | ログ集約・保管（Push 受信） | 3100 (Tailscaleのみ) |
| Promtail | 各ノードのログ転送エージェント | 9080 (内部のみ) |

#### デプロイ

monitoring role に Loki/Promtail が含まれているため、以下のタグで反映する。

```bash
ansible-playbook -i local_config/ansible/inventory.ini -e @local_config/ansible/vars.yml -e @local_config/ansible/credentials/vault.yml ansible/site.yml --tags monitoring
```

Promtail 設定 [roles/monitoring/templates/promtail-config.yml.j2](../iac-workspace/ansible/roles/monitoring/templates/promtail-config.yml.j2) はホスト名を自動注入するため、ノードごとに個別設定は不要。

#### Grafana での設定

**① Data Source の追加**

1. Grafana（http://100.X.X.3:3000）にログインする。
2. 左メニュー → **Connections** → **Data sources** → **Add new data source** をクリックする。
3. 検索欄に `Loki` と入力して選択する。
4. **URL** 欄に `http://localhost:3100` を入力する。
5. 画面最下部の **Save & test** をクリックし、`"Data source successfully connected."` と表示されれば成功。

> **補足:** `/ready` エンドポイントが "Ingester not ready" を返していても、Loki は実際には動作している。Save & test が成功していれば問題ない。

**② Explore でのログ検索**

1. 左メニュー（コンパスアイコン）→ **Explore** を開く。
2. 画面上部のデータソース切り替えドロップダウンで **Loki** を選択する。
3. **Label filters** の行に **2つのテキストボックス**が表示される。
   - 左のボックス（ラベル名）に `job` と入力する。
   - 右のボックス（ラベル値）に `varlogs` と入力する。
4. 右上の **Run query** をクリックするとログが表示される。

**主なラベルと用途**

| ラベル | 値の例 | 用途 |
|---|---|---|
| `job` | `varlogs` | `/var/log/` 配下のシステムログ全般 |
| `job` | `docker` | Docker コンテナのログ全般 |
| `compose_service` | `prometheus`, `grafana` など | 特定のコンテナに絞り込む |
| `host` | `tarakoserver` | ノードで絞り込む（複数ノード時） |

**③ Prometheus との組み合わせ**

既存の Prometheus ダッシュボードを開き、パネルの追加時にデータソースとして Loki を選ぶと、メトリクスグラフとログを同一画面に並べて確認できる。


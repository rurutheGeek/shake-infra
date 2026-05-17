**【IaC（Infrastructure as Code）を導入する目的】**
手作業でサーバーの初期設定やソフトウェアのインストールを行うと、手順の抜け漏れや設定ミスが発生しやすく、後から「どのサーバーに何を設定したか」が分からなくなる（ブラックボックス化する）問題がある。
インフラの状態や設定手順をプログラムコード（TerraformやAnsible）として記述・管理することで、**誰が実行しても全く同じ環境が構築できる（再現性の確保）**、**過去の設定変更履歴をGit等で追跡できる（バージョン管理）**、**サーバー構築の完全な自動化（運用コスト削減）**といった強力なメリットを得ることができる。

**Windows環境**では、WSL2（Windows Subsystem for Linux 2）を使用してUbuntu環境を構築し、その内部で構成管理ツールを実行する。
### この章終了時点の最終的なディレクトリ構成
※末尾に `*` が付いているものは、この章で新しく追加されたディレクトリ・ファイルです。
```text
iac-workspace *
├── ansible *
│   ├── files *
│   ├── group_vars *
│   │   └── all *
│   ├── inventory.ini *
│   ├── playbooks *
│   │   └── create_ansible_user.yml *
│   ├── roles *
│   │   └── common *
│   │       └── tasks *
│   │           └── main.yml *
│   ├── secrets *
│   ├── site.yml *
│   └── templates *
└── terraform *
    └── main.tf *
```
### 1.1 WSL2とUbuntuのインストール
1. PowerShellを「管理者として実行」で開く。
2. 以下のコマンドを実行する。
    ```PowerShell
    wsl --install
    ```
3. PCを再起動する。
4. 再起動後、Ubuntuのターミナルが自動起動する。画面の指示に従い、UNIXユーザー名とパスワードを設定する。
    ※以降の作業はすべてUbuntuターミナル内で実行する。

## Linux環境（Ubuntu/Debian系）のセットアップ
Linux環境で、OSの標準ターミナル上で直接ツールをインストールする。
### 1.2 Ansibleのインストール
Ubuntuターミナルで以下のコマンドを順に実行する。
```Bash
sudo apt update
sudo apt install software-properties-common -y
sudo add-apt-repository --yes --update ppa:ansible/ansible
sudo apt install ansible -y
```
### 1.3 Terraformのインストール
```Bash
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update
sudo apt install terraform -y
```
### 1.4 SSH公開鍵の生成と配置
AnsibleがパスワードなしでRaspberry Piへ接続するための設定を行う。
1. 鍵の生成。パスフレーズを求められたら何も入力せずにEnterを押し、空のまま作成する。
    ```Bash
    ssh-keygen -t rsa -b 4096
    ```
2. 各Raspberry Piへ公開鍵を転送する。`IP_ADDRESS` の部分は実際のローカルIPに置き換える。初回のみ対象機器のパスワード入力を求められる。
    ```Bash
	ssh-copy-id username@IP_ADDRESS
    ```
### 1.5 作業用ディレクトリの作成
インフラのコードを保存するディレクトリを作成し、移動する。
```bash
mkdir -p ~/iac-workspace/terraform
mkdir -p ~/iac-workspace/ansible/{playbooks,roles,group_vars/all,secrets,files,templates}
cd ~/iac-workspace
```


### 1.6 Terraformの構成と適用（Cloudflare設定）
1.  Ubuntuターミナルで `terraform` フォルダに移動する。
    ```bash
    cd ~/iac-workspace/terraform
    ```
2.  以下のコードを `main.tf` として作成する。
   *   `YOUR_CLOUDFLARE_API_TOKEN`、`YOUR_ZONE_ID`、`YOUR_CLOUDFLARE_ACCOUNT_ID`、`example.com` の各プレースホルダーは自身のCloudflare環境の実際の値に書き換える。
```tf
terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  api_token = "YOUR_CLOUDFLARE_API_TOKEN"
}

# ゾーンIDの変数を定義
variable "cloudflare_zone_id" {
  default = "YOUR_ZONE_ID"
}

# 大学ノードのAレコード設定 (プロキシ無効でTCP/UDPを通す)
resource "cloudflare_record" "univ_node" {
  zone_id = var.cloudflare_zone_id
  name    = "example.com" # 取得したドメイン名に置き換える
  value   = "192.0.2.1"   # 大学ノードのIPアドレス(後で大学設置時のグローバルIPに変更)
  type    = "A"
  proxied = false
}

# 共通バックアップ用R2バケットの作成
resource "cloudflare_r2_bucket" "backup_bucket" {
  account_id = "YOUR_CLOUDFLARE_ACCOUNT_ID"
  name       = "shakeserver-backup"
  location   = "APAC"
}

# ubsleepyアプリデータおよびバックアップ用R2バケットの作成
resource "cloudflare_r2_bucket" "ubsleepy_bucket" {
  account_id = "YOUR_CLOUDFLARE_ACCOUNT_ID"
  name       = "ubsleepy-app-data"
  location   = "APAC"
}
```
3.  以下のコマンドを順に実行し、Cloudflare上にDNSレコードとR2バケットを作成する。
   実行中、適用の確認を求められた場合は `yes` と入力する。
```bash
    terraform init
    terraform apply
```
#### 1.6.1 YOUR_CLOUDFLARE_API_TOKEN (APIトークン) の取得方法
1. Cloudflareダッシュボード右上の「マイプロフィール」アイコン（人型マーク）をクリックし、「マイプロフィール」を選択する。
2. 左側メニューから「API トークン」を選択し、「トークンを作成する」をクリックする。
3. ページ下部の「カスタム トークンを作成する」の「はじめる」をクリックする。
4. TerraformでDNSレコードとR2バケットの両方を自動構成するため、「アクセス許可」の項目で以下の2つを設定する。
    - 「ゾーン」 - 「DNS」 - 「編集」
    - 「アカウント」 - 「Workers R2 ストレージ」 - 「編集」
5. 「概要に進む」をクリックし、「トークンを作成する」を実行する。
6. 表示された文字列がAPIトークンである。※セキュリティ上、この文字列は画面を閉じると二度と表示されないため、確実にコピーして控える。
#### 1.6.2 YOUR_ZONE_ID (ゾーンID) と YOUR_CLOUDFLARE_ACCOUNT_ID (アカウントID) の取得方法
1. Cloudflareダッシュボードのトップページ（Webサイト一覧）から、設定対象のドメインをクリックする。
2. 左側メニューで「概要」が選択されていることを確認する。
3. 画面を右下までスクロールすると、「API」というセクションが存在する。
4. 「ゾーン ID」および「アカウント ID」という英数字の文字列が表示されているため、それぞれの右側にある「クリックしてコピー」を使用して取得する。

#### 1.6.3 Cloudflare R2 専用の S3 API 資格情報（アクセスキー・シークレットキー）の取得方法
Terraform で作成された R2 バケットに、Ansible 経由でファイルをアップロード・ダウンロードする（awscli等で制御する）ための API トークン（S3 互換資格情報）を払い出します。

1. Cloudflare ダッシュボードの左側メニューから「R2」を選択する。
2. 画面右側にある「R2 API トークンの管理」をクリックする。
3. 「API トークンを作成する」をクリックする。
4. トークンの詳細設定で以下を指定する。
    - トークン名: 任意の識別名（例: `shakeserver-backup-token`）
    - アクセス許可: 「読み取りと書き込み」を選択する。
    - 対象バケット: 「特定のバケットのみ」を選択し、先ほど作成した `shakeserver-backup` および `ubsleepy-app-data` を指定する（または「すべてのバケット」にする）。
5. 「API トークンを作成する」を実行する。
6. 作成完了画面に、以下の値が表示されるため、必ず確実にコピーしてローカルに保存する。
    - **アクセスキー ID** (S3 Access Key ID)
    - **シークレットアクセスキー** (S3 Secret Access Key)
    ※これらの値は、この画面を閉じると二度と表示されません。

### 1.7 Ansibleの構成と適用（自動操作用ユーザーの作成と初期通信）
1. 作業ディレクトリ内の `ansible` フォルダに移動する。
	```bash
	cd ~/iac-workspace/ansible
	```
2. 現在のアクセスユーザーを利用して、初期設定用の `inventory.ini` を作成・保存する。
```toml
	[proxy_node]
	negitoroserver ansible_host=192.168.X.1 ansible_user=ruru
	
	[home_node1]
	shakeserver ansible_host=192.168.X.2 ansible_user=39ix
	
	[home_node2]
	tarakoserver ansible_host=192.168.X.3 ansible_user=ruru
	
	[all:vars]
	ansible_ssh_private_key_file=~/.ssh/id_rsa
```
3. 自動操作専用ユーザー（`ansible_admin`）を作成するためのPlaybookを `playbooks/create_ansible_user.yml` として作成・保存する。
```yaml
---
- name: 自動操作用ユーザーの作成と設定
  hosts: all
  become: true
  vars:
    new_user: ansible_admin
  tasks:
    - name: ユーザーの作成
      ansible.builtin.user:
        name: "{{ new_user }}"
        state: present
        shell: /bin/bash
        create_home: true

    - name: sudo権限の付与 (パスワードなし)
      ansible.builtin.copy:
        dest: "/etc/sudoers.d/{{ new_user }}"
        content: "{{ new_user }} ALL=(ALL) NOPASSWD: ALL"
        mode: '0440'
        validate: 'visudo -cf %s'

    - name: SSH公開鍵の登録
      ansible.posix.authorized_key:
        user: "{{ new_user }}"
        state: present
        key: "{{ lookup('file', '~/.ssh/id_rsa.pub') }}"
```

4. 以下のコマンドを実行し、各ノードに `ansible_admin` を作成する。既存ユーザーのsudoパスワードを求められるため、プロンプトに従って入力する。
  ※各ノードでパスワードが異なる場合は、一度の実行で認証が通らないため、`-l` オプションを使用して対象ノードを1つずつ指定し実行する（例: `ansible-playbook -i inventory.ini playbooks/create_ansible_user.yml -K -l shakeserver`）。
```bash
ansible-playbook -i inventory.ini playbooks/create_ansible_user.yml -K
```

5. ユーザー作成完了後、`inventory.ini` を編集し、すべてのノードの `ansible_user` を作成した `ansible_admin` に書き換えて保存する。
```toml
[proxy_node]
negitoroserver ansible_host=192.168.X.1 ansible_user=ansible_admin

[home_node1]
shakeserver ansible_host=192.168.X.2 ansible_user=ansible_admin

[home_node2]
tarakoserver ansible_host=192.168.X.3 ansible_user=ansible_admin

[all:vars]
ansible_ssh_private_key_file=~/.ssh/id_rsa
```

6. 各サーバーに共通して適用する初期通信確認、セキュリティ自動アップデート、OSのライフサイクル監視、および補助記憶装置（マイクロSDカードやSSD）の摩耗・寿命低下を防ぐためのスワップ（SWAP）無効化設定を一括制御する共通設定ロール `common` と、全体のマスタープレイブック `site.yml` を作成・保存する。

まず、共通ロールのタスク用ディレクトリを作成する。
```bash
mkdir -p ~/iac-workspace/ansible/roles/common/tasks
```

**`site.yml`**
```yaml
---
- name: 共通設定、自動アップデート、およびスワップ無効化の適用
  hosts: all
  become: true
  roles:
    - common
```

**`roles/common/tasks/main.yml`**
```yaml
---
# common/tasks/main.yml
- name: Pingによる疎通確認
  ansible.builtin.ping:

- name: Aptパッケージリストの更新
  ansible.builtin.apt:
    update_cache: true

- name: セキュリティ自動アップデートツールのインストール
  ansible.builtin.apt:
    name:
      - unattended-upgrades
      - apt-listchanges
    state: present

- name: 自動アップデートの基本設定 (20auto-upgrades)
  ansible.builtin.template:
    src: common/20auto-upgrades.j2
    dest: /etc/apt/apt.conf.d/20auto-upgrades
    owner: root
    group: root
    mode: "0644"

- name: 自動アップデートの詳細設定 (50unattended-upgrades)
  ansible.builtin.template:
    src: common/50unattended-upgrades.j2
    dest: /etc/apt/apt.conf.d/50unattended-upgrades
    owner: root
    group: root
    mode: "0644"

- name: Unattended-upgrades サービスの有効化と起動
  ansible.builtin.systemd:
    name: unattended-upgrades
    enabled: true
    state: started

- name: ライフサイクル管理用ディレクトリの作成
  ansible.builtin.file:
    path: /var/lib/lifecycle
    state: directory
    owner: root
    group: root
    mode: "0755"

- name: ライフサイクル監視通知スクリプトの配置
  ansible.builtin.template:
    src: common/server-lifecycle-notify.sh.j2
    dest: /usr/local/bin/server-lifecycle-notify.sh
    owner: root
    group: root
    mode: "0755"

- name: ライフサイクル監視 Systemd サービスの配置
  ansible.builtin.template:
    src: common/server-lifecycle.service.j2
    dest: /etc/systemd/system/server-lifecycle.service
    owner: root
    group: root
    mode: "0644"

- name: ライフサイクル監視 サービスの有効化と起動
  ansible.builtin.systemd:
    name: server-lifecycle
    daemon_reload: true
    enabled: true
    state: started

- name: Raspberry Pi 標準の dphys-swapfile サービスの停止と無効化
  ansible.builtin.systemd:
    name: dphys-swapfile
    enabled: false
    state: stopped
  failed_when: false

- name: 現在有効なすべてのスワップの即時無効化 (swapoff)
  ansible.builtin.command: swapoff -a
  changed_when: false

- name: fstab からのスワップ設定の完全排除
  ansible.builtin.replace:
    path: /etc/fstab
    regexp: '^([^#].*\sswap\s.*)$'
    replace: '# \1'

- name: 不要な dphys-swapfile パッケージの削除
  ansible.builtin.apt:
    name: dphys-swapfile
    state: absent
    purge: true
```


7. 更新したインベントリを使用して以下のコマンドを実行し、新しい `ansible_admin` ユーザーによるSSH接続と `apt` パッケージリストの更新を実行する。
```bash
ansible-playbook -i inventory.ini site.yml
```

### 1.8 Ansible の変数設計と暗号化機密変数（Ansible Vault）の配置テンプレート

本インフラ環境の構成管理では、パブリックに公開してよい通常のインフラ変数（IPアドレス、ドメイン名、バケット名など）と、外部に流出してはならない機密性の高い資格情報（APIトークン、シークレットキー、パスワード等）を完全に分離して管理します。

機密情報は Ansible Vault の仕組みで暗号化して管理しますが、本マニュアルに基づいて新規に環境をアセンブルする際は、以下の変数テンプレートとプレースホルダー値（ダミー）を参考に、事前に `group_vars/all/vars.yml` および `group_vars/all/vault.yml` を作成して配置します。

#### group_vars/all/vars.yml の作成と配置
公開可能なパブリック変数を定義します。以下の内容で `group_vars/all/vars.yml` を作成します。

> **💡 Column: Pythonインタープリタの自動検出とバージョン差異について**
> Ansible実行時、「Host is using the discovered Python interpreter at ...」という警告が表示される場合があります。これは各サーバーのOS（UbuntuやDebian等）の標準Pythonバージョンが異なるために生じる「自動検出の報告」であり、エラーではありません。
> 本環境では、システムOSの破損を防ぐためサーバーごとのPythonバージョンは無理に統一せず、アプリケーション固有の環境は `uv` 等で切り離して構築するモダンな設計を採用しています。この不要な警告を抑制するため、変数ファイルの冒頭に `ansible_python_interpreter: auto_silent` を設定しています。

```yaml
# Ansible 全体設定
ansible_python_interpreter: auto_silent

# パブリックインフラ設定
domain_name: "example.com"
cf_bucket_name: "shakeserver-backup"
cf_account_id: "YOUR_CLOUDFLARE_ACCOUNT_ID"

# Discord Bot (ubsleepy) 設定
ubsleepy_dir: "/opt/ubsleepy"
ubsleepy_repo_url: "https://github.com/example/ubsleepy"
ubsleepy_r2_bucket: "ubsleepy-app-data"
ubsleepy_r2_object_key: "app_data.zip"
ubsleepy_r2_endpoint: "YOUR_CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com"
ubsleepy_backup_r2_bucket: "ubsleepy-app-data"
ubsleepy_backup_r2_endpoint: "YOUR_CLOUDFLARE_ACCOUNT_ID.r2.cloudflarestorage.com"
ubsleepy_backup_max_backups: 7
```

#### group_vars/all/vault.yml（暗号化用ダミーテンプレート）の作成と配置
機密情報のプレースホルダーです。以下の内容で `group_vars/all/vault.yml` を作成します。
実際の本番適用時は、このファイルを `ansible-vault encrypt group_vars/all/vault.yml` コマンドで暗号化して管理します。

```yaml
# Cloudflare API資格情報
cf_access_key: "DUMMY_CF_ACCESS_KEY"
cf_secret_key: "DUMMY_CF_SECRET_KEY"

# PostgreSQL データベース認証情報
postgres_user: "postgres_admin"
postgres_password: "DUMMY_POSTGRES_PASSWORD"
db_name: "shakedb"
db_user_reader: "db_reader"
db_password_reader: "DUMMY_READER_PASSWORD"
db_user_editor: "db_editor"
db_password_editor: "DUMMY_EDITOR_PASSWORD"

# Discord Bot (ubsleepy) 認証情報
ubsleepy_r2_access_key_id: "DUMMY_R2_ACCESS_KEY_ID"
ubsleepy_r2_secret_access_key: "DUMMY_R2_SECRET_ACCESS_KEY"
ubsleepy_discord_token: "DUMMY_DISCORD_TOKEN"
ubsleepy_backup_r2_access_key_id: "DUMMY_BACKUP_R2_ACCESS_KEY_ID"
ubsleepy_backup_r2_secret_access_key: "DUMMY_BACKUP_R2_SECRET_ACCESS_KEY"
ubsleepy_backup_discord_webhook: "https://discordapp.com/api/webhooks/YOUR_DUMMY_WEBHOOK_URL"
```

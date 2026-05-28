【Tailscale（メッシュVPN）を導入する目的】
サーバーを外部から操作する場合、通常はルーターのポート開放（ポートフォワーディング）を行う必要があるが、これは外部からの不正アクセスやサイバー攻撃の標的になるリスクを伴う。
TailscaleはWireGuardをベースにした最新のメッシュVPN技術であり、ポート開放を一切行わずに安全なプライベートネットワークを構築できる。これにより、物理的に離れた場所にあるデバイス同士でも、あたかも同じ自宅LAN内にあるかのように安全かつ簡単に通信させることが可能になる。

手作業での認証を省き、Ansibleを用いて3台同時にTailscale of インストールとネットワーク参加を自動化する。
### この章終了時点の最終的なディレクトリ構成
※末尾に * が付いているものは、この章で新しく追加されたディレクトリ・ファイルです。
```text
iac-workspace
├── ansible
│   ├── files
│   ├── playbooks
│   │   ├── create_ansible_user.yml
│   │   └── install_tailscale.yml *
│   ├── roles
│   │   └── common
│   │       └── tasks
│   │           └── main.yml
│   ├── site.yml
│   └── templates
├── local_config
│   ├── ansible
│   │   └── credentials
│   └── terraform
└── terraform
    └── main.tf
```
---
#### 1. Tailscale Auth Key の取得
Ansibleから自動でログイン処理を行うための認証キーを発行する。
1.  ブラウザで Tailscale Admin Console (https://login.tailscale.com/admin/settings/keys) にアクセスし、自身のアカウントでログインする。
2.  左側メニューの Settings > Keys を開く。
3.  Auth keys のセクションにある Generate auth key をクリックする。
4.  設定モーダルで以下の通り選択する。
    - Reusable: オン（3台のマシンで同じキーを使うため必須）
    - Ephemeral: オフ
    - Pre-approved: オン（承認待ちを省くため推奨）
5.  Generate key をクリックし、表示された tskey-auth- から始まる文字列をコピーして控える。

#### 2. Tailscaleインストール用Playbookの作成
作業用PCの [iac-workspace/ansible/playbooks](../iac-workspace/ansible/playbooks) ディレクトリに、Tailscaleの導入と設定を行うPlaybookを作成する。
以下のコードを [install_tailscale.yml](../iac-workspace/ansible/playbooks/install_tailscale.yml) として保存する。tailscale_authkey の値は、手順1で取得した実際のキーに置き換える。

```yaml
---
- name: Tailscaleのインストールとネットワーク参加
  hosts: all
  become: yes
  vars:
    tailscale_authkey: "tskey-auth-XXXXXXXXXXXXXXXXXXXXX"
  tasks:
    - name: Tailscaleインストールスクリプトの実行
      shell: curl -fsSL https://tailscale.com/install.sh | sh
      args:
        creates: /usr/bin/tailscale

    - name: Tailnetへの参加 (Auth Keyを使用)
      command: tailscale up --authkey={{ tailscale_authkey }} --accept-routes
      register: tailscale_result
      changed_when: "'Success' in tailscale_result.stdout"
      failed_when: tailscale_result.rc != 0

    - name: Tailscale IP (IPv4) の取得
      command: tailscale ip -4
      register: ts_ip
      changed_when: false

    - name: 各ノードのTailscale IPを表示
      debug:
        msg: "{{ inventory_hostname }} の Tailscale IP は {{ ts_ip.stdout }} です"

    - name: inventory.iniのIPアドレスをTailscale IPに自動更新
      delegate_to: localhost
      become: no
      replace:
        path: "{{ inventory_file }}"
        regexp: '^({{ inventory_hostname }}\s+ansible_host=)[0-9\.]+(.*)$'
        replace: '\g<1>{{ ts_ip.stdout }}\g<2>'
```

#### 3. Playbookの実行
作業用PCの [iac-workspace/ansible](../iac-workspace/ansible) ディレクトリで以下のコマンドを実行する。

```bash
ansible-playbook -i local_config/ansible/inventory.ini ansible/playbooks/install_tailscale.yml
```

#### 4. IPアドレスの記録
Playbookの実行が完了すると、最後に出力される TASK [各ノードのTailscale IPを表示] のセクションに、各Raspberry Piに割り当てられた 100.x.y.z 形式のIPアドレスが表示される。
```bash
TASK [各ノードのTailscale IPを表示] ************************************************************************************
ok: [negitoroserver] => {
    "msg": "negitoroserver の Tailscale IP は 100.X.X.1 です"
}
ok: [shakeserver] => {
    "msg": "shakeserver の Tailscale IP は 100.X.X.2 です"
}
ok: [tarakoserver] => {
    "msg": "tarakoserver の Tailscale IP は 100.X.X.3 です"
}
```

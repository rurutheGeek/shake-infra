from http.server import BaseHTTPRequestHandler, HTTPServer
import subprocess
import json
import os

SCRIPT_PATH = '/opt/monitoring/maintenance_toggle.sh'


def desired_mode(alerts):
    """ProxyDown の状態からあるべきメンテモードを決める。

    - firing が含まれる -> 'on'（firing 優先。状態不明時はメンテ側に倒す）
    - resolved のみ      -> 'off'
    - 対象アラート無し    -> None（何もしない）
    """
    saw_firing = False
    saw_resolved = False
    for alert in alerts:
        labels = alert.get('labels') or {}
        if labels.get('alertname') != 'ProxyDown':
            continue
        status = alert.get('status')
        if status == 'firing':
            saw_firing = True
        elif status == 'resolved':
            saw_resolved = True
    if saw_firing:
        return 'on'
    if saw_resolved:
        return 'off'
    return None


def run_toggle(mode):
    """maintenance_toggle.sh を実行する。失敗しても例外にしない（常時 ACK のため）。"""
    if not os.path.exists(SCRIPT_PATH):
        print(f"Error: {SCRIPT_PATH} not found.")
        return
    try:
        result = subprocess.run(
            [SCRIPT_PATH, mode],
            check=False, timeout=120,
            capture_output=True, text=True,
        )
        for line in (result.stdout or '').splitlines():
            print(f"toggle[stdout]: {line}")
        for line in (result.stderr or '').splitlines():
            print(f"toggle[stderr]: {line}")
        if result.returncode != 0:
            print(f"WARN: {SCRIPT_PATH} {mode} exited {result.returncode}"
                  " (reconcile timer が後で収束させます)")
    except Exception as e:
        print(f"WARN: failed to run {SCRIPT_PATH} {mode}: {e}")


class WebhookHandler(BaseHTTPRequestHandler):
    def _respond(self, code, body):
        self.send_response(code)
        self.send_header('Content-Type', 'text/plain; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0) or 0)
        post_data = self.rfile.read(content_length)

        try:
            data = json.loads(post_data.decode('utf-8'))
            mode = desired_mode(data.get('alerts') or [])
        except Exception as e:
            print(f"Error parsing webhook payload: {e}")
            self._respond(400, 'Bad Request'.encode('utf-8'))
            return

        if mode is None:
            print("Alert ignored (no ProxyDown alert).")
            self._respond(200, 'Alert ignored'.encode('utf-8'))
            return

        print(f"Received ProxyDown webhook (alerts={len(data.get('alerts') or [])})."
              f" Converging maintenance mode: {mode}")
        run_toggle(mode)

        # 必ず 2xx を返す。5xx を返すと Alertmanager が同一受信者の通知を成功するまで
        # 無期限リトライし（notify.RetryStage）、resolved（=メンテ OFF）が配信されなく
        # なる。切替失敗時のリトライは maintenance_reconcile.timer が担う。
        self._respond(200, f'Accepted ({mode})'.encode('utf-8'))


def run(server_class=HTTPServer, handler_class=WebhookHandler, port=9000):
    server_address = ('127.0.0.1', port)
    httpd = server_class(server_address, handler_class)
    print(f'Starting failover webhook receiver on port {port}...')
    httpd.serve_forever()


if __name__ == '__main__':
    run()

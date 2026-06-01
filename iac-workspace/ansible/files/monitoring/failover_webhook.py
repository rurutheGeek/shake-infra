from http.server import BaseHTTPRequestHandler, HTTPServer
import subprocess
import json
import os

class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers['Content-Length'])
        post_data = self.rfile.read(content_length)
        
        try:
            data = json.loads(post_data.decode('utf-8'))
            alerts = data.get('alerts', [])
            
            for alert in alerts:
                # ProxyDown アラートが発火(firing)した場合
                if alert.get('status') == 'firing' and alert['labels'].get('alertname') == 'ProxyDown':
                    print("Received ProxyDown firing alert. Triggering maintenance mode ON...")
                    # toggle_maintenance.sh を on で実行
                    script_path = '/opt/monitoring/maintenance_toggle.sh'
                    
                    if os.path.exists(script_path):
                        subprocess.run([script_path, 'on'], check=True)
                        print("Failover script executed successfully.")
                    else:
                        print(f"Error: {script_path} not found.")

                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'Maintenance mode activated')
                    return

                # ProxyDown アラートが解決(resolved)した場合
                elif alert.get('status') == 'resolved' and alert['labels'].get('alertname') == 'ProxyDown':
                    print("Received ProxyDown resolved alert. Triggering maintenance mode OFF...")
                    # toggle_maintenance.sh を off で実行
                    script_path = '/opt/monitoring/maintenance_toggle.sh'
                    
                    if os.path.exists(script_path):
                        subprocess.run([script_path, 'off'], check=True)
                        print("Failback script executed successfully.")
                    else:
                        print(f"Error: {script_path} not found.")

                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'Maintenance mode deactivated')
                    return

            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'Alert ignored')
            
        except Exception as e:
            print(f"Error processing webhook: {e}")
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b'Internal Server Error')

def run(server_class=HTTPServer, handler_class=WebhookHandler, port=9000):
    server_address = ('127.0.0.1', port)
    httpd = server_class(server_address, handler_class)
    print(f'Starting failover webhook receiver on port {port}...')
    httpd.serve_forever()

if __name__ == '__main__':
    run()

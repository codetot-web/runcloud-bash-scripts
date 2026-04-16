Check the status of all 20 production servers: script version, SSH connectivity, and dashboard health.

Steps:
1. Read server list from `sqlite3 ~/.rc/rc.db "SELECT hostname, ssh_port FROM servers ORDER BY hostname;"`
2. In parallel, SSH to each server and run: `cd /root/runcloud-bash-scripts && git log --oneline -1`
3. Check dashboard is running: `docker ps --filter name=rc-dashboard --format '{{.Status}}'`
4. Check dashboard API: `curl -s http://localhost:8090/api/servers | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{len(d)} servers')"`
5. Report: table of server | status | git commit

# runcloud-bash-scripts

Server management scripts for RunCloud-managed WordPress hosting fleet.

## Architecture

- **20 production servers** across SG, VN, JP regions (see `~/.rc/config.yaml`)
- **Multi-user**: apps live under `/home/*/webapps/`, not just `/home/runcloud/`
- **SSH access**: all servers via root, ports vary (22 or 2018, defined in config)
- **Git-tracked**: repo cloned at `/root/runcloud-bash-scripts/` on every server
- **Dashboard integration**: scripts registered as actions in `runcloud-go/internal/web/server.go` `appScripts` map

## Key patterns

### Script conventions
- All scripts use `set -euo pipefail`
- Color helpers: `info()`, `success()`, `warn()`, `error()`
- Site resolution: accept `--site=NAME` (searches `/home/*/webapps/`) or `--path=PATH` (full path)
- Site owner detection: `stat -c '%U'` (Linux) with `stat -f '%Su'` (BSD) fallback
- wp-cli: search multiple paths (`/usr/local/bin/wp`, `/usr/bin/wp`, RunCloud agent)
- Run wp-cli as site owner: `sudo -u $SITE_OWNER $WP_CLI --path=$SITE_PATH`

### Deployment
```bash
# Deploy to all servers (parallel):
sqlite3 ~/.rc/rc.db "SELECT hostname, ssh_port FROM servers;" | while IFS='|' read -r host port; do
    (ssh -p "$port" -o ConnectTimeout=5 "root@$host" \
      "cd /root/runcloud-bash-scripts && git checkout -- . 2>/dev/null; git pull --ff-only && chmod +x *.sh") &
done; wait
```

### Dashboard registration
In `runcloud-go/internal/web/server.go`, use `{name}` and `{path}` placeholders (NOT `%s`):
```go
"vuln-check": "bash /root/runcloud-bash-scripts/wp-vuln-check.sh --path={path} --include-core",
```

## Testing
- Syntax check: `bash -n script.sh`
- Test on a single server: `scp -P PORT script.sh root@YOUR_SERVER:/root/test.sh && ssh -p PORT root@YOUR_SERVER "bash /root/test.sh --site=SITE_NAME"`
- Always test before merge+deploy

## Common pitfalls
- Never hardcode `/home/runcloud/` — use `/home/*/webapps/` glob or accept `--path=`
- `fmt.Sprintf` in Go eats `%U` from `stat -c %U` — use `{name}`/`{path}` placeholders only
- `git checkout -- .` before `git pull` on servers (filemode changes from `chmod +x` block pulls)
- wp-cli may not be in PATH during cron — always search candidate paths

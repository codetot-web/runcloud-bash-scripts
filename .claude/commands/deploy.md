Deploy the latest bash scripts to all 20 production servers and rebuild+restart the Go dashboard Docker container.

Steps:
1. Run `git push` on both repos if there are unpushed commits
2. Deploy scripts to all servers in parallel: read server list from `sqlite3 ~/.rc/rc.db "SELECT hostname, ssh_port FROM servers;"`, SSH to each, `git checkout -- . && git pull --ff-only && chmod +x *.sh`
3. Rebuild Docker: `cd /Users/khoipro/Projects/runcloud-go && docker build -t codetot/rc:latest .`
4. Restart dashboard: `docker stop rc-dashboard && docker rm rc-dashboard && docker run -d --name rc-dashboard -p 8090:8080 -v ~/.rc:/root/.rc -v ~/.ssh:/root/.ssh:ro --restart unless-stopped codetot/rc:latest`
5. Run steps 2-4 in parallel where possible
6. Report results: count successful/failed servers

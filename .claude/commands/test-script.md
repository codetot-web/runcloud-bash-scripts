Test a bash script on a single production server before deploying fleet-wide.

Usage: /test-script <script-name> <server> <args>
Example: /test-script wp-vuln-check.sh sg9.codetot.org --site=vinhhoan

Steps:
1. Run `bash -n <script>` locally to check syntax
2. Look up SSH port: `sqlite3 ~/.rc/rc.db "SELECT ssh_port FROM servers WHERE hostname='<server>';"`
3. SCP the script to the server: `scp -P <port> <script> root@<server>:/root/test-script.sh`
4. Run it: `ssh -p <port> root@<server> "bash /root/test-script.sh <args>"`
5. Clean up: `ssh -p <port> root@<server> "rm /root/test-script.sh"`
6. Report results

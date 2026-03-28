#!/bin/bash
# Usage:
#   sudo ./change-ssh-port.sh <new_port>
#   sudo ./change-ssh-port.sh restore

SSHD_CONFIG="/etc/ssh/sshd_config"
JAIL_LOCAL="/etc/fail2ban/jail.local"

restore_configs() {
  echo ">>> Restoring configs..."
  # Restore sshd_config
  LATEST_SSHD=$(ls -t ${SSHD_CONFIG}.bak.* 2>/dev/null | head -n 1)
  if [ -n "$LATEST_SSHD" ]; then
    cp "$LATEST_SSHD" $SSHD_CONFIG
    echo "Restored sshd_config from $LATEST_SSHD"
  else
    echo "No sshd_config backup found."
  fi

  # Restore jail.local
  if [ -f "$JAIL_LOCAL" ]; then
    LATEST_JAIL=$(ls -t ${JAIL_LOCAL}.bak.* 2>/dev/null | head -n 1)
    if [ -n "$LATEST_JAIL" ]; then
      cp "$LATEST_JAIL" $JAIL_LOCAL
      echo "Restored jail.local from $LATEST_JAIL"
    else
      echo "No jail.local backup found."
    fi
  fi

  # Restart services
  if command -v systemctl >/dev/null; then
    systemctl restart sshd
    systemctl restart fail2ban
  else
    service ssh restart
    service fail2ban restart
  fi

  echo ">>> Restore complete."
  exit 0
}

if [ "$1" == "restore" ]; then
  restore_configs
fi

if [ -z "$1" ]; then
  echo "Usage: $0 <new_port>|restore"
  exit 1
fi

NEW_PORT=$1
echo ">>> Changing SSH port to $NEW_PORT"

# --- Backup configs ---
cp $SSHD_CONFIG ${SSHD_CONFIG}.bak.$(date +%F-%H%M)
[ -f "$JAIL_LOCAL" ] && cp $JAIL_LOCAL ${JAIL_LOCAL}.bak.$(date +%F-%H%M)

# --- Update sshd_config ---
if grep -q "^#Port 22" $SSHD_CONFIG; then
  sed -i "s/^#Port 22/Port $NEW_PORT/" $SSHD_CONFIG
elif grep -q "^Port " $SSHD_CONFIG; then
  sed -i "s/^Port .*/Port $NEW_PORT/" $SSHD_CONFIG
else
  echo "Port $NEW_PORT" >> $SSHD_CONFIG
fi

# --- Firewalld rules ---
if command -v firewall-cmd >/dev/null; then
  echo ">>> Updating Firewalld rules..."
  firewall-cmd --permanent --add-port=${NEW_PORT}/tcp
  firewall-cmd --permanent --remove-port=22/tcp
  firewall-cmd --reload
else
  echo "Firewalld not found. Please update firewall rules manually or via RunCloud dashboard."
fi

# --- Fail2Ban rules ---
if [ -f "$JAIL_LOCAL" ]; then
  echo ">>> Updating Fail2Ban jail.local..."
  if grep -q "^

\[sshd\]

" $JAIL_LOCAL; then
    sed -i "/^

\[sshd\]

/,/^

\[/ s/^port.*/port = $NEW_PORT/" $JAIL_LOCAL
  else
    cat <<EOF >> $JAIL_LOCAL

[sshd]
enabled = true
port    = $NEW_PORT
filter  = sshd
logpath = /var/log/auth.log
maxretry = 5
EOF
  fi
else
  echo "Fail2Ban jail.local not found. Please configure manually."
fi

# --- Restart services ---
echo ">>> Restarting services..."
if command -v systemctl >/dev/null; then
  systemctl restart sshd
  systemctl restart fail2ban
else
  service ssh restart
  service fail2ban restart
fi

echo ">>> SSH port changed to $NEW_PORT."
echo ">>> Firewalld and Fail2Ban updated."
echo ">>> Reminder: Check RunCloud dashboard to ensure the new port is allowed."
echo ">>> Reminder: ModSecurity and site authentication are web-layer protections, no SSH changes needed."

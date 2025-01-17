#!/bin/bash

set -e

export DEBIAN_FRONTEND=noninteractive

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (with sudo)." >&2
    exit 1
fi

FLAG_FILE="/var/log/install_script_completed"

if [[ -f "$FLAG_FILE" ]]; then
    echo "The installation and configuration have already been completed. Exiting."
    exit 0
fi

version=$(awk '/Version/ {print $2}' package/DEBIAN/control)
echo -e "\n  ____   v:$version         _        __        \n | __ )  ___  _ __ _ __ (_)_ __  / _| ___   \n |  _ \ / _ \| '__| '_ \| | '_ \| |_ / _ \  \n | |_) | (_) | |  | | | | | | | |  _| (_) | \n |____/ \___/|_|  |_| |_|_|_| |_|_|  \___/  \n"

dependencies=(
  "bash" "libc6" "procps" "sysstat" "net-tools"
  "hostname" "coreutils" "systemd" "lsb-release"
  "util-linux" "iproute2"
)

echo " + System Update..."
apt-get update -y > /dev/null 2>&1
apt-get upgrade -y > /dev/null 2>&1

echo " + Checking Dependencies..."
for dep in "${dependencies[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$dep" 2>/dev/null | grep -q "install ok installed"; then
        echo " + Installing $dep..."
        apt-get install -y "$dep" > /dev/null 2>&1 || {
            echo " - Failed to install $dep. Please check manually." >&2
            echo "Error during installation of $dep. Stopping the script." >&2
            exit 1
        }
    fi
done

echo " + Adding Permissions..."
chmod 755 package/DEBIAN/postinst

echo " + Building Package..."
dpkg-deb --build package > /dev/null 2>&1

echo " + Installing Package..."
dpkg -i package.deb > /dev/null 2>&1 || {
    echo " - Failed to install the package. Please check the package and dependencies." >&2
    echo "Error during package installation. Stopping the script." >&2
    exit 1
}

rm -rf package.deb
echo -e "\n * Installation Complete! 🎉\n"

allow_port() {
    local port=$1
    if [[ -z "$port" ]]; then
        echo "Usage: $0 <port_number>"
        exit 1
    fi
    
    echo "Allowing port $port in UFW..."
    ufw allow "$port" > /dev/null 2>&1
    echo "Port $port has been allowed."
}

install_services() {
    services=("ufw" "ssh" "apparmor")
    
    for service in "${services[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$service" 2>/dev/null | grep -q "install ok installed"; then
            echo "Installing missing service: $service"
            apt-get install -y "$service" > /dev/null 2>&1 || {
                echo "Failed to install $service. Please check manually." >&2
                echo "Error during installation of service $service. Stopping the script." >&2
                exit 1
            }
        fi
    done
}

check_services() {
    echo "Checking service statuses..."
    services=("apparmor" "ufw" "ssh" "ftp" "nginx" "apache2" "mysql" "postgresql")
    
    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            echo "$service: ACTIVE"
        else
            echo "$service: INACTIVE"
        fi
    done
}

echo "Checking and installing libpam-pwquality..."
if ! dpkg-query -W -f='${Status}' libpam-pwquality 2>/dev/null | grep -q "install ok installed"; then
    apt-get update -y > /dev/null 2>&1
    apt-get install -y libpam-pwquality > /dev/null 2>&1
    echo "libpam-pwquality installed."
else
    echo "libpam-pwquality is already installed."
fi

CONFIG_FILE="/etc/pam.d/common-password"
POLICY_RULE="retry=3 minlen=10 ucredit=-1 lcredit=-1 dcredit=-1 maxrepeat=3 reject_username difok=7 enforce_for_root"

echo "Configuring password policy..."
if grep -q '^password\s\+requisite\s\+pam_pwquality.so' "$CONFIG_FILE"; then
    sed -i "s/^password\s\+requisite\s\+pam_pwquality.so.*/password requisite pam_pwquality.so $POLICY_RULE/" "$CONFIG_FILE"
else
    echo "password requisite pam_pwquality.so $POLICY_RULE" >> "$CONFIG_FILE"
fi
echo "Password policy updated successfully!"

LOGIN_DEFS_FILE="/etc/login.defs"
echo "Updating password aging policy..."
sed -i 's/^PASS_MAX_DAYS\s\+[0-9]\+/PASS_MAX_DAYS 30/' "$LOGIN_DEFS_FILE"
sed -i 's/^PASS_MIN_DAYS\s\+[0-9]\+/PASS_MIN_DAYS 2/' "$LOGIN_DEFS_FILE"
echo "Password aging policy updated successfully!"

echo "Checking and applying password aging policy for existing users..."
for user in $(cut -f1 -d: /etc/passwd); do
    shadow_entry=$(grep "^$user:" /etc/shadow)
    max_days=$(echo "$shadow_entry" | cut -d: -f5)
    min_days=$(echo "$shadow_entry" | cut -d: -f6)

    if [[ "$max_days" -ne 30 || "$min_days" -ne 2 ]]; then
        echo "Updating password aging for user $user..."
        chage -M 30 -m 2 "$user"
    fi
done
echo "Password aging policy applied to existing users!"

echo "Backing up the sudoers file..."
cp /etc/sudoers /etc/sudoers.bak

DEFAULTS=(
    "Defaults	env_reset"
    "Defaults	mail_badpass"
    "Defaults	secure_path=\"/usr/local/sbin:/usr/local/bin:/usr/bin:/sbin:/bin\""
    "Defaults	badpass_message=\"Password is wrong, please try again!\""
    "Defaults	passwd_tries=3"
    "Defaults	logfile=\"/var/log/sudo/sudo.log\""
    "Defaults	log_input, log_output"
    "Defaults	requiretty"
)

echo "Opening sudoers file for editing..."
visudo -c -f /etc/sudoers

if visudo -c; then
    echo "Visudo syntax check passed. Adding defaults to sudoers..."
    
    for DEFAULT in "${DEFAULTS[@]}"; do
        if ! grep -q "$DEFAULT" /etc/sudoers; then
            echo "$DEFAULT" >> /etc/sudoers
        fi
    done
    echo "Defaults added successfully to sudoers file."
else
    echo "Syntax error in the sudoers file. Aborting!" >&2
    exit 1
fi

touch "$FLAG_FILE"
echo "Installation and configuration are completed successfully."

echo "A reboot is necessary for changes to take full effect."
read -p "Would you like to reboot now? (y/N): " response
case "$response" in
    [yY][eE][sS]|[yY])
        echo "Rebooting now..."
        reboot
        ;;
    *)
        echo "Please reboot manually later to apply changes."
        ;;
esac

# Jitsi_Suite_With_Etherpad_Install_Script_For_Debian-Ubuntu.sh

Complete Jitsi, Jigasi, Jibri, Jicofo installation script with optional Etherpad installation and integration.

Due to the increase in demand for secure video and voice communications and some of the complexities in setting services up, I have decided to script the installation process, making it easier for others to deploy.

This script will create a configuration file, which it will then use for setup. 

It will also ask the user if Jitsi is being installed behind NAT and will make and apply the appropriate configuration changes. 

It is intended to be run on Debian/Ubuntu, but can be easily modified for other systems. 

**The script ***MUST*** be downloaded to and run from the /root/ directory with sudo privileges or as root**

To run the script, use "sudo ./script-name.sh" from terminal. You may need to run "chmod +x script-name.sh" to make it executable. 

You can also copy and paste the code below into your own file, make it executable, and run it as stated above. 

Feel free to fork or modify it as per your needs!


#!/usr/bin/env bash

# This version includes the option to install Jigasi as part of the Jitsi installation.

set -e
# set -x

# Define paths as variables
JITSI_MEET_PATH="/etc/jitsi/meet/"
PROSODY_CONF_PATH="/etc/prosody/conf.avail/"

# Define log file
LOG_FILE="/var/log/jitsi_script.log"

# Define config file
CONFIG_FILE="/etc/jitsi_script.conf"

# Function to log messages
log_message() {
    local message=$1
    local level=$2
    echo "$(date): [$level] $message" >> $LOG_FILE
}

# Function to display error messages
display_error() {
    local message=$1
    echo "Error: $message" >> "$LOG_FILE"
    echo "Error: $message"
    exit 1
}

# Function to check if a command succeeded
check_command() {
    if [[ $? -ne 0 ]]; then
        display_error "Command failed: $BASH_COMMAND"
    fi
}

# Function to check if a file exists
check_file() {
    local file=$1
    if [[ ! -f $file ]]; then
        display_error "File not found: $file"
    fi
}

# Function to check if a directory exists
check_directory() {
    local directory=$1
    if [[ ! -d $directory ]]; then
        display_error "Directory not found: $directory"
    fi
}

# Function to install a package and check if it was installed successfully
install_package() {
    local package=$1
    sudo apt install "$package" -y
    check_command
}

# Function to start a service and check if it started successfully
start_service() {
    local service=$1
    if ! systemctl is-enabled --quiet "$service"; then
        sudo systemctl start "$service"
        check_command
    else
        log_message "Service $service is already running. Skipping start." "INFO"
    fi
}

# Function to restart a service and check if it restarted successfully
restart_service() {
    local service=$1
    if systemctl is-enabled --quiet "$service"; then
        sudo systemctl restart "$service"
        check_command
    else
        log_message "Service $service is not running. Skipping restart." "INFO"
    fi
}

# Function to download a file and check if it was downloaded successfully
download_file() {
    local url=$1
    local file=$2
    wget "$url" -O "$file"
    check_command
    check_file "$file"
}

# Function to append a line to a file
append_to_file() {
    local line=$1
    local file=$2
    echo "$line" | sudo tee -a "$file" > /dev/null
    check_command
}

# Function to replace a placeholder in a file
replace_placeholder() {
    local placeholder=$1
    local replacement=$2
    local file=$3
    # Use a different delimiter for sed, e.g., #
    sudo sed -i "s#$placeholder#$replacement#g" "$file"
    check_command
}

# Function to clone a git repository and check if it was cloned successfully
clone_repo() {
    local url=$1
    local directory=$2
    git clone "$url" "$directory"
    check_command
    check_directory "$directory"
}

# Function to run a command and check if it ran successfully
run_command() {
    local command=$1
    $command
    check_command
}

# Function to secure MariaDB installation
secure_mariadb() {
    log_message "Securing MariaDB installation..." "INFO"
    sudo mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$root_password';"
    sudo mysql -e "DELETE FROM mysql.user WHERE User='';"
    sudo mysql -e "FLUSH PRIVILEGES;"
    sudo mysql_secure_installation
    check_command
}

# Function to install Jitsi Meet and Jigasi
install_jitsi() {
    log_message "Installing Jitsi Meet and Jigasi..." "INFO"
    sudo apt update
    sudo apt install apt-transport-https
    sudo wget -qO - https://download.jitsi.org/jitsi-key.gpg.key | sudo apt-key add -
    echo 'deb https://download.jitsi.org stable/' | sudo tee /etc/apt/sources.list.d/jitsi-stable.list
    sudo apt update
    sudo apt -y install jitsi-meet jigasi
    sudo /usr/share/jitsi-meet/scripts/install-letsencrypt-cert.sh
    configure_jitsi_nat $public_ip $local_ip
}

# Function to configure Jitsi Meet behind NAT
configure_jitsi_nat() {
    log_message "Configuring Jitsi Meet for NAT..." "INFO"
    replace_placeholder "org.ice4j.ice.harvest.NAT_HARVESTER_LOCAL_ADDRESS=" "org.ice4j.ice.harvest.NAT_HARVESTER_LOCAL_ADDRESS=$local_ip" /etc/jitsi/videobridge/sip-communicator.properties
    replace_placeholder "org.ice4j.ice.harvest.NAT_HARVESTER_PUBLIC_ADDRESS=" "org.ice4j.ice.harvest.NAT_HARVESTER_PUBLIC_ADDRESS=$public_ip" /etc/jitsi/videobridge/sip-communicator.properties
    restart_service "jitsi-videobridge2"
}

# Function to install Jibri
install_jibri() {
    log_message "Installing Jibri..." "INFO"
    install_package "jibri"
}

# Function to install Etherpad
install_etherpad() {
    log_message "Installing Etherpad..." "INFO"
    install_package "nodejs"
    install_package "git"
    # Create Etherpad user and clone Etherpad repository
    create_user_and_clone_repo "etherpad" "https://github.com/ether/etherpad-lite.git" "etherpad-lite"
    run_command "etherpad-lite/bin/run.sh &"
}

# Function to uninstall Jitsi
uninstall_jitsi() {
    log_message "Uninstalling Jitsi..." "INFO"
    sudo apt purge jitsi-meet jigasi -y
    sudo apt autoremove -y
    check_command
}

# Function to uninstall Jibri
uninstall_jibri() {
    log_message "Uninstalling Jibri..." "INFO"
    sudo apt purge jibri -y
    sudo apt autoremove -y
    check_command
}

# Function to uninstall Etherpad
uninstall_etherpad() {
    log_message "Uninstalling Etherpad..." "INFO"
    sudo apt purge nodejs -y
    sudo apt purge git -y
    sudo rm -rf /usr/local/lib/node_modules
    sudo rm -rf /usr/local/bin/node
    sudo rm -rf /usr/local/share/man/man1/node.1
    sudo rm -rf /usr/local/lib/dtrace/node.d
    sudo rm -rf ~/.npm
    sudo rm -rf ~/.node-gyp
    sudo rm -rf /opt/local/bin/node
    sudo rm -rf /opt/local/include/node
    sudo rm -rf /opt/local/lib/node_modules
    sudo apt autoremove -y
    check_command
}

# Function to reinstall a service
reinstall_service() {
    local service=$1
    case $service in
        "jitsi") uninstall_jitsi; install_jitsi;;
        "jibri") uninstall_jibri; install_jibri;;
        "etherpad") uninstall_etherpad; install_etherpad;;
        *) echo "Invalid service. Please try again.";;
    esac
}

# Function to read configuration file
read_config_file() {
    local config_file=$1
    if [[ -f $config_file ]]; then
        source $config_file
    else
        display_error "Configuration file not found: $config_file"
    fi
}

# Function to create configuration file
create_config_file() {
    echo "Creating configuration file..."
    if [[ -f $config_file ]]; then
        read -p "Configuration file already exists. Do you want to overwrite it? (y/n): " overwrite
        if [[ $overwrite != "y" ]]; then
            echo "Aborting configuration file creation."
            return
        fi
    fi
    read -p "Enter local IP address: " local_ip
    if [[ ! $local_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        display_error "Invalid local IP address: $local_ip"
    fi
    read -p "Enter public IP address: " public_ip
    if [[ ! $public_ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        display_error "Invalid public IP address: $public_ip"
    fi
    read -p "Enter Fully Qualified Domain Name (FQDN): " fqdn
    if [[ -z $fqdn ]]; then
        display_error "FQDN cannot be empty."
    fi
    read -sp "Enter root password: " root_password
    echo "local_ip=\"$local_ip\"" > "$config_file"
    echo "public_ip=\"$public_ip\"" >> "$config_file"
    echo "fqdn=\"$fqdn\"" >> "$config_file"
    echo "root_password=\"$root_password\"" >> "$config_file"
    echo "Configuration file created at $config_file"
}

# Function to display menu
display_menu() {
    echo "1. Create configuration file"
    echo "2. Install Jitsi"
    echo "3. Install Jibri"
    echo "4. Install Etherpad"
    echo "5. Uninstall Jitsi"
    echo "6. Uninstall Jibri"
    echo "7. Uninstall Etherpad"
    echo "8. Reinstall Jitsi"
    echo "9. Reinstall Jibri"
    echo "10. Reinstall Etherpad"
    echo "11. Exit"
    local valid_options=("1" "2" "3" "4" "5" "6" "7" "8" "9" "10" "11")
    while true; do
        read -p "Please select an option: " menu_option
        if [[ ! " ${valid_options[@]} " =~ " ${menu_option} " ]]; then
            echo "Invalid option. Please try again."
        else
            break
        fi
    done
}

# Main function
main() {
    # Get the current date and time
    start_time=$(date)
    # Print the start time
    log_message "Script started at: $start_time" "INFO"

    local config_file="/root/jitsi_configuration"
    if [[ ! -f $config_file ]]; then
        create_config_file $config_file
    fi
    read_config_file $config_file

    # Update System
    log_message "Updating system..." "INFO"
    sudo apt update
    check_command
    sudo apt upgrade -y
    check_command

    # Display menu
    local menu_option
    while true; do
        display_menu
        case $menu_option in
            1) create_config_file;;
            2) read_config_file $CONFIG_FILE; install_jitsi;;
            3) read_config_file $CONFIG_FILE; install_jibri;;
            4) read_config_file $CONFIG_FILE; install_etherpad;;
            5) read_config_file $CONFIG_FILE; uninstall_jitsi;;
            6) read_config_file $CONFIG_FILE; uninstall_jibri;;
            7) read_config_file $CONFIG_FILE; uninstall_etherpad;;
            8) read_config_file $CONFIG_FILE; reinstall_service "jitsi";;
            9) read_config_file $CONFIG_FILE; reinstall_service "jibri";;
            10) read_config_file $CONFIG_FILE; reinstall_service "etherpad";;
            11) break;;
            *) echo "Invalid option. Please try again.";;
        esac
    done

    # Get the current date and time
    end_time=$(date)
    # Print the end time
    log_message "Script ended at: $end_time" "INFO"
}

# Run the main function
main

#!/bin/bash

set -eo pipefail

# Function to display usage
usage() {
    echo "Usage: $0 --backup-location <path> --plan-name <plan_name> --docker-image <image>"
    exit 1
}

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function to handle errors
handle_error() {
    log "Error occurred in function '$1' on line $2"
    exit 1
}

trap 'handle_error "${FUNCNAME[-1]}" "$LINENO"' ERR

# Function to install required packages
install_dependencies() {
    log "Installing dependencies..."
    if [ -f /etc/debian_version ]; then
        sudo apt-get update && sudo apt-get install -y tar unzip jq mysql-client wget curl
    elif [ -f /etc/redhat-release ]; then
        sudo yum install -y epel-release tar unzip jq mysql wget curl
    elif [ -f /etc/almalinux-release ]; then
        sudo dnf install -y tar unzip jq mysql wget curl
    else
        log "Unsupported OS. Please install tar, unzip, jq, mysql-client, wget, and curl manually."
        exit 1
    fi
    log "Dependencies installed successfully."
}

# Function to identify and extract the cPanel backup
extract_cpanel_backup() {
    local backup_location="$1"
    local backup_dir="$2"
    log "Identifying and extracting backup from $backup_location to $backup_dir"
    mkdir -p "$backup_dir"

    # Identify the backup type
    local backup_filename=$(basename "$backup_location")
    local extraction_command=""

    case "$backup_filename" in
        cpmove-*.tar.gz)
            log "Identified cpmove backup"
            extraction_command="tar -xzf"
            ;;
        backup-*.tar.gz)
            log "Identified full or partial cPanel backup"
            extraction_command="tar -xzf"
            ;;
        *.tar.gz)
            log "Identified gzipped tar backup"
            extraction_command="tar -xzf"
            ;;
        *.tgz)
            log "Identified tgz backup"
            extraction_command="tar -xzf"
            ;;
        *.tar)
            log "Identified tar backup"
            extraction_command="tar -xf"
            ;;
        *.zip)
            log "Identified zip backup"
            extraction_command="unzip"
            ;;
        *)
            log "Unrecognized backup format: $backup_filename"
            exit 1
            ;;
    esac

    # Extract the backup
    if [ "$extraction_command" = "unzip" ]; then
        $extraction_command "$backup_location" -d "$backup_dir"
    else
        $extraction_command "$backup_location" -C "$backup_dir"
    fi

    log "Backup extracted successfully."

    # Handle nested archives (common in some cPanel backups)
    for nested_archive in "$backup_dir"/*.tar.gz "$backup_dir"/*.tgz; do
        if [ -f "$nested_archive" ]; then
            log "Found nested archive: $nested_archive"
            tar -xzf "$nested_archive" -C "$backup_dir"
            rm "$nested_archive"  # Remove the nested archive after extraction
        fi
    done

    # List contents of extracted backup for debugging
    log "Contents of extracted backup:"
    find "$backup_dir" -type f | sed 's/^/  /'
}

# Function to locate important directories in the extracted backup
locate_backup_directories() {
    local backup_dir="$1"
    log "Locating important directories in the extracted backup"

    # Try to locate the key directories
    homedir=$(find "$backup_dir" -type d -name "homedir" | head -n 1)
    if [ -z "$homedir" ]; then
        homedir=$(find "$backup_dir" -type d -name "public_html" -printf '%h\n' | head -n 1)
    fi
    if [ -z "$homedir" ]; then
        log "Unable to locate home directory in the backup"
        exit 1
    fi

    mysqldir=$(find "$backup_dir" -type d -name "mysql" | head -n 1)
    if [ -z "$mysqldir" ]; then
        log "Unable to locate MySQL directory in the backup"
        exit 1
    fi

    log "Backup directories located successfully"
    log "Home directory: $homedir"
    log "MySQL directory: $mysqldir"
}

# Function to parse cPanel backup metadata
parse_cpanel_metadata() {
    local backup_dir="$1"
    local plan_name="$2"
    log "Parsing cPanel metadata..."

    local metadata_file="$backup_dir/userdata/main"

    if [ -f "$metadata_file" ]; then
        log "Metadata file found: $metadata_file"
        cpanel_username=$(grep -oP 'user: \K\S+' "$metadata_file" | tr -d '\r')
        cpanel_email=$(grep -oP 'email: \K\S+' "$metadata_file" | tr -d '\r')
        main_domain=$(grep -oP 'main_domain: \K\S+' "$metadata_file" | tr -d '\r')
        php_version=$(grep -oP 'phpversion: \K\S+' "$metadata_file" | tr -d '\r')
        
        if [ -z "$php_version" ]; then
            php_version=$(grep -oP 'php_version: \K\S+' "$metadata_file" | tr -d '\r')
        fi

        if [ -z "$cpanel_username" ] || [ -z "$cpanel_email" ] || [ -z "$main_domain" ] || [ -z "$php_version" ]; then
            log "Some metadata is missing. Prompting for manual input."
            [ -z "$cpanel_username" ] && read -p "Enter cPanel username: " cpanel_username
            [ -z "$cpanel_email" ] && read -p "Enter cPanel email: " cpanel_email
            [ -z "$main_domain" ] && read -p "Enter main domain: " main_domain
            [ -z "$php_version" ] && read -p "Enter PHP version (e.g., php8.1): " php_version
        fi
    else
        log "Unable to locate metadata file. Prompting for manual input."
        read -p "Enter cPanel username: " cpanel_username
        read -p "Enter cPanel email: " cpanel_email
        read -p "Enter main domain: " main_domain
        read -p "Enter PHP version (e.g., php8.1): " php_version
    fi

    log "cPanel metadata parsed successfully."
    log "Username: $cpanel_username"
    log "Email: $cpanel_email"
    log "Main Domain: $main_domain"
    log "PHP Version: $php_version"
    log "Plan Name: $plan_name"
}

# Function to create or check and get an existing plan
create_or_get_plan() {
    local plan_name="$1"
    local plan_description="$2"
    local plan_domains="${3:-unlimited}"
    local plan_websites="${4:-unlimited}"
    local plan_disk="${5:-unlimited}"
    local plan_inodes="${6:-unlimited}"
    local plan_databases="${7:-unlimited}"
    local plan_cpu="${8:-100}"
    local plan_ram="${9:-1024}"
    local docker_image="${10}"
    local plan_bandwidth="${11:-unlimited}"

    log "Creating or getting plan: $plan_name"
    local existing_plan=$(opencli plan-list --json | jq -r ".[] | select(.name == \"$plan_name\") | .id")
    if [ -z "$existing_plan" ]; then
        opencli plan-create "$plan_name" "$plan_description" "$plan_domains" "$plan_websites" \
                             "$plan_disk" "$plan_inodes" "$plan_databases" "$plan_cpu" "$plan_ram" \
                             "$docker_image" "$plan_bandwidth"
    else
        log "Plan $plan_name already exists, using the existing plan."
    fi
}

# Function to create or get user
create_or_get_user() {
    local username="$1"
    local password="$2"
    local email="$3"
    local plan_name="$4"

    log "Creating or getting user: $username"
    local existing_user=$(opencli user-list --json | jq -r ".[] | select(.username == \"$username\") | .id")
    if [ -z "$existing_user" ]; then
        opencli user-add "$username" "$password" "$email" "$plan_name"
    else
        log "User $username already exists."
    fi
}

# Function to restore PHP version
restore_php_version() {
    local username="$1"
    local php_version="$2"

    log "Restoring PHP version $php_version for user $username"
    local current_version=$(opencli php-default_php_version "$username")
    if [ "$current_version" != "$php_version" ]; then
        local installed_versions=$(opencli php-enabled_php_versions "$username")
        if ! echo "$installed_versions" | grep -q "$php_version"; then
            opencli php-install_php_version "$username" "$php_version"
        fi
        opencli php-enabled_php_versions --update "$username" "$php_version"
    fi
}

# Function to restore domains
restore_domains() {
    local username="$1"
    local domain="$2"
    local path="$3"

    log "Restoring domain $domain for user $username"
    local domain_owner=$(opencli domains-whoowns "$domain")
    if [ -z "$domain_owner" ]; then
        opencli domains-add "$domain" "$username" "$path"
    else
        log "Domain $domain already exists and is owned by $domain_owner"
    fi
}

# Function to restore MySQL databases and users
restore_mysql() {
    local username="$1"
    local password="$2"
    local mysql_dir="$3"

    log "Restoring MySQL databases for user $username"
    if [ -d "$mysql_dir" ]; then
        for db_file in "$mysql_dir"/*.sql; do
            local db_name=$(basename "$db_file" .sql)
            log "Restoring database: $db_name"
            opencli db create "$db_name" "$username" "$password"
            mysql -u "$username" -p"$password" "$db_name" < "$db_file"
        done
    else
        log "No MySQL databases found to restore"
    fi
}

# Function to restore emails
restore_emails() {
    local username="$1"
    local backup_dir="$2"

    log "Restoring emails for user $username"
    if [ -d "$backup_dir/mail" ]; then
        cp -r "$backup_dir/mail" "/home/$username/mail"
        opencli files-fix_permissions "$username" "/home/$username/mail"
    else
        log "No email data found to restore"
    fi
}

# Function to restore SSL certificates
restore_ssl() {
    local username="$1"
    local backup_dir="$2"

    log "Restoring SSL certificates for user $username"
    if [ -d "$backup_dir/ssl" ]; then
        for cert_file in "$backup_dir/ssl"/*.crt; do
            local domain=$(basename "$cert_file" .crt)
            local key_file="$backup_dir/ssl/$domain.key"
            if [ -f "$key_file" ]; then
                log "Installing SSL certificate for domain: $domain"
                opencli ssl install --domain "$domain" --cert "$cert_file" --key "$key_file"
            else
                log "SSL key file not found for domain: $domain"
            fi
        done
    else
        log "No SSL certificates found to restore"
    fi
}

# Function to restore SSH access
restore_ssh() {
    local username="$1"
    local backup_dir="$2"

    log "Restoring SSH access for user $username"
    local shell_access=$(grep -oP 'shell: \K\S+' "$backup_dir/userdata/main")
    if [ "$shell_access" == "/bin/bash" ]; then
        opencli user-ssh enable "$username"
        if [ -f "$backup_dir/.ssh/id_rsa.pub" ]; then
            mkdir -p "/home/$username/.ssh"
            cp "$backup_dir/.ssh/id_rsa.pub" "/home/$username/.ssh/authorized_keys"
            chown -R "$username:$username" "/home/$username/.ssh"
        fi
    fi
}

# Function to restore DNS zones
restore_dns_zones() {
    local username="$1"
    local backup_dir="$2"

    log "Restoring DNS zones for user $username"
    if [ -d "$backup_dir/dnszones" ]; then
        for zone_file in "$backup_dir/dnszones"/*; do
            local zone_name=$(basename "$zone_file")
            log "Importing DNS zone: $zone_name"
            opencli dns-import-zone "$zone_file"
        done
    else
        log "No DNS zones found to restore"
    fi
}

# Function to restore files
restore_files() {
    local backup_dir="$1"
    local username="$2"
    local domain="$3"

    log "Restoring files for user $username and domain $domain"
    cp -r "$backup_dir/homedir" "/home/$username/$domain/"
    opencli files-fix_permissions "$username" "/home/$username/$domain"
}

# Function to restore WordPress sites
restore_wordpress() {
    local backup_dir="$1"
    local username="$2"

    log "Restoring WordPress sites for user $username"
    if [ -d "$backup_dir/wptoolkit" ]; then
        for wp_file in "$backup_dir/wptoolkit"/*.json; do
            log "Importing WordPress site from: $wp_file"
            opencli wp-import "$username" "$wp_file"
        done
    else
        log "No WordPress data found to restore"
    fi
}

# Function to restore cron jobs
restore_cron() {
    local backup_dir="$1"
    local username="$2"

    log "Restoring cron jobs for user $username"
    if [ -f "$backup_dir/cron/crontab" ]; then
        crontab -u "$username" "$backup_dir/cron/crontab"
    else
        log "No cron jobs found to restore"
    fi
}

# Main execution
main() {
    local backup_location=""
    local plan_name=""
    local docker_image=""

    # Parse command-line arguments
    while [ "$1" != "" ]; do
        case $1 in
            --backup-location ) shift
                                backup_location=$1
                                ;;
            --plan-name )       shift
                                plan_name=$1
                                ;;
            --docker-image )    shift
                                docker_image=$1
                                ;;
            * )                 usage
        esac
        shift
    done

    # Validate required parameters
    if [ -z "$backup_location" ] || [ -z "$plan_name" ] || [ -z "$docker_image" ]; then
        usage
    fi

    # Ensure the script is run with superuser privileges
    if [[ $EUID -ne 0 ]]; then
        log "This script must be run as root or with sudo privileges"
        exit 1
    fi

    # Install required packages
    install_dependencies

    # Create a unique temporary directory
    backup_dir=$(mktemp -d /tmp/cpanel_import_XXXXXX)
    log "Created temporary directory: $backup_dir"

    # Extract backup
    extract_cpanel_backup "$backup_location" "$backup_dir"

    # Locate important directories
    locate_backup_directories "$backup_dir

# shellcheck shell=bash
# cp-import.sh step: cron jobs, sourced by cp-import.sh

# ======================================================================
# CRONJOB
restore_cron() {
    log "Restoring cron jobs"
    
    dry_run "Would restore cron jobs for user $cpanel_username" && return

    if [ -f "$real_backup_files_path/cron/$cpanel_username" ]; then
        ofelia_cron_path="/home/${cpanel_username}/crons.ini"
        > "$ofelia_cron_path"

        # PHP jobs run in the account's own PHP container, cPanel's version names (ea-php81, native) don't exist here
        local default_php php_container
        default_php=$(grep -E '^DEFAULT_PHP_VERSION=' "/home/$cpanel_username/.env" | cut -d= -f2 | tr -d '"[:space:]')
        php_container="php-fpm-${default_php#php}"

        job_index=1
        job_found=false
        local active_found=false
        while IFS= read -r cron_line; do
            [[ -z "${cron_line//[[:space:]]/}" || "$cron_line" =~ ^[[:space:]]*# ]] && continue
            # crontab settings like MAILTO= or SHELL= aren't jobs
            [[ "$cron_line" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*= ]] && continue

            # ofelia reads a seconds field first, so a plain "*" there would run the job every second of its minute
            if [[ "$cron_line" =~ ^[[:space:]]*@ ]]; then
                schedule=$(awk '{print $1}' <<< "$cron_line")
                command=$(sed -E 's/^[[:space:]]*[^[:space:]]+[[:space:]]+//' <<< "$cron_line")
                if [ "$schedule" = "@reboot" ]; then
                    log "Skipping @reboot cron job, the cron service can't run it: $command"
                    continue
                fi
            else
                schedule="0 $(awk '{print $1, $2, $3, $4, $5}' <<< "$cron_line")"
                command=$(sed -E 's/^[[:space:]]*([^[:space:]]+[[:space:]]+){5}//' <<< "$cron_line")
            fi
            job_found=true

            if [[ "$command" == *mysql* || "$command" == *mariadb* ]]; then
                container_name="$mysql_type"
                comment_prefix=""
            elif [[ "$command" == *php* ]]; then
                container_name="$php_container"
                comment_prefix=""
            else
                # anything else comes in disabled, the same way OpenPanel saves a disabled job, so it can be checked and turned on there
                container_name="$php_container"
                comment_prefix="#"
                log "Imported cron job as disabled, check it and enable it in OpenPanel: $command"
            fi
            [ -z "$comment_prefix" ] && active_found=true

            {
                echo "${comment_prefix}[job-exec \"${cpanel_username}_job_$job_index\"]"
                echo "${comment_prefix}schedule = $schedule"
                echo "${comment_prefix}container = $container_name"
                echo "${comment_prefix}command = $command"
                echo
            } >> "$ofelia_cron_path"

            ((job_index++))
        done < "$real_backup_files_path/cron/$cpanel_username"

        if [ "$job_found" = true ] && [ "$active_found" = false ]; then
            log "Converted crontab to Ofelia config at: $ofelia_cron_path, all jobs disabled so the cron service isn't started"
        elif [ "$job_found" = true ]; then
            log "Converted crontab to Ofelia config at: $ofelia_cron_path"
            log "Starting Cron service"
            output=$(cd /home/$cpanel_username && CONTAINER_HOST=unix:///hostfs/run/user/$(id -u $cpanel_username)/podman/podman.sock podman-compose up -d cron >/dev/null 2>&1)           
            while IFS= read -r line; do
                log "$line"
            done <<< "$output"
        else
            log "No cron jobs found in file, not starting cron service"
            rm -f "$ofelia_cron_path"
        fi

    else
        log "No cron jobs found to restore"
    fi
}

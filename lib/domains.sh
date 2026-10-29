# shellcheck shell=bash
# cp-import.sh step: domains, DNS zones, SSL certificates and WordPress sites, sourced by cp-import.sh

# ======================================================================
# SSL CERTIFICATES
restore_ssl() {
    local username="$1"

    dry_run "Would restore SSL certificates for user $username" && return

    log "Restoring SSL certificates"
    # cPanel keeps each installed certificate in apache_tls/<domain>: the key, the certificate and its CA chain in one file
    local tls_dir="$real_backup_files_path/apache_tls"
    if [ ! -d "$tls_dir" ]; then
        log "No SSL certificates found to restore"
        return
    fi

    local data_dir="/home/$username/docker-data/volumes/${username}_html_data/_data"
    local pem domain cert_file key_file issuer subject name output installed=0
    for pem in "$tls_dir"/*; do
        [ -f "$pem" ] || continue
        domain=$(basename "$pem")
        if [[ "$domain" == *.cpanel.site ]]; then
            log "Skipping cPanel temporary domain: $domain"
            continue
        fi
        if [ "$(opencli domains-whoowns "$domain" 2>/dev/null | awk -F': ' '{print $2}')" != "$username" ]; then
            log "Skipping SSL for $domain: the domain wasn't added to this account"
            continue
        fi

        cert_file=$(mktemp)
        key_file=$(mktemp)
        awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' "$pem" > "$cert_file"
        awk '/-----BEGIN [A-Z ]*PRIVATE KEY-----/,/-----END [A-Z ]*PRIVATE KEY-----/' "$pem" > "$key_file"
        issuer=$(openssl x509 -in "$cert_file" -noout -issuer 2>/dev/null)
        subject=$(openssl x509 -in "$cert_file" -noout -subject 2>/dev/null)

        # Caddy issues its own certificates, so only bring over ones it can't replace: valid, not self-signed, not from an automatic CA
        if [ ! -s "$key_file" ] || [ -z "$issuer" ]; then
            log "Skipping SSL for $domain: no certificate and key found in apache_tls/$domain"
        elif ! openssl x509 -in "$cert_file" -noout -checkend 0 >/dev/null 2>&1; then
            log "Skipping SSL for $domain: the certificate has expired, a new one will be issued automatically"
        elif [ "${issuer#issuer=}" = "${subject#subject=}" ]; then
            log "Skipping SSL for $domain: self-signed certificate, a new one will be issued automatically"
        elif echo "$issuer" | grep -qiE "cPanel|Let'?s Encrypt|ZeroSSL"; then
            log "Skipping SSL for $domain: AutoSSL certificate (${issuer#issuer=}), a new one will be issued automatically"
        else
            # domains-ssl only reads the files from the account's /var/www/html/
            name=".cpanel-import-ssl-$domain"
            install -m 600 -o "$username" -g "$username" "$cert_file" "$data_dir/$name.crt"
            install -m 600 -o "$username" -g "$username" "$key_file" "$data_dir/$name.key"
            log "Installing custom SSL certificate for $domain (${issuer#issuer=})"
            output=$(opencli domains-ssl "$domain" custom "/var/www/html/$name.crt" "/var/www/html/$name.key" 2>&1)
            while IFS= read -r line; do
                log "$line"
            done <<< "$output"
            rm -f "$data_dir/$name.crt" "$data_dir/$name.key"
            installed=$((installed + 1))
        fi
        rm -f "$cert_file" "$key_file"
    done

    log "Installed $installed custom SSL certificate(s)"
}

# ======================================================================
# ACCESS LOGS
# OpenPanel's access logs are Caddy's own, so cPanel's Apache domlogs are kept as files next to the monthly archives cPanel leaves in logs/
restore_domlogs() {
    local username="$1"

    dry_run "Would save cPanel access logs to logs/cpanel-domlogs/ in the account's files" && return

    local src="$real_backup_files_path/logs"
    local logs_dir="/home/$username/docker-data/volumes/${username}_html_data/_data/logs"
    local log_file copied=0
    for log_file in "$src"/*; do
        if [ ! -f "$log_file" ] || [ ! -s "$log_file" ]; then
            continue
        fi
        # bytes_log is cPanel's bandwidth counter, not an access log
        [[ "$log_file" == *-bytes_log ]] && continue
        mkdir -p "$logs_dir/cpanel-domlogs"
        gzip -c "$log_file" > "$logs_dir/cpanel-domlogs/$(basename "$log_file").gz"
        copied=$((copied + 1))
    done

    if [ "$copied" -eq 0 ]; then
        log "No access logs found to restore"
        return
    fi
    chown "$username:$username" "$logs_dir"
    chown -R "$username:$username" "$logs_dir/cpanel-domlogs"
    log "Saved $copied cPanel access log(s) to logs/cpanel-domlogs/ in the account's files"
}

# ======================================================================
# DNS ZONES
# prints OpenPanel's SOA and apex NS, every other record from the cPanel zone, then OpenPanel's defaults only for names cPanel has nothing for
merge_dns_zone() {
    local zone="${1%.}." cpanel_zone="$2" openpanel_zone="$3"
    awk -v zone="$zone" '
        function fqdn(name) {
            name = tolower(name)
            if (name == "@") return origin
            if (name ~ /\.$/) return name
            return name "." origin
        }
        function rrtype(text,    tokens, n, i, t) {
            n = split(text, tokens, /[ \t\n()]+/)
            for (i = 1; i <= n; i++) {
                t = toupper(tokens[i])
                if (t ~ /^(A|AAAA|CAA|CNAME|DNAME|DS|HINFO|MX|NAPTR|NS|PTR|SOA|SPF|SRV|SSHFP|TLSA|TXT)$/) return t
            }
            return ""
        }
        FNR == 1 { file++; origin = tolower(zone); owner = origin; depth = 0 }
        {
            line = $0
            # parens and ; only count outside quoted strings
            bare = line
            gsub(/"([^"\\]|\\.)*"/, "\"\"", bare)
            sub(/;.*/, "", bare)
            if (depth == 0) {
                if (bare ~ /^[ \t]*$/) next
                if (bare ~ /^\$/) {
                    split(bare, d, /[ \t]+/)
                    if (toupper(d[1]) == "$TTL") ttl[file] = "$TTL " d[2]
                    if (toupper(d[1]) == "$ORIGIN") origin = fqdn(d[2])
                    next
                }
                rec = line; rest = bare
                if (line ~ /^[ \t]/) {
                    blank_owner = 1
                } else {
                    blank_owner = 0
                    match(bare, /^[^ \t]+/)
                    owner = fqdn(substr(bare, 1, RLENGTH))
                    rest = substr(bare, RLENGTH + 1)
                }
            } else {
                rec = rec "\n" line; rest = rest "\n" bare
            }
            depth += gsub(/\(/, "(", bare) - gsub(/\)/, ")", bare)
            if (depth > 0) next
            depth = 0
            # every record gets its full owner name, so dropping one never hands its owner to the next
            if (blank_owner) rec = owner rec
            else { match(rec, /^[^ \t]+/); rec = owner substr(rec, RLENGTH + 1) }
            i = ++count[file]
            text[file, i] = rec; own[file, i] = owner; type[file, i] = rrtype(rest)
        }
        END {
            apex = tolower(zone)
            print (ttl[2] != "" ? ttl[2] : "$TTL 14400")
            for (i = 1; i <= count[2]; i++)
                if (type[2, i] == "SOA" || (type[2, i] == "NS" && own[2, i] == apex)) print text[2, i]
            print ""
            print "$ORIGIN " apex
            if (ttl[1] != "") print ttl[1]
            for (i = 1; i <= count[1]; i++) {
                if (type[1, i] == "SOA" || (type[1, i] == "NS" && own[1, i] == apex)) continue
                print text[1, i]
                has[own[1, i]] = 1
            }
            print ""
            if (ttl[2] != "") print ttl[2]
            for (i = 1; i <= count[2]; i++) {
                if (type[2, i] == "SOA" || (type[2, i] == "NS" && own[2, i] == apex)) continue
                if (own[2, i] in has) continue
                print text[2, i]
            }
        }
    ' "$cpanel_zone" "$openpanel_zone"
}

restore_dns_zones() {
    log "Restoring DNS zones"

    dry_run "Would restore DNS zones for user $cpanel_username" && return

    if [ -d "$real_backup_files_path/dnszones" ]; then
        for zone_file in "$real_backup_files_path/dnszones"/*; do
            local zone_name=$(basename "${zone_file%.db}")
			
			if [[ "$zone_name" == *.cpanel.site ]]; then
			    log "Skipping cPanel temporary domain: $zone_name"
			    continue
            fi

            if [ ! -f "/etc/bind/zones/${zone_name}.zone" ]; then
                log "DNS zone file /etc/bind/zones/${zone_name}.zone does not exist. Skipping import for $zone_name."
                continue
			fi

            old_ip=$(grep -oP 'IP=\K[0-9.]+' ${real_backup_files_path}/cp/$cpanel_username)
            if [ -z "$old_ip" ]; then
                log "WARNING: old server ip address not detected in file ${real_backup_files_path}/cp/$cpanel_username - records will not be automatically updated to new ip address."
            else
                # whole addresses only, so an old IP like 1.2.3.4 doesn't also rewrite 1.2.3.45
                sed -i -E "s/(^|[^0-9.])${old_ip//./\\.}([^0-9.]|$)/\1${new_ip}\2/g" "$zone_file"
            fi

            local live_zone="/etc/bind/zones/${zone_name}.zone"
            local merged_zone="${live_zone}.import"
            merge_dns_zone "$zone_name" "$zone_file" "$live_zone" > "$merged_zone"

            # bind refuses a whole zone over one bad record, so only install what it accepts and keep OpenPanel's zone otherwise
            local check_output check_status
            check_output=$(podman exec openpanel_dns named-checkzone "$zone_name" "$merged_zone" 2>&1)
            check_status=$?
            if [ "$check_status" -eq 1 ]; then
                log "WARNING: imported DNS zone for $zone_name doesn't load in BIND ($(echo "$check_output" | head -1)), keeping OpenPanel's default zone"
                rm -f "$merged_zone"
                continue
            elif [ "$check_status" -ne 0 ]; then
                log "WARNING: couldn't check the imported DNS zone for $zone_name, the DNS service isn't running"
            fi
            # write into the existing file so it keeps the owner and mode BIND reads it with
            cat "$merged_zone" > "$live_zone"
            rm -f "$merged_zone"

            opencli domains-update_ns ${zone_name} >/dev/null 2>&1
            log "DNS zone file for $zone_name has been imported."
        done
    else
        log "No DNS zones found to restore"
    fi
}

# ======================================================================
# WORDPRESS SITES
restore_wordpress() {
    local real_backup_files_path="$1"
    local username="$2"

    dry_run "Would restore WordPress sites for user $username" && return

    log "Checking user files for WordPress installations to add to Site Manager interface.."
    output=$(opencli websites-scan $cpanel_username)
        while IFS= read -r line; do
            log "$line"
        done <<< "$output"    
}

# ======================================================================
# DOMAINS
restore_domains() {
    if [ -f "$real_backup_files_path/userdata/main" ]; then
        file_path="$real_backup_files_path/userdata/main"
        main_domain=""
        parked_domains=""
        sub_domains=""
        addon_domains=""

		parked_domains_section=false
		sub_domains_section=false
		addon_domains_section=false


        while IFS= read -r line; do
            if [[ "$line" =~ ^main_domain: ]]; then
                main_domain=$(echo "$line" | awk '{print $2}')
			elif [[ "$line" =~ ^parked_domains: ]]; then
			    parked_domains_section=true
			    sub_domains_section=false
			    addon_domains_section=false
			    continue
			elif [[ "$line" =~ ^sub_domains: ]]; then
			    sub_domains_section=true
			    parked_domains_section=false
			    addon_domains_section=false
			    continue
			elif [[ "$line" =~ ^addon_domains: ]]; then
			    addon_domains_section=true
			    parked_domains_section=false
			    sub_domains_section=false
			    continue
            fi

            if [[ "$sub_domains_section" == true ]]; then
                if [[ "$line" =~ ^[[:space:]]+- ]]; then
                    sub_domains+=$(echo "$line" | awk '{print $2}')$'\n'
                else
                    sub_domains_section=false
                fi
            fi

            if [[ "$parked_domains_section" == true ]]; then
                if [[ "$line" =~ ^[[:space:]]+- ]]; then
                    parked_domains+=$(echo "$line" | awk '{print $2}')$'\n'
                else
                    parked_domains_section=false
                fi
            fi

            if [[ "$addon_domains_section" == true ]]; then
                if [[ "$line" =~ ^[[:space:]]*[^:]+:[[:space:]]*[^[:space:]]+$ ]]; then
                    domain=$(echo "$line" | awk -F: '{print $1}' | tr -d '[:space:]')
                    if [[ -n "$domain" && "$domain" != "main_domain" && "$domain" != "parked_domains" ]]; then
                        addon_domains+="$domain"$'\n'
                    fi
                else
                    addon_domains_section=false
                fi
            fi
        done < "$file_path"

        sub_domains_array=()
        addon_domains_array=()
		parked_domains_array=()

        # Parse sub_domains
        while IFS= read -r domain; do
            if [[ -n "$domain" ]]; then
                sub_domains_array+=("$domain")
            fi
        done <<< "$sub_domains"

        # Parse addon_domains
        while IFS= read -r domain; do
            if [[ -n "$domain" ]]; then
                addon_domains_array+=("$domain")
            fi
        done <<< "$addon_domains"

        # Parse parked_domains
        while IFS= read -r domain; do
            if [[ -n "$domain" ]]; then
                parked_domains_array+=("$domain")
            fi
        done <<< "$parked_domains"

        # Filter out subdomains that are essentially addon_domain.$main_domain
        filtered_sub_domains=()
        for sub_domain in "${sub_domains_array[@]}"; do
            trimmed_sub_domain=$(echo "$sub_domain" | xargs)
            is_addon=false
            for addon in "${addon_domains_array[@]}"; do
                if [[ "$trimmed_sub_domain" == "$addon.$main_domain" ]]; then
                    is_addon=true
                    break
                fi
            done
            if [ "$is_addon" = false ]; then
                filtered_sub_domains+=("$trimmed_sub_domain")
            fi
        done

		main_domain_count=1
		log "Primary domain ($main_domain_count): $main_domain"

        addon_domains_count=${#addon_domains_array[@]}
        if [ "${#addon_domains_array[@]}" -eq 1 ] && [ -z "${addon_domains_array[0]}" ]; then
            addon_domains_count=0
            log "No addon domains detected."
        else
            log "Addon domains  ($addon_domains_count): ${addon_domains_array[@]}"
        fi

        parked_domains_count=${#parked_domains_array[@]}
        if [ "${#parked_domains_array[@]}" -eq 1 ] && [ -z "${parked_domains_array[0]}" ]; then
            parked_domains_count=0
            log "No parked domains detected."
        else
            log "Parked domains ($parked_domains_count): ${parked_domains_array[@]}"
        fi

        filtered_sub_domains_count=${#filtered_sub_domains[@]}
        if [ "${#filtered_sub_domains[@]}" -eq 1 ] && [ -z "${filtered_sub_domains[0]}" ]; then
            filtered_sub_domains_count=0
            log "No subdomains detected."
        else
            log "Subdomains     ($filtered_sub_domains_count): ${filtered_sub_domains[@]}"
        fi


        domains_total_count=$((main_domain_count + addon_domains_count + parked_domains_count + filtered_sub_domains_count))

        log "Detected a total of $domains_total_count domains"

        current_domain_count=0

        create_domain(){
            domain="$1"
            type="$2"

            current_domain_count=$((current_domain_count + 1))

		    if [[ "$domain" == *.cpanel.site ]]; then
		        log "Skipping cPanel temporary domain: $domain"
		        return 0
		    fi
			
            if [[ $domain == \*.* ]]; then
                log "WARNING: Skipping wildcard domain $domain"
				return 0
            fi
			log "Restoring $type $domain (${current_domain_count}/${domains_total_count})"

			local userdata_file="$real_backup_files_path/userdata/$domain"
			local addon_userdata_file="$real_backup_files_path/userdata/$domain.$main_domain"
			file_to_use="$userdata_file"
			[ ! -f "$file_to_use" ] && [ -f "$addon_userdata_file" ] && file_to_use="$addon_userdata_file"
			# cPanel keeps no userdata for parked (alias) domains, they serve the main domain's docroot
			[ ! -f "$file_to_use" ] && [ "$type" = "alias domain" ] && file_to_use="$real_backup_files_path/userdata/$main_domain"

			docroot=""
			if [ -f "$file_to_use" ]; then
				original_docroot=$(awk -F': ' '/^documentroot:/ {print $2}' "$file_to_use" | xargs)
			    docroot="${original_docroot#/home/$cpanel_username/}"
			    docroot="/var/www/html/$docroot"
			else
				log "WARNING: userdata file not found for $domain. Using default docroot."
			fi

			dry_run "Would restore $type $domain with --docroot ${docroot:-N/A}" && return

			if opencli domains-whoowns "$domain" | grep -q "not found in the database."; then
				if [ -n "$docroot" ]; then
					output=$(opencli domains-add "$domain" "$cpanel_username" --docroot "$docroot" 2>&1)
					while IFS= read -r line; do
						log "$line"
					done <<< "$output"
				else
					output=$(opencli domains-add "$domain" "$cpanel_username" 2>&1)
					while IFS= read -r line; do
						log "$line"
					done <<< "$output"                        
				fi
				if [ -f "$real_backup_files_path/userdata/$domain" ]; then
					local secruleengineoff=$(grep '^secruleengineoff=' "$real_backup_files_path/userdata/$domain" | cut -d'=' -f2 | cut -c1-2 | tr '[:upper:]' '[:lower:]')
					if [ "$secruleengineoff" == "1" ]; then
						log "Disabling WAF because ModSecurity is turned off for this domain in cPanel."
						output=$(opencli waf domain "$domain" "disable" 2>&1)
						while IFS= read -r line; do
							log "$line"
						done <<< "$output"
					fi
				fi
			else
				log "WARNING: $type $domain already exists and will not be added to this user."
			fi
        }

        log "Processing main (primary) domain.."
        create_domain "$main_domain" "main domain"

        if [ "$parked_domains_count" -eq 0 ]; then
            log "No parked (alias) domains detected."
        else
            log "Processing parked (alias) domains.."
            for parked in "${parked_domains_array[@]}"; do
                create_domain "$parked" "alias domain"
            done
        fi

        if [ "$addon_domains_count" -eq 0 ]; then
            log "No addon domains detected."
        else
            log "Processing addon domains.."
            for addon in "${addon_domains_array[@]}"; do
                create_domain "$addon" "addon domain"
            done
        fi

        if [ "$filtered_sub_domains_count" -eq 0 ]; then
            log "No subdomains detected."
        else
            log "Processing sub-domains.."
            for filtered_sub in "${filtered_sub_domains[@]}"; do
                create_domain "$filtered_sub" "subdomain"
            done
        fi

        log "Finished importing $domains_total_count domains"

    else
        log "FATAL ERROR: domains file userdata/main is missing in backup file."
        exit 1
    fi
}

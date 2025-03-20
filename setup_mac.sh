#!/bin/bash

# Cross-platform script configuration
set -euo pipefail

# Cross-platform environment variables
: "${CI:=false}"
: "${WITH_REDIS:=false}"
: "${SUDO_USER:=""}"

NO_COLOR=''
RED=''
CYAN=''
GREEN=''

# Check if terminal supports colors https://unix.stackexchange.com/a/10065/642181
if [ -t 1 ]; then
    total_colors=$(tput colors)
    if [[ -n "$total_colors" && $total_colors -ge 8 ]]; then
        # https://stackoverflow.com/a/28938235/18954618
        NO_COLOR='\033[0m'
        RED='\033[0;31m'
        CYAN='\033[0;36m'
        GREEN='\033[0;32m'
    fi
fi

error_log() { echo -e "${RED}ERROR: $1${NO_COLOR}"; }
info_log() { echo -e "${CYAN}INFO: $1${NO_COLOR}"; }
error_exit() {
    error_log "$*"
    exit 1
}

# Cross-platform OS detection - supports both Linux and macOS
if [[ "$(uname -s)" != "Darwin" && "$EUID" -ne 0 ]]; then 
    error_exit "Please run this script as root user"
fi

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Self-host Supabase with nginx/caddy and authelia 2FA with just ONE bash script."
    echo ""
    echo "Options:"
    echo "  -h, --help           Show this help message and exit"
    echo "  --proxy PROXY        Set the reverse proxy to use (nginx or caddy). Default: nginx"
    echo "  --with-authelia      Enable or disable Authelia 2FA support"
    echo ""
    echo "Examples:"
    echo "  $0 --proxy nginx --with-authelia    # Set up Supabase with nginx and Authelia 2FA"
    echo "  $0 --proxy caddy                    # Set up Supabase with caddy and no 2FA"
    echo ""
    echo "For more information, visit the project repository:"
    echo "https://github.com/loulibre/supafastllm"
}

has_argument() {
    [[ ("$1" == *=* && -n ${1#*=}) || (-n "$2" && "$2" != -*) ]]
}

extract_argument() { echo "${2:-${1#*=}}"; }

with_authelia=false
proxy="nginx"

# https://medium.com/@wujido20/handling-flags-in-bash-scripts-4b06b4d0ed04
while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help)
        usage
        exit 0
        ;;

    --with-authelia)
        with_authelia=true
        ;;

    --proxy)
        if has_argument "$@"; then
            proxy="$(extract_argument "$@")"
            shift
        fi
        ;;

    *)
        echo -e "ERROR: ${RED}Invalid option:${NO_COLOR} $1" >&2
        usage
        exit 1
        ;;
    esac
    shift
done

if [[ "$proxy" != "caddy" && "$proxy" != "nginx" ]]; then
    error_exit "proxy can only be caddy or nginx"
fi

info_log "Configuration Summary"
echo -e "  ${GREEN}Proxy:${NO_COLOR} ${proxy}"
echo -e "  ${GREEN}Authelia 2FA:${NO_COLOR} ${with_authelia}"

detect_arch() {
    case $(uname -m) in
    x86_64) echo "amd64" ;;
    aarch64 | arm64) echo "arm64" ;;
    armv7l) echo "arm" ;;
    i686 | i386) echo "386" ;;
    *) echo "err" ;;
    esac
}

detect_os() {
    case $(uname | tr '[:upper:]' '[:lower:]') in
    linux*) echo "linux" ;;
    darwin*) echo "darwin" ;;
    *) echo "err" ;;
    esac
}

os="$(detect_os)"
arch="$(detect_arch)"

if [[ "$os" == "err" ]]; then error_exit "This script only supports Linux and macOS"; fi
if [[ "$arch" == "err" ]]; then error_exit "Unsupported cpu architecture"; fi

# Cross-platform Docker checks
if ! command -v docker &> /dev/null; then
    error_exit "Docker is not installed. Please install Docker Desktop for Mac first."
fi

if ! docker info &> /dev/null; then
    error_exit "Docker is not running. Please start Docker Desktop and try again."
fi

# Cross-platform required packages
packages=(curl wget jq openssl git)

# Package installation based on OS
if [[ "$os" == "darwin" ]]; then
    if ! command -v brew &> /dev/null; then
        error_exit "Homebrew is not installed. Please install Homebrew first."
    fi
    
    # Install required packages
    brew install "${packages[@]}" httpd
    
    # Install Docker if not already installed
    if ! command -v docker &> /dev/null; then
        brew install --cask docker
    fi
else
    if [ -x "$(command -v apt-get)" ]; then
        apt-get update && apt-get install -y "${packages[@]}" apache2-utils
    elif [ -x "$(command -v apk)" ]; then
        apk update && apk add --no-cache "${packages[@]}" apache2-utils
    elif [ -x "$(command -v dnf)" ]; then
        dnf makecache && dnf install -y "${packages[@]}" httpd-tools
    elif [ -x "$(command -v zypper)" ]; then
        zypper refresh && zypper install "${packages[@]}" apache2-utils
    elif [ -x "$(command -v pacman)" ]; then
        pacman -Syu --noconfirm "${packages[@]}" apache
    elif [ -x "$(command -v pkg)" ]; then
        pkg update && pkg install -y "${packages[@]}" apache24
    else
        error_exit "Failed to install packages. Package manager not found.\nSupported package managers: apt, apk, dnf, zypper, pacman, pkg, brew"
    fi
fi

if [ $? -ne 0 ]; then error_exit "Failed to install packages."; fi

# URL validation function
validate_url() {
    local url="$1"
    # Trim whitespace
    url="${url// /}"
    
    local protocol=""
    local host=""
    local registered_domain=""
    
    # Extract protocol using basic string operations
    if [[ "$url" == http://* ]]; then
        protocol="http://"
        host="${url#http://}"
    elif [[ "$url" == https://* ]]; then
        protocol="https://"
        host="${url#https://}"
    else
        error_log "Invalid URL format. Must start with http:// or https:// (no spaces allowed)"
        return 1
    fi
    
    # Basic host validation
    if [[ ! "$host" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        error_log "Invalid host format. Please enter a valid domain name without spaces"
        return 1
    fi
    
    # Extract registered domain (last two parts of host)
    registered_domain=$(echo "$host" | grep -o '[^.]*\.[^.]*$')
    if [ -z "$registered_domain" ]; then
        error_log "Could not extract registered domain. Please enter a valid domain name"
        return 1
    fi
    
    # Return values
    echo "$protocol|$host|$registered_domain"
    return 0
}

githubAc="https://github.com/loulibre"
repoUrl="$githubAc/supafastllm"
directory="$(basename "$repoUrl")"

if [ -d "$directory" ]; then
    info_log "$directory directory present, skipping git clone"
else
    git clone "$repoUrl" "$directory"
fi

# Change to the docker directory
if ! cd "$directory/docker"; then 
    error_exit "Unable to access $directory/docker directory"
fi

# Create .env.example if it doesn't exist
if [ ! -f ".env.example" ]; then
    info_log "Creating .env.example file..."
    cp .env .env.example
fi

# Download yq if not present
if [ ! -x "$(command -v yq)" ]; then
    info_log "Downloading yq from https://github.com/mikefarah/yq"
    if [[ "$os" == "darwin" ]]; then
        brew install yq
    else
        wget "https://github.com/mikefarah/yq/releases/download/v4.44.6/yq_${os}_${arch}" -O /usr/local/bin/yq
        chmod +x /usr/local/bin/yq
    fi
fi

echo -e "---------------------------------------------------------------------------\n"

format_prompt() { echo -e "${GREEN}$1${NO_COLOR}"; }

confirmation_prompt() {
    local variable_to_update_name="$1"
    local answer=""
    read -rp "$(format_prompt "$2")" answer

    # converts input to lowercase using tr instead of bash 4.0+ syntax
    case "$(echo "$answer" | tr '[:upper:]' '[:lower:]')" in
    y | yes)
        answer=true
        ;;
    n | no)
        answer=false
        ;;
    *)
        error_log "Please answer yes or no\n"
        answer=""
        ;;
    esac

    # Use eval to dynamically assign the new value to the variable name
    if [ -n "$answer" ]; then eval "$variable_to_update_name=$answer"; fi
}

domain=""
while [ -z "$domain" ]; do
    if [ "$CI" == true ]; then
        domain="https://supabase.example.com"
    else
        read -rp "$(format_prompt "Enter your domain (e.g., http://example.com):") " domain
    fi

    # Validate URL using our new function
    if url_parts=$(validate_url "$domain"); then
        IFS='|' read -r protocol host registered_domain <<< "$url_parts"
        
        if [[ "$with_authelia" == true ]]; then
            if [[ "$protocol" != "https://" ]]; then
                error_log "As you've enabled --with-authelia flag, url protocol needs to https"
                domain=""
            fi
        fi
    else
        domain=""
    fi
done

username=""
if [[ "$CI" == true ]]; then username="inder"; fi

while [ -z "$username" ]; do
    read -rp "$(format_prompt "Enter username:") " username

    # https://stackoverflow.com/questions/18041761/bash-need-to-test-for-alphanumeric-string
    if [[ ! "$username" =~ ^[a-zA-Z0-9]+$ ]]; then
        error_log "Only alphabets and numbers are allowed"
        username=""
    fi
    # read command automatically trims leading & trailing whitespace. No need to handle it separately
done

password=""
confirmPassword=""

if [[ "$CI" == true ]]; then
    password="password"
    confirmPassword="password"
fi

while [[ -z "$password" || "$password" != "$confirmPassword" ]]; do
    read -s -rp "$(format_prompt "Enter password(password is hidden):") " password
    echo
    read -s -rp "$(format_prompt "Confirm password:") " confirmPassword
    echo

    if [[ "$password" != "$confirmPassword" ]]; then
        error_log "Password mismatch. Please try again!\n"
    fi
done

autoConfirm=""
if [[ "$CI" == true ]]; then autoConfirm="false"; fi

while [ -z "$autoConfirm" ]; do
    confirmation_prompt autoConfirm "Do you want to send confirmation emails to register users? If yes, you'll have to setup your own SMTP server [y/n]: "
    if [[ "$autoConfirm" == true ]]; then
        autoConfirm="false"
    elif [[ "$autoConfirm" == false ]]; then
        autoConfirm="true"
    fi
done

# If with_authelia, then additionally ask for email and display name
if [[ "$with_authelia" == true ]]; then
    email=""
    display_name=""
    setup_redis=""

    if [[ "$CI" == true ]]; then
        email="johndoe@gmail.com"
        display_name="Inder Singh"
        if [[ "$WITH_REDIS" == true ]]; then setup_redis=true; fi
    fi

    while [ -z "$email" ]; do
        read -rp "$(format_prompt "Enter your email for Authelia:") " email

        # split email string on @ symbol
        IFS="@" read -r before_at after_at <<<"$email"

        if [[ -z "$before_at" || -z "$after_at" ]]; then
            error_log "Invalid email"
            email=""
        fi
    done

    while [ -z "$display_name" ]; do
        read -rp "$(format_prompt "Enter Display Name:") " display_name

        if [[ ! "$display_name" =~ ^[a-zA-Z0-9[:space:]]+$ ]]; then
            error_log "Only alphabets, numbers and spaces are allowed"
            display_name=""
        fi
    done

    while [[ "$CI" == false && -z "$setup_redis" ]]; do
        confirmation_prompt setup_redis "Do you want to setup redis with authelia? [y/n]: "
    done
fi

info_log "Finishing..."

# Cross-platform bcrypt password hashing
# Adjusts rounds based on proxy type for better performance
bcryptRounds=12
if [[ "$proxy" == "nginx" && "$with_authelia" == false ]]; then bcryptRounds=6; fi

# https://www.baeldung.com/linux/bcrypt-hash#using-htpasswd
password=$(htpasswd -bnBC "$bcryptRounds" "" "$password" | cut -d : -f 2)

# Cross-platform OpenSSL commands for generating secrets
gen_hex() { openssl rand -hex "$1"; }

# Cross-platform base64 encoding with URL-safe characters
base64_url_encode() { openssl enc -base64 -A | tr '+/' '-_' | tr -d '='; }

jwt_secret=$(gen_hex 20)

# Cross-platform timestamp generation for JWT tokens
iat=$(date +%s)
exp=$((iat + (5 * 3600 * 24 * 365))) # 5 years expiry

gen_token() {
    local payload=$(
        echo "$1" | jq --arg jq_iat "$iat" --arg jq_exp "$exp" '.iat=($jq_iat | tonumber) | .exp=($jq_exp | tonumber)'
    )

    local payload_base64=$(printf %s "$payload" | base64_url_encode)

    local signed_content="${header_base64}.${payload_base64}"

    local signature=$(printf %s "$signed_content" | openssl dgst -binary -sha256 -hmac "$jwt_secret" | base64_url_encode)

    printf '%s' "${signed_content}.${signature}"
}

anon_payload='{"role": "anon", "iss": "supabase"}'
anon_token=$(gen_token "$anon_payload")

service_role_payload='{"role": "service_role", "iss": "supabase"}'
service_role_token=$(gen_token "$service_role_payload")

# Create .env file from .env.example
# This section handles the creation of the .env file from .env.example
# The process is:
# 1. If an existing .env file exists, back it up to .env.backup
# 2. Use sed to modify .env.example with new values:
#    - Remove line 3 (empty line)
#    - Replace POSTGRES_PASSWORD with a new random hex value
#    - Replace JWT_SECRET with the generated JWT secret
#    - Replace ANON_KEY with the generated anonymous token
#    - Replace SERVICE_ROLE_KEY with the generated service role token
#    - Replace DASHBOARD_PASSWORD with a placeholder
#    - Replace SECRET_KEY_BASE with a new random hex value
#    - Replace VAULT_ENC_KEY with a new random hex value
#    - Replace API_EXTERNAL_URL with the domain + /goapi
#    - Replace SUPABASE_PUBLIC_URL with the domain
#    - Replace ENABLE_EMAIL_AUTOCONFIRM with the user's choice
# 3. Rename the modified .env.example to .env
# 4. If the new .env file wasn't created successfully, restore from backup
# 5. If everything is successful, remove the backup file
if [ -f ".env" ]; then
    info_log "Backing up existing .env file..."
    mv .env .env.backup
fi

# Create new .env file from .env.example
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS version
    sed -i '' \
        -e "3d" \
        -e "s|POSTGRES_PASSWORD.*|POSTGRES_PASSWORD=$(gen_hex 16)|" \
        -e "s|JWT_SECRET.*|JWT_SECRET=$jwt_secret|" \
        -e "s|ANON_KEY.*|ANON_KEY=$anon_token|" \
        -e "s|SERVICE_ROLE_KEY.*|SERVICE_ROLE_KEY=$service_role_token|" \
        -e "s|DASHBOARD_PASSWORD.*|DASHBOARD_PASSWORD=not_being_used|" \
        -e "s|SECRET_KEY_BASE.*|SECRET_KEY_BASE=$(gen_hex 32)|" \
        -e "s|VAULT_ENC_KEY.*|VAULT_ENC_KEY=$(gen_hex 16)|" \
        -e "s|API_EXTERNAL_URL.*|API_EXTERNAL_URL=$domain/goapi|" \
        -e "s|SUPABASE_PUBLIC_URL.*|SUPABASE_PUBLIC_URL=$domain|" \
        -e "s|ENABLE_EMAIL_AUTOCONFIRM.*|ENABLE_EMAIL_AUTOCONFIRM=$autoConfirm|" \
        .env.example
else
    # Linux version
    sed -i \
        -e "3d" \
        -e "s|POSTGRES_PASSWORD.*|POSTGRES_PASSWORD=$(gen_hex 16)|" \
        -e "s|JWT_SECRET.*|JWT_SECRET=$jwt_secret|" \
        -e "s|ANON_KEY.*|ANON_KEY=$anon_token|" \
        -e "s|SERVICE_ROLE_KEY.*|SERVICE_ROLE_KEY=$service_role_token|" \
        -e "s|DASHBOARD_PASSWORD.*|DASHBOARD_PASSWORD=not_being_used|" \
        -e "s|SECRET_KEY_BASE.*|SECRET_KEY_BASE=$(gen_hex 32)|" \
        -e "s|VAULT_ENC_KEY.*|VAULT_ENC_KEY=$(gen_hex 16)|" \
        -e "s|API_EXTERNAL_URL.*|API_EXTERNAL_URL=$domain/goapi|" \
        -e "s|SUPABASE_PUBLIC_URL.*|SUPABASE_PUBLIC_URL=$domain|" \
        -e "s|ENABLE_EMAIL_AUTOCONFIRM.*|ENABLE_EMAIL_AUTOCONFIRM=$autoConfirm|" \
        .env.example
fi

# Rename .env.example to .env
mv .env.example .env

# If something went wrong, restore the backup
if [ ! -f ".env" ]; then
    error_log "Failed to create .env file, restoring backup..."
    mv .env.backup .env
    error_exit "Failed to create .env file"
fi

# Remove backup if everything is successful
rm -f .env.backup

update_yaml_file() {
    # https://github.com/mikefarah/yq/issues/465#issuecomment-2265381565
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS version
        sed -i '' '/^\r\{0,1\}$/s// #BLANK_LINE/' "$2"
        yq -i "$1" "$2"
        sed -i '' "s/ *#BLANK_LINE//g" "$2"
    else
        # Linux version
        sed -i '/^\r\{0,1\}$/s// #BLANK_LINE/' "$2"
        yq -i "$1" "$2"
        sed -i "s/ *#BLANK_LINE//g" "$2"
    fi
}

compose_file="docker-compose.yml"
env_vars=""

update_env_vars() {
    for env_key_value in "$@"; do
        env_vars="${env_vars}\n$env_key_value"
    done
}

# START DEFINING proxy_service_yaml
proxy_service_yaml=".services.$proxy.container_name=\"$proxy-container\" |
.services.$proxy.restart=\"unless-stopped\" |
.services.$proxy.ports=[\"80:80\",\"443:443\",\"443:443/udp\"] |
.services.$proxy.depends_on.kong.condition=\"service_healthy\"
"
if [[ "$with_authelia" == true ]]; then
    proxy_service_yaml="${proxy_service_yaml} | .services.$proxy.depends_on.authelia.condition=\"service_healthy\""
fi

if [[ "$proxy" == "caddy" ]]; then
    caddy_local_volume="./volumes/caddy"
    caddyfile_local="$caddy_local_volume/Caddyfile"

    proxy_service_yaml="${proxy_service_yaml} |
                        .services.caddy.image=\"caddy:2.9.1\" |
                        .services.caddy.environment.DOMAIN=\"\${SUPABASE_PUBLIC_URL:?error}\" |
                        .services.caddy.volumes=[\"$caddyfile_local:/etc/caddy/Caddyfile\",\"$caddy_local_volume/caddy_data:/data\",\"$caddy_local_volume/caddy_config:/config\"]
                       "
else
    update_env_vars "NGINX_SERVER_NAME=$host"
    # docker compose nginx service command directive. Passed via yq strenv
    nginx_cmd=""

    nginx_local_volume="./volumes/nginx"
    # path in local fs where nginx template file is stored
    nginx_local_template_file="$nginx_local_volume/nginx.template"

    # path inside container where template file will be mounted
    nginx_container_template_file="/etc/nginx/user_conf.d/nginx.template"

    # Pass an array of args to nginx service command directive https://stackoverflow.com/a/57821785/18954618
    # output multiline string from yq https://mikefarah.gitbook.io/yq/operators/string-operators#string-blocks-bash-and-newlines

    proxy_service_yaml="${proxy_service_yaml} |
                        .services.nginx.image=\"jonasal/nginx-certbot:5.4.1-nginx1.27.4\" |
                        .services.nginx.volumes=[\"$nginx_local_volume:/etc/nginx/user_conf.d\",\"$nginx_local_volume/letsencrypt:/etc/letsencrypt\"] |
                        .services.nginx.environment.NGINX_SERVER_NAME = \"\${NGINX_SERVER_NAME:?error}\" |
                        .services.nginx.environment.CERTBOT_EMAIL=\"your@email.org\" |
                        .services.nginx.command=[\"/bin/bash\",\"-c\",strenv(nginx_cmd)]
                       "

    if [[ "$CI" == true ]]; then
        # https://github.com/JonasAlfredsson/docker-nginx-certbot/blob/master/docs/advanced_usage.md#local-ca
        proxy_service_yaml="${proxy_service_yaml} | .services.nginx.environment.USE_LOCAL_CA=1"
    fi

    # https://www.baeldung.com/linux/nginx-config-environment-variables#4-a-common-pitfall

    printf -v nginx_cmd \
        "envsubst '\$\${NGINX_SERVER_NAME}' < %s > %s/nginx.conf \\
&& /scripts/start_nginx_certbot.sh\n" \
        "$nginx_container_template_file" "$(dirname "$nginx_container_template_file")"
fi

# HANDLE BASIC_AUTH
if [[ "$with_authelia" == false ]]; then
    update_env_vars "PROXY_AUTH_USERNAME=$username" "PROXY_AUTH_PASSWORD='$password'"

    proxy_service_yaml="${proxy_service_yaml} | 
                        .services.$proxy.environment.PROXY_AUTH_USERNAME = \"\${PROXY_AUTH_USERNAME:?error}\" |
                        .services.$proxy.environment.PROXY_AUTH_PASSWORD = \"\${PROXY_AUTH_PASSWORD:?error}\"
                        "

    if [[ "$proxy" == "nginx" ]]; then
        # path inside nginx container for storing basic_auth credentials
        nginx_pass_file="/etc/nginx/user_conf.d/supabase-self-host-users"

        printf -v nginx_cmd "echo \"\$\${PROXY_AUTH_USERNAME}:\$\${PROXY_AUTH_PASSWORD}\" >%s \\
&& %s" $nginx_pass_file "$nginx_cmd"
    fi
fi

nginx_cmd="${nginx_cmd:=""}" update_yaml_file "$proxy_service_yaml" "$compose_file"

if [[ "$with_authelia" == true ]]; then
    # Dynamically update yaml path from env https://github.com/mikefarah/yq/discussions/1253
    # https://mikefarah.gitbook.io/yq/operators/style

    # WRITE AUTHELIA users_database.yml file
    # adding disabled=false after updating style to double so that every value except disabled is double quoted
    yaml_path=".users.$username" displayName="$display_name" password="$password" email="$email" \
        yq -n 'eval(strenv(yaml_path)).displayname = strenv(displayName) |
               eval(strenv(yaml_path)).password = strenv(password) | 
               eval(strenv(yaml_path)).email = strenv(email) | 
               eval(strenv(yaml_path)).groups = ["admins","dev"] | 
               .. style="double" | 
               eval(strenv(yaml_path)).disabled = false' >./volumes/authelia/users_database.yml

    authelia_config_file_yaml='.access_control.rules[0].domain=strenv(host) | 
            .session.cookies[0].domain=strenv(registered_domain) | 
            .session.cookies[0].authelia_url=strenv(authelia_url) |
            .session.cookies[0].default_redirection_url=strenv(redirect_url)'

    server_endpoints="forward-auth"
    implementation="ForwardAuth"

    if [[ "$proxy" == "nginx" ]]; then
        server_endpoints="auth-request"
        implementation="AuthRequest"
    fi

    # auth implementation
    authelia_config_file_yaml="${authelia_config_file_yaml} | .server.endpoints.authz.$server_endpoints.implementation=\"$implementation\""

    update_env_vars "AUTHELIA_SESSION_SECRET=$(gen_hex 32)" "AUTHELIA_STORAGE_ENCRYPTION_KEY=$(gen_hex 32)" "AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET=$(gen_hex 32)"

    # shellcheck disable=SC2016
    authelia_docker_service_yaml='.services.authelia.container_name = "authelia" |
       .services.authelia.image = "authelia/authelia:4.38" |
       .services.authelia.volumes = ["./volumes/authelia:/config"] |
       .services.authelia.depends_on.db.condition = "service_healthy" |
       .services.authelia.expose = [9091] |    
       .services.authelia.restart = "unless-stopped" |    
       .services.authelia.healthcheck.disable = false |
       .services.authelia.environment = {
         "AUTHELIA_STORAGE_POSTGRES_ADDRESS": "tcp://db:5432",
         "AUTHELIA_STORAGE_POSTGRES_USERNAME": "postgres",
         "AUTHELIA_STORAGE_POSTGRES_PASSWORD" : "${POSTGRES_PASSWORD}",
         "AUTHELIA_STORAGE_POSTGRES_DATABASE" : "${POSTGRES_DB}",
         "AUTHELIA_STORAGE_POSTGRES_SCHEMA" : strenv(authelia_schema),
         "AUTHELIA_SESSION_SECRET": "${AUTHELIA_SESSION_SECRET:?error}",
         "AUTHELIA_STORAGE_ENCRYPTION_KEY": "${AUTHELIA_STORAGE_ENCRYPTION_KEY:?error}",
         "AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET": "${AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET:?error}"
       } |       
       .services.db.environment.AUTHELIA_SCHEMA = strenv(authelia_schema) |
       .services.db.volumes += "./volumes/db/schema-authelia.sh:/docker-entrypoint-initdb.d/schema-authelia.sh"'

    if [[ "$setup_redis" == true ]]; then
        authelia_config_file_yaml="${authelia_config_file_yaml}|.session.redis.host=\"redis\" | .session.redis.port=6379"

        authelia_docker_service_yaml="${authelia_docker_service_yaml}|.services.redis.container_name=\"redis\" |
                    .services.redis.image=\"redis:7.4\" |
                    .services.redis.expose=[6379] |
                    .services.redis.volumes=[\"./volumes/redis:/data\"] |
                    .services.redis.healthcheck={
                    \"test\" : [\"CMD-SHELL\",\"redis-cli ping | grep PONG\"],
                    \"timeout\" : \"5s\",
                    \"interval\" : \"1s\",
                    \"retries\" : 5
                    } |
                    .services.authelia.depends_on.redis.condition=\"service_healthy\""
    fi

    host="$host" registered_domain="$registered_domain" authelia_url="$domain"/authenticate redirect_url="$domain" \
        update_yaml_file "$authelia_config_file_yaml" "./volumes/authelia/configuration.yml"

    authelia_schema="authelia" update_yaml_file "$authelia_docker_service_yaml" "$compose_file"
fi

echo -e "$env_vars" >>.env

if [[ "$proxy" == "caddy" ]]; then
    mkdir -p "$caddy_local_volume"

    # https://stackoverflow.com/a/3953712/18954618
    echo "{\$DOMAIN} {
        $([[ "$CI" == true ]] && echo "tls internal")
        @supa_api path /rest/* /auth/* /realtime/* /storage/* /functions/*

        $([[ "$with_authelia" == true ]] && echo "@authelia path /authenticate /authenticate/*
        handle @authelia {
                reverse_proxy authelia:9091
        }
        ")

        handle @supa_api {
		    reverse_proxy kong:8000
	    }

        handle_path /goapi/* {
            reverse_proxy kong:8000
        }

       	handle {
            $([[ "$with_authelia" == false ]] && echo "basic_auth {
			    {\$PROXY_AUTH_USERNAME} {\$PROXY_AUTH_PASSWORD}
		    }" || echo "forward_auth authelia:9091 {
                        uri /api/authz/forward-auth

                        copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
                }")	    	

		    reverse_proxy studio:3000
	    }
      	
        header -server
}" >"$caddyfile_local"
else
    mkdir -p "$(dirname "$nginx_local_template_file")"

    # mounted local ./volumes/nginx/snippets to this path inside container
    nginxSnippetsPath="/etc/nginx/user_conf.d/snippets"

    # cert path inside container https://github.com/JonasAlfredsson/docker-nginx-certbot/blob/master/docs/good_to_know.md#how-the-script-add-domain-names-to-certificate-requests
    certPath="/etc/letsencrypt/live/supabase-automated-self-host"

    echo "    
upstream kong_upstream {
        server kong:8000;
        keepalive 2;
}

server {
	    listen 443 ssl;
 	    listen [::]:443 ssl;
 	    http2 on;
        server_name \${NGINX_SERVER_NAME};
        server_tokens off;
        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Original-URL \$scheme://\$http_host\$request_uri;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$http_host;
        proxy_set_header X-Forwarded-URI \$request_uri;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Real-IP \$remote_addr;

        ssl_certificate         $certPath/fullchain.pem;
        ssl_certificate_key     $certPath/privkey.pem;
        ssl_trusted_certificate $certPath/chain.pem;
    
        ssl_dhparam /etc/letsencrypt/dhparams/dhparam.pem;

        location /realtime {
            proxy_pass http://kong_upstream;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \"upgrade\";
            proxy_read_timeout 3600s;
        }

        location /storage {
            client_max_body_size 0;
            proxy_pass http://kong_upstream;
        }

    	location /goapi/ {
		    proxy_pass http://kong_upstream/;
	    }

        location /rest {
            proxy_pass http://kong_upstream;
        }

        location /auth {
            proxy_pass http://kong_upstream;
        }

        location /functions {
            proxy_pass http://kong_upstream;
        }

        $([[ $with_authelia == true ]] && echo "
        include $nginxSnippetsPath/authelia-location.conf;

    	location /authenticate {
	     	include $nginxSnippetsPath/proxy.conf;
		    proxy_pass http://authelia:9091;
	    }")

        location / {
            $(
        [[ $with_authelia == false ]] && echo "auth_basic \"Admin\";
            auth_basic_user_file $nginx_pass_file;
            " || echo "            
            include $nginxSnippetsPath/proxy.conf;
		    include $nginxSnippetsPath/authelia-authrequest.conf;
            "
    )
            proxy_pass http://studio:3000;
        }
}

server {
    listen 80;
	listen [::]:80;
    server_name \${NGINX_SERVER_NAME};
    return 301 https://\$server_name\$request_uri;
}
" >"$nginx_local_template_file"
fi

# Cross-platform file ownership handling
# Only changes ownership if SUDO_USER is set (typically on Linux)
if [ -n "$SUDO_USER" ]; then chown -R "$SUDO_USER": .; fi

echo -e "\n🎉 Success!"
echo "👉 Next steps:"
echo "1. Change into the docker directory:"
echo "   cd $directory/docker"
echo "2. Start the services with Docker Compose:"
echo "   docker compose up -d"
echo "🚀 Everything should now be running!"

echo -e "\n🌐 To access the dashboard over the internet, ensure your firewall allows traffic on ports 80 and 443\n"

# Cross-platform security cleanup
unset password confirmPassword
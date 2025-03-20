#!/bin/bash

# URL validation function
validate_url() {
    local url="$1"
    # Trim whitespace
    url="${url// /}"
    
    local protocol=""
    local host=""
    local registered_domain=""
    
    echo "Testing URL: '$url'"
    
    # Extract protocol using basic string operations
    if [[ "$url" == http://* ]]; then
        protocol="http://"
        host="${url#http://}"
    elif [[ "$url" == https://* ]]; then
        protocol="https://"
        host="${url#https://}"
    else
        echo "ERROR: Invalid URL format. Must start with http:// or https:// (no spaces allowed)"
        return 1
    fi
    
    echo "Protocol found: $protocol"
    echo "Host found: $host"
    
    # Basic host validation
    if [[ ! "$host" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "ERROR: Invalid host format. Please enter a valid domain name without spaces"
        return 1
    fi
    
    # Extract registered domain (last two parts of host)
    registered_domain=$(echo "$host" | grep -o '[^.]*\.[^.]*$')
    if [ -z "$registered_domain" ]; then
        echo "ERROR: Could not extract registered domain. Please enter a valid domain name"
        return 1
    fi
    
    echo "Registered domain: $registered_domain"
    
    # Return values
    echo "$protocol|$host|$registered_domain"
    return 0
}

# Test cases
echo "Test 1: Valid URL with no spaces"
validate_url "http://apps.topaims.net"

echo -e "\nTest 2: Valid URL with spaces"
validate_url "http://apps.topaims.net "

echo -e "\nTest 3: Invalid URL (no protocol)"
validate_url "apps.topaims.net"

echo -e "\nTest 4: Invalid URL (invalid characters)"
validate_url "http://apps.topaims.net!"
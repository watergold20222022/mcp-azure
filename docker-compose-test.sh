#!/bin/bash
# Azure MCP Server - Docker Compose HTTP/SSE Test Script
# This script builds and tests the Azure MCP Server using docker-compose

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
PORT=${MCP_PORT:-8080}
HOST=${MCP_HOST:-127.0.0.1}
SSE_OUTPUT="/tmp/compose_sse_out_$$.txt"
COMPOSE_PROJECT="azure-mcp"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Azure MCP Server - Docker Compose Test${NC}"
echo -e "${BLUE}========================================${NC}"

# Check if .env file exists
if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${RED}Error: .env file not found at $ENV_FILE${NC}"
    echo "Please create .env with Azure credentials:"
    echo "  AZURE_TENANT_ID=<your-tenant-id>"
    echo "  AZURE_CLIENT_ID=<your-client-id>"
    echo "  AZURE_CLIENT_SECRET=<your-client-secret>"
    echo "  AZURE_SUBSCRIPTION_ID=<your-subscription-id>"
    exit 1
fi

# Load environment variables for subscription ID
source "$ENV_FILE"

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker compose -p "$COMPOSE_PROJECT" down 2>/dev/null || true
    rm -f "$SSE_OUTPUT"
    echo -e "${GREEN}Done.${NC}"
}
trap cleanup EXIT

# Step 1: Stop any existing containers
echo -e "${YELLOW}Stopping any existing containers...${NC}"
docker compose -p "$COMPOSE_PROJECT" down 2>/dev/null || true
echo -e "${GREEN}✓ Cleanup complete${NC}"

# Step 2: Build the image using docker-compose
echo -e "\n${BLUE}Step 1: Building Docker image with docker-compose...${NC}"
docker compose -p "$COMPOSE_PROJECT" build
echo -e "${GREEN}✓ Docker image built${NC}"

# Step 3: Start the container
echo -e "\n${BLUE}Step 2: Starting container with docker-compose...${NC}"
docker compose -p "$COMPOSE_PROJECT" up -d

# Wait for server to start
echo -e "${YELLOW}Waiting for server to start...${NC}"
sleep 3

# Show container status
echo -e "\nContainer Status:"
docker compose -p "$COMPOSE_PROJECT" ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

# Step 4: Connect to SSE endpoint
echo -e "\n${BLUE}Step 3: Connecting to SSE endpoint...${NC}"
curl -s -N "http://$HOST:$PORT/sse" > "$SSE_OUTPUT" &
SSE_PID=$!
sleep 2

# Extract session ID
SESSION_ID=$(grep -o 'sessionId=[^"]*' "$SSE_OUTPUT" | head -1 | cut -d= -f2)
if [[ -z "$SESSION_ID" ]]; then
    echo -e "${RED}Error: Failed to get session ID${NC}"
    cat "$SSE_OUTPUT"
    exit 1
fi
echo -e "${GREEN}✓ Session ID: $SESSION_ID${NC}"

# Function to send MCP request
send_mcp_request() {
    local id=$1
    local method=$2
    local params=$3
    
    if [[ -z "$params" ]]; then
        curl -s -X POST "http://$HOST:$PORT/message?sessionId=$SESSION_ID" \
            -H "Content-Type: application/json" \
            -d "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"$method\"}" > /dev/null
    else
        curl -s -X POST "http://$HOST:$PORT/message?sessionId=$SESSION_ID" \
            -H "Content-Type: application/json" \
            -d "{\"jsonrpc\":\"2.0\",\"id\":$id,\"method\":\"$method\",\"params\":$params}" > /dev/null
    fi
}

# Test 1: Initialize
echo -e "\n${BLUE}Test 1: MCP Initialize${NC}"
send_mcp_request 1 "initialize" '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"compose-test","version":"1.0"}}'
sleep 1

if grep -q '"serverInfo"' "$SSE_OUTPUT"; then
    echo -e "${GREEN}✓ Initialize successful${NC}"
    SERVER_VERSION=$(grep -o '"version":"[^"]*"' "$SSE_OUTPUT" | head -2 | tail -1 | cut -d'"' -f4)
    echo -e "  Server: Azure MCP Server $SERVER_VERSION"
else
    echo -e "${RED}✗ Initialize failed${NC}"
fi

# Test 2: Send initialized notification
echo -e "\n${BLUE}Test 2: Send initialized notification${NC}"
curl -s -X POST "http://$HOST:$PORT/message?sessionId=$SESSION_ID" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' > /dev/null
echo -e "${GREEN}✓ Initialized notification sent${NC}"

# Test 3: List tools
echo -e "\n${BLUE}Test 3: List available tools${NC}"
send_mcp_request 2 "tools/list" ""
sleep 1

TOOL_COUNT=$(grep -o '"name":' "$SSE_OUTPUT" | wc -l)
echo -e "${GREEN}✓ Tools available: $TOOL_COUNT${NC}"

# Test 4: Call group_list
if [[ -n "$AZURE_SUBSCRIPTION_ID" ]]; then
    echo -e "\n${BLUE}Test 4: Call group_list tool${NC}"
    echo -e "  Subscription: ${AZURE_SUBSCRIPTION_ID:0:8}..."
    send_mcp_request 3 "tools/call" "{\"name\":\"group_list\",\"arguments\":{\"subscription\":\"$AZURE_SUBSCRIPTION_ID\"}}"
    sleep 8
    
    LAST_RESPONSE=$(tail -10 "$SSE_OUTPUT" | grep '"id":3' || true)
    
    if echo "$LAST_RESPONSE" | grep -q '"isError":false'; then
        echo -e "${GREEN}✓ group_list successful${NC}"
        DECODED=$(echo "$LAST_RESPONSE" | sed 's/\\u0022/"/g')
        echo -e "  ${BLUE}Resource Groups:${NC}"
        echo "$DECODED" | grep -o '"name":"[^"]*","id":"[^"]*","location":"[^"]*"' | while read -r line; do
            NAME=$(echo "$line" | sed 's/.*"name":"\([^"]*\)".*/\1/')
            LOCATION=$(echo "$line" | sed 's/.*"location":"\([^"]*\)".*/\1/')
            echo -e "    ${GREEN}•${NC} $NAME (${YELLOW}$LOCATION${NC})"
        done
        COUNT=$(echo "$DECODED" | grep -o '"name":"[^"]*","id":"[^"]*","location":"[^"]*"' | wc -l)
        echo -e "  Total: $COUNT resource group(s)"
    elif echo "$LAST_RESPONSE" | grep -q '"isError":true'; then
        echo -e "${RED}✗ group_list returned an error${NC}"
        DECODED=$(echo "$LAST_RESPONSE" | sed 's/\\u0022/"/g')
        ERROR_MSG=$(echo "$DECODED" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//')
        echo -e "  Error: $ERROR_MSG"
    else
        echo -e "${YELLOW}⚠ Response pending, waiting...${NC}"
        sleep 5
        LAST_RESPONSE=$(tail -10 "$SSE_OUTPUT" | grep '"id":3' || true)
        if echo "$LAST_RESPONSE" | grep -q '"isError":false'; then
            echo -e "${GREEN}✓ group_list successful (delayed)${NC}"
            DECODED=$(echo "$LAST_RESPONSE" | sed 's/\\u0022/"/g')
            echo -e "  ${BLUE}Resource Groups:${NC}"
            echo "$DECODED" | grep -o '"name":"[^"]*","id":"[^"]*","location":"[^"]*"' | while read -r line; do
                NAME=$(echo "$line" | sed 's/.*"name":"\([^"]*\)".*/\1/')
                LOCATION=$(echo "$line" | sed 's/.*"location":"\([^"]*\)".*/\1/')
                echo -e "    ${GREEN}•${NC} $NAME (${YELLOW}$LOCATION${NC})"
            done
            COUNT=$(echo "$DECODED" | grep -o '"name":"[^"]*","id":"[^"]*","location":"[^"]*"' | wc -l)
            echo -e "  Total: $COUNT resource group(s)"
        fi
    fi
else
    echo -e "\n${YELLOW}Test 4: Skipped (AZURE_SUBSCRIPTION_ID not set)${NC}"
fi

# Kill SSE connection
kill $SSE_PID 2>/dev/null || true

# Summary
echo -e "\n${BLUE}========================================${NC}"
echo -e "${GREEN}All Docker Compose tests completed!${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Container: ${GREEN}azure-mcp-server${NC}"
echo -e "Image: ${GREEN}azure-mcp-server-http:local${NC}"
echo -e "Server URL: ${GREEN}http://$HOST:$PORT${NC}"
echo -e "Session ID: ${GREEN}$SESSION_ID${NC}"

# Show container logs
echo -e "\nContainer logs (last 10 lines):"
docker compose -p "$COMPOSE_PROJECT" logs --tail=10

echo -e "\n${YELLOW}Press Enter to stop and remove the container...${NC}"
read -r

# Cleanup is handled by trap

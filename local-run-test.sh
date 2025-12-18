#!/bin/bash
# Azure MCP Server - Local HTTP/SSE Test Script
# This script starts the Azure MCP Server with HTTP transport and tests the MCP protocol

set -e

# Configuration
DOTNET_ROOT=/snap/aspnetcore-runtime-90/current/usr/lib/dotnet
SERVER_DIR="$(dirname "$0")/servers/Azure.Mcp.Server/src/bin/Release/net9.0"
ENV_FILE="$(dirname "$0")/.env"
PORT=${MCP_PORT:-8080}
HOST=${MCP_HOST:-127.0.0.1}
SSE_OUTPUT="/tmp/sse_out_$$.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Azure MCP Server - HTTP/SSE Test${NC}"
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

# Check if server binary exists
if [[ ! -f "$SERVER_DIR/azmcp.dll" ]]; then
    echo -e "${YELLOW}Server binary not found. Building...${NC}"
    cd "$(dirname "$0")"
    dotnet build servers/Azure.Mcp.Server/src -c Release
fi

# Load environment variables
source "$ENV_FILE"

# Check required Azure variables
if [[ -z "$AZURE_TENANT_ID" || -z "$AZURE_CLIENT_ID" || -z "$AZURE_CLIENT_SECRET" ]]; then
    echo -e "${RED}Error: Missing Azure credentials in .env file${NC}"
    exit 1
fi

# Clean up any existing Azure MCP server processes
echo -e "${YELLOW}Cleaning up existing processes...${NC}"
pkill -9 -f "azmcp.dll" 2>/dev/null || true
pkill -9 -f "curl.*sse" 2>/dev/null || true
rm -f /tmp/sse_out_*.txt 2>/dev/null || true
sleep 1

# Kill any existing server on the port
if lsof -i :$PORT &>/dev/null; then
    echo -e "${YELLOW}Killing existing process on port $PORT...${NC}"
    fuser -k $PORT/tcp 2>/dev/null || true
    sleep 1
fi
echo -e "${GREEN}✓ Cleanup complete${NC}"

# Start the server in background
echo -e "${GREEN}Starting Azure MCP Server on http://$HOST:$PORT...${NC}"
cd "$SERVER_DIR"
export DOTNET_ROOT
ASPNETCORE_URLS="http://$HOST:$PORT" $DOTNET_ROOT/dotnet azmcp.dll server start \
    --transport http \
    --dangerously-disable-http-incoming-auth \
    --mode namespace &
SERVER_PID=$!

# Wait for server to start
echo -e "${YELLOW}Waiting for server to start...${NC}"
sleep 3

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo -e "${RED}Error: Server failed to start${NC}"
    exit 1
fi

echo -e "${GREEN}Server started with PID $SERVER_PID${NC}"

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    kill $SERVER_PID 2>/dev/null || true
    rm -f "$SSE_OUTPUT"
    echo -e "${GREEN}Done.${NC}"
}
trap cleanup EXIT

# Connect to SSE endpoint and capture session ID
echo -e "\n${BLUE}Connecting to SSE endpoint...${NC}"
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
echo -e "${GREEN}Session ID: $SESSION_ID${NC}"

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
send_mcp_request 1 "initialize" '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test-script","version":"1.0"}}'
sleep 1

# Check response
if grep -q '"serverInfo"' "$SSE_OUTPUT"; then
    echo -e "${GREEN}✓ Initialize successful${NC}"
    SERVER_NAME=$(grep -o '"name":"[^"]*"' "$SSE_OUTPUT" | grep -A1 serverInfo | head -1 | cut -d'"' -f4)
    SERVER_VERSION=$(grep -o '"version":"[^"]*"' "$SSE_OUTPUT" | head -2 | tail -1 | cut -d'"' -f4)
    echo -e "  Server: $SERVER_NAME $SERVER_VERSION"
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

# Test 4: Call group_list (if subscription is set)
if [[ -n "$AZURE_SUBSCRIPTION_ID" ]]; then
    echo -e "\n${BLUE}Test 4: Call group_list tool${NC}"
    echo -e "  Subscription: ${AZURE_SUBSCRIPTION_ID:0:8}..."
    send_mcp_request 3 "tools/call" "{\"name\":\"group_list\",\"arguments\":{\"subscription\":\"$AZURE_SUBSCRIPTION_ID\"}}"
    sleep 5
    
    # Get the last response from SSE stream
    LAST_RESPONSE=$(tail -10 "$SSE_OUTPUT" | grep '"id":3' || true)
    
    if echo "$LAST_RESPONSE" | grep -q '"isError":false'; then
        echo -e "${GREEN}✓ group_list successful${NC}"
        
        # Decode unicode escapes and extract resource group info
        DECODED=$(echo "$LAST_RESPONSE" | sed 's/\\u0022/"/g')
        
        # Extract resource groups with name and location
        echo -e "  ${BLUE}Resource Groups:${NC}"
        echo "$DECODED" | grep -o '"name":"[^"]*","id":"[^"]*","location":"[^"]*"' | while read -r line; do
            NAME=$(echo "$line" | sed 's/.*"name":"\([^"]*\)".*/\1/')
            LOCATION=$(echo "$line" | sed 's/.*"location":"\([^"]*\)".*/\1/')
            echo -e "    ${GREEN}•${NC} $NAME (${YELLOW}$LOCATION${NC})"
        done
        
        # Count total
        COUNT=$(echo "$DECODED" | grep -o '"name":"[^"]*","id":"[^"]*","location":"[^"]*"' | wc -l)
        echo -e "  Total: $COUNT resource group(s)"
        
    elif echo "$LAST_RESPONSE" | grep -q '"isError":true'; then
        echo -e "${RED}✗ group_list returned an error${NC}"
        # Extract error message (decode unicode first)
        DECODED=$(echo "$LAST_RESPONSE" | sed 's/\\u0022/"/g')
        ERROR_MSG=$(echo "$DECODED" | grep -o '"message":"[^"]*"' | head -1 | sed 's/"message":"//;s/"$//')
        echo -e "  Error: $ERROR_MSG"
        echo -e "\n${YELLOW}Debugging info:${NC}"
        echo -e "  - Check AZURE_TENANT_ID, AZURE_CLIENT_ID, AZURE_CLIENT_SECRET are correct"
        echo -e "  - Verify service principal has Reader role on subscription"
        echo -e "  - Try: az login --service-principal -u \$AZURE_CLIENT_ID -p \$AZURE_CLIENT_SECRET --tenant \$AZURE_TENANT_ID"
    else
        echo -e "${YELLOW}⚠ Response not captured yet, waiting...${NC}"
        sleep 3
        # Try again
        LAST_RESPONSE=$(tail -10 "$SSE_OUTPUT" | grep '"id":3' || true)
        if [[ -n "$LAST_RESPONSE" ]]; then
            DECODED=$(echo "$LAST_RESPONSE" | sed 's/\\u0022/"/g')
            if echo "$LAST_RESPONSE" | grep -q '"isError":false'; then
                echo -e "${GREEN}✓ group_list successful (delayed)${NC}"
                echo -e "  ${BLUE}Resource Groups:${NC}"
                echo "$DECODED" | grep -o '"name":"[^"]*","id":"[^"]*","location":"[^"]*"' | while read -r line; do
                    NAME=$(echo "$line" | sed 's/.*"name":"\([^"]*\)".*/\1/')
                    LOCATION=$(echo "$line" | sed 's/.*"location":"\([^"]*\)".*/\1/')
                    echo -e "    ${GREEN}•${NC} $NAME (${YELLOW}$LOCATION${NC})"
                done
            else
                echo -e "  Raw response (first 300 chars):"
                echo "$LAST_RESPONSE" | head -c 300
            fi
        else
            echo -e "  Check SSE output: $SSE_OUTPUT"
        fi
    fi
else
    echo -e "\n${YELLOW}Test 4: Skipped (AZURE_SUBSCRIPTION_ID not set)${NC}"
fi

# Summary
echo -e "\n${BLUE}========================================${NC}"
echo -e "${GREEN}All tests completed!${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Server running at: ${GREEN}http://$HOST:$PORT${NC}"
echo -e "Session ID: ${GREEN}$SESSION_ID${NC}"
echo -e "\nPress Ctrl+C to stop the server..."

# Keep script running
wait $SERVER_PID

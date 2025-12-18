#!/bin/bash
# Azure MCP Server - Docker HTTP/SSE Test Script
# Tests the MCP server running in Docker with HTTP transport

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
IMAGE_NAME="azure-mcp-server-http"
CONTAINER_NAME="azure-mcp-test"
PORT=${MCP_PORT:-8080}
HOST="127.0.0.1"
SSE_OUTPUT="/tmp/docker_sse_out_$$.txt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Azure MCP Server - Docker HTTP/SSE Test${NC}"
echo -e "${BLUE}========================================${NC}"

# Check if .env file exists
if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${RED}Error: .env file not found at $ENV_FILE${NC}"
    echo "Please create .env with Azure credentials"
    exit 1
fi

# Load environment variables
source "$ENV_FILE"

# Check required Azure variables
if [[ -z "$AZURE_TENANT_ID" || -z "$AZURE_CLIENT_ID" || -z "$AZURE_CLIENT_SECRET" ]]; then
    echo -e "${RED}Error: Missing Azure credentials in .env file${NC}"
    exit 1
fi

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    docker stop "$CONTAINER_NAME" 2>/dev/null || true
    docker rm "$CONTAINER_NAME" 2>/dev/null || true
    pkill -f "curl.*sse" 2>/dev/null || true
    rm -f "$SSE_OUTPUT"
    echo -e "${GREEN}Done.${NC}"
}
trap cleanup EXIT

# Clean up any existing container
echo -e "${YELLOW}Cleaning up existing containers...${NC}"
docker stop "$CONTAINER_NAME" 2>/dev/null || true
docker rm "$CONTAINER_NAME" 2>/dev/null || true

# Clean up old/dangling docker images
echo -e "${YELLOW}Cleaning up old docker images...${NC}"
docker rmi "$IMAGE_NAME:local" 2>/dev/null || true
docker image prune -f 2>/dev/null || true
# Remove any dangling build cache
docker builder prune -f 2>/dev/null || true
sleep 1
echo -e "${GREEN}✓ Cleanup complete${NC}"

# Build Docker image
echo -e "\n${BLUE}Step 1: Building Docker image...${NC}"
docker build -f Dockerfile.http -t "$IMAGE_NAME:local" "$SCRIPT_DIR" 2>&1
BUILD_EXIT_CODE=$?
if [[ $BUILD_EXIT_CODE -ne 0 ]]; then
    echo -e "${RED}✗ Docker build failed with exit code $BUILD_EXIT_CODE${NC}"
    exit 1
fi

# Verify image exists
if ! docker image inspect "$IMAGE_NAME:local" &>/dev/null; then
    echo -e "${RED}✗ Docker image not found after build${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Docker image built: $IMAGE_NAME:local${NC}"

# Verify image can run (test --help)
echo -e "\n${BLUE}Step 1b: Verifying Docker image...${NC}"
HELP_OUTPUT=$(docker run --rm "$IMAGE_NAME:local" dotnet azmcp.dll --help 2>&1 || true)
if echo "$HELP_OUTPUT" | grep -q "server"; then
    echo -e "${GREEN}✓ Docker image verified (server command available)${NC}"
else
    echo -e "${YELLOW}⚠ Help output check:${NC}"
    echo "$HELP_OUTPUT" | head -10
    
    # Try running interactively to see the actual error
    echo -e "\n${YELLOW}Testing container startup...${NC}"
    docker run --rm -e AZURE_TENANT_ID="test" "$IMAGE_NAME:local" 2>&1 | head -20
fi

# Start container
echo -e "\n${BLUE}Step 2: Starting Docker container...${NC}"
docker run -d \
    --name "$CONTAINER_NAME" \
    -p "$PORT:8080" \
    -e AZURE_TENANT_ID="$AZURE_TENANT_ID" \
    -e AZURE_CLIENT_ID="$AZURE_CLIENT_ID" \
    -e AZURE_CLIENT_SECRET="$AZURE_CLIENT_SECRET" \
    -e AZURE_SUBSCRIPTION_ID="$AZURE_SUBSCRIPTION_ID" \
    "$IMAGE_NAME:local"

# Wait for container to start
echo -e "${YELLOW}Waiting for container to start...${NC}"
for i in {1..15}; do
    if docker ps | grep -q "$CONTAINER_NAME"; then
        # Check if server is responding
        if curl -s "http://$HOST:$PORT/sse" -o /dev/null -w "%{http_code}" --max-time 2 2>/dev/null | grep -q "200"; then
            echo -e "${GREEN}✓ Container started and server responding${NC}"
            break
        fi
    fi
    
    # Check if container exited
    if ! docker ps | grep -q "$CONTAINER_NAME"; then
        echo -e "${RED}✗ Container exited unexpectedly${NC}"
        echo -e "${YELLOW}Container logs:${NC}"
        docker logs "$CONTAINER_NAME" 2>&1 | tail -30
        exit 1
    fi
    
    if [[ $i -eq 15 ]]; then
        echo -e "${RED}✗ Timeout waiting for server${NC}"
        echo -e "${YELLOW}Container logs:${NC}"
        docker logs "$CONTAINER_NAME" 2>&1 | tail -30
        exit 1
    fi
    sleep 1
    echo -n "."
done

# Show container status
echo -e "\n${BLUE}Container Status:${NC}"
docker ps --filter "name=$CONTAINER_NAME" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Connect to SSE endpoint
echo -e "\n${BLUE}Step 3: Connecting to SSE endpoint...${NC}"
curl -s -N "http://$HOST:$PORT/sse" > "$SSE_OUTPUT" &
SSE_PID=$!
sleep 2

# Extract session ID
SESSION_ID=$(grep -o 'sessionId=[^"]*' "$SSE_OUTPUT" | head -1 | cut -d= -f2)
if [[ -z "$SESSION_ID" ]]; then
    echo -e "${RED}✗ Failed to get session ID${NC}"
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
send_mcp_request 1 "initialize" '{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"docker-test","version":"1.0"}}'
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
    sleep 5
    
    # Get the last response from SSE stream
    LAST_RESPONSE=$(tail -10 "$SSE_OUTPUT" | grep '"id":3' || true)
    
    if echo "$LAST_RESPONSE" | grep -q '"isError":false'; then
        echo -e "${GREEN}✓ group_list successful${NC}"
        
        # Decode unicode escapes and extract resource group info
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
        echo -e "${YELLOW}⚠ Response not captured yet${NC}"
        sleep 3
        LAST_RESPONSE=$(tail -10 "$SSE_OUTPUT" | grep '"id":3' || true)
        if [[ -n "$LAST_RESPONSE" ]]; then
            echo "$LAST_RESPONSE" | head -c 300
        fi
    fi
else
    echo -e "\n${YELLOW}Test 4: Skipped (AZURE_SUBSCRIPTION_ID not set)${NC}"
fi

# Summary
echo -e "\n${BLUE}========================================${NC}"
echo -e "${GREEN}All Docker tests completed!${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "Container: ${GREEN}$CONTAINER_NAME${NC}"
echo -e "Image: ${GREEN}$IMAGE_NAME:local${NC}"
echo -e "Server URL: ${GREEN}http://$HOST:$PORT${NC}"
echo -e "Session ID: ${GREEN}$SESSION_ID${NC}"

echo -e "\n${YELLOW}Container logs (last 10 lines):${NC}"
docker logs "$CONTAINER_NAME" 2>&1 | tail -10

echo -e "\nPress Enter to stop and remove the container..."
read -r

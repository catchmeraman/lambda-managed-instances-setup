#!/bin/bash
# test-deployment.sh - Comprehensive testing script for Lambda Managed Instances

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
API_ENDPOINT="${1:-}"
FUNCTION_NAME="high-traffic-api"
CAPACITY_PROVIDER="api-capacity-provider"

if [ -z "$API_ENDPOINT" ]; then
    echo -e "${RED}Error: API endpoint required${NC}"
    echo "Usage: ./test-deployment.sh https://xxx.execute-api.us-east-1.amazonaws.com/prod"
    exit 1
fi

echo "=========================================="
echo "Lambda Managed Instances - Test Suite"
echo "=========================================="
echo ""

# Test 1: Health Check
echo -e "${YELLOW}Test 1: Health Check${NC}"
HEALTH_RESPONSE=$(curl -s -w "\n%{http_code}" "${API_ENDPOINT}/health")
HTTP_CODE=$(echo "$HEALTH_RESPONSE" | tail -n1)
BODY=$(echo "$HEALTH_RESPONSE" | head -n-1)

if [ "$HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}✓ Health check passed${NC}"
    echo "Response: $BODY"
else
    echo -e "${RED}✗ Health check failed (HTTP $HTTP_CODE)${NC}"
    exit 1
fi
echo ""

# Test 2: Recommendations Endpoint
echo -e "${YELLOW}Test 2: Recommendations Endpoint${NC}"
REC_RESPONSE=$(curl -s -w "\n%{http_code}" "${API_ENDPOINT}/recommendations?userId=test123")
HTTP_CODE=$(echo "$REC_RESPONSE" | tail -n1)
BODY=$(echo "$REC_RESPONSE" | head -n-1)

if [ "$HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}✓ Recommendations endpoint passed${NC}"
    echo "Response: $BODY"
else
    echo -e "${RED}✗ Recommendations endpoint failed (HTTP $HTTP_CODE)${NC}"
    exit 1
fi
echo ""

# Test 3: Metadata Endpoint
echo -e "${YELLOW}Test 3: Metadata Endpoint${NC}"
META_RESPONSE=$(curl -s -w "\n%{http_code}" "${API_ENDPOINT}/metadata?contentId=movie123")
HTTP_CODE=$(echo "$META_RESPONSE" | tail -n1)
BODY=$(echo "$META_RESPONSE" | head -n-1)

if [ "$HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}✓ Metadata endpoint passed${NC}"
    echo "Response: $BODY"
else
    echo -e "${RED}✗ Metadata endpoint failed (HTTP $HTTP_CODE)${NC}"
    exit 1
fi
echo ""

# Test 4: 404 Handling
echo -e "${YELLOW}Test 4: 404 Error Handling${NC}"
NOT_FOUND=$(curl -s -w "\n%{http_code}" "${API_ENDPOINT}/nonexistent")
HTTP_CODE=$(echo "$NOT_FOUND" | tail -n1)

if [ "$HTTP_CODE" = "404" ]; then
    echo -e "${GREEN}✓ 404 handling works correctly${NC}"
else
    echo -e "${RED}✗ Expected 404, got HTTP $HTTP_CODE${NC}"
fi
echo ""

# Test 5: Load Test (requires Apache Bench)
if command -v ab &> /dev/null; then
    echo -e "${YELLOW}Test 5: Load Test (100 requests, 10 concurrent)${NC}"
    ab -n 100 -c 10 -q "${API_ENDPOINT}/health" > /tmp/ab_results.txt 2>&1
    
    RPS=$(grep "Requests per second" /tmp/ab_results.txt | awk '{print $4}')
    FAILED=$(grep "Failed requests" /tmp/ab_results.txt | awk '{print $3}')
    
    echo "Requests per second: $RPS"
    echo "Failed requests: $FAILED"
    
    if [ "$FAILED" = "0" ]; then
        echo -e "${GREEN}✓ Load test passed${NC}"
    else
        echo -e "${RED}✗ Load test had $FAILED failures${NC}"
    fi
else
    echo -e "${YELLOW}⊘ Apache Bench not installed, skipping load test${NC}"
fi
echo ""

# Test 6: Check Capacity Provider
echo -e "${YELLOW}Test 6: Capacity Provider Status${NC}"
PROVIDER_STATUS=$(aws lambda describe-capacity-provider \
    --name $CAPACITY_PROVIDER \
    --query 'CapacityProvider.Status.State' \
    --output text 2>/dev/null || echo "NOT_FOUND")

if [ "$PROVIDER_STATUS" = "ACTIVE" ]; then
    echo -e "${GREEN}✓ Capacity provider is active${NC}"
elif [ "$PROVIDER_STATUS" = "NOT_FOUND" ]; then
    echo -e "${YELLOW}⊘ Capacity provider not found (may not be deployed yet)${NC}"
else
    echo -e "${RED}✗ Capacity provider status: $PROVIDER_STATUS${NC}"
fi
echo ""

# Test 7: Check Running Instances
echo -e "${YELLOW}Test 7: EC2 Instances${NC}"
INSTANCE_COUNT=$(aws ec2 describe-instances \
    --filters "Name=tag:aws:lambda:capacity-provider,Values=$CAPACITY_PROVIDER" "Name=instance-state-name,Values=running" \
    --query 'length(Reservations[].Instances[])' \
    --output text 2>/dev/null || echo "0")

echo "Running instances: $INSTANCE_COUNT"
if [ "$INSTANCE_COUNT" -gt 0 ]; then
    echo -e "${GREEN}✓ Instances are running${NC}"
    
    aws ec2 describe-instances \
        --filters "Name=tag:aws:lambda:capacity-provider,Values=$CAPACITY_PROVIDER" "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[InstanceId,InstanceType,LaunchTime]' \
        --output table
else
    echo -e "${YELLOW}⊘ No instances running (may scale to zero during idle)${NC}"
fi
echo ""

# Test 8: CloudWatch Metrics
echo -e "${YELLOW}Test 8: CloudWatch Metrics (Last 5 minutes)${NC}"
INVOCATIONS=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name Invocations \
    --dimensions Name=FunctionName,Value=$FUNCTION_NAME \
    --statistics Sum \
    --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -v-5M +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --query 'Datapoints[0].Sum' \
    --output text 2>/dev/null || echo "0")

ERRORS=$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name Errors \
    --dimensions Name=FunctionName,Value=$FUNCTION_NAME \
    --statistics Sum \
    --start-time $(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -u -v-5M +%Y-%m-%dT%H:%M:%S) \
    --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
    --period 300 \
    --query 'Datapoints[0].Sum' \
    --output text 2>/dev/null || echo "0")

echo "Invocations (last 5 min): $INVOCATIONS"
echo "Errors (last 5 min): $ERRORS"

if [ "$ERRORS" = "0" ] || [ "$ERRORS" = "None" ]; then
    echo -e "${GREEN}✓ No errors in last 5 minutes${NC}"
else
    echo -e "${YELLOW}⚠ $ERRORS errors detected${NC}"
fi
echo ""

# Summary
echo "=========================================="
echo -e "${GREEN}Test Suite Complete${NC}"
echo "=========================================="
echo ""
echo "Next steps:"
echo "1. Run load test: ab -n 10000 -c 100 ${API_ENDPOINT}/health"
echo "2. Monitor logs: aws logs tail /aws/lambda/${FUNCTION_NAME} --follow"
echo "3. Check costs: aws ce get-cost-and-usage --time-period Start=2026-03-01,End=2026-03-11 --granularity DAILY --metrics BlendedCost"

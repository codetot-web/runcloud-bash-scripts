#!/bin/bash
API_KEY=*** /tmp/typesense-key | tr -d '\n')
echo "=== Collections ==="
curl -s -H "X-TYPESENSE-API-KEY: *** http://127.0.0.1:8108/collections
echo ""
echo "=== Debug: key length ==="
echo "API_KEY length: ${#API_KEY}"

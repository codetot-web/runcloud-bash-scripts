#!/bin/bash
API_KEY=$(cat /tmp/typesense-key)

# Create collection
curl -s -X POST \
  -H "X-TYPESENSE-API-KEY: $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"product","fields":[{"name":"title","type":"string"},{"name":"content","type":"string"},{"name":"sku","type":"string"},{"name":"price","type":"float"},{"name":"categories","type":"string[]"}],"default_sorting_field":"price"}' \
  http://127.0.0.1:8108/collections

echo ""
echo "--- Collections ---"
curl -s -H "X-TYPESENSE-API-KEY: $API_KEY" http://127.0.0.1:8108/collections

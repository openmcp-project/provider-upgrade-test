#!/usr/bin/env bash
echo "^^Executing clean-up scripts ^^"

kubectl delete -f providers/provider-btp/v1.0.3/crs/

echo "checking deletion status of managed resources ..."
# Duration of the timeout in seconds (1 hour)
timeout_duration=$(( 60 * 60 ))
interval=30

start_time=$(date +%s)

while true; do
  current_time=$(date +%s)
  elapsed_time=$(( current_time - start_time ))
  
  if [ "$elapsed_time" -ge "$timeout_duration" ]; then
    echo "Timeout of checking reached. Exit."
    exit 1
  fi

  resources=$(kubectl get managed --no-headers 2>/dev/null)

  if [ -n "$resources" ]; then
    echo "Managed resources still exists:"
    echo "$resources"
  else
    echo "No managed resources found. Deletion finished."
    exit 0
  fi

  sleep "$interval"
done